// NetworkGateway.cs —— 手机走网络（TCP）连这台电脑：电脑端的监听和连接管理。对照 Mac 的 Sources/PhoneNetwork.swift（NetworkGateway）
//
// 只依赖 System.Net（没有 WinForms、没有 WinRT），测试直接在进程里起一个真的 NetworkGateway（本机回环）。
// 安全全在 PairingCrypto / PairingAuthority（Transport.Network）：这里只是字节管道 + 加固，规则和 Mac 一一对应：
//   * 帧：2 字节大端长度 + 一整条 PairingCrypto 消息（NetFraming），长度 0 或超过 1024 立刻断开
//   * 手机只能 ping / away / awake:* / name:，其余（撤下、解除配对、预览、设置、配对、Presence、LiftNow）
//     在权威端（NetworkPolicy）默认拒绝（签名的 Ack 5）；Presence / LiftNow / 配对帧这里根本不交给权威端
//   * 连上后 5 秒内必须有一条验过的签名命令，否则断开；同时最多 4 条还没验过的连接
//   * 一条连接上 3 个坏帧：断开，这个 IP 60 秒内不再理；验过之后 120 秒没有验过的帧也断开；打开 TCP keepalive
//   * 端口：49200–49999 里挑一个存起来（Settings.PhoneNetPort），以后一直用，占用了才换（最多 5 次）
//   * 每条网络连接上（认出手机后、以及每次回 Ack 之后）发一条签名的 Poll 当新鲜度挑战：
//     手机之后的命令要带这里面的 nonce（n1:<nonce>:<命令>），单次有效，不进 LiftGate
//
// 线程：所有状态只在 scheduler 上碰（和 Mac 的 queue 一样）。程序里 scheduler 就是 UI 线程（和 PairingAuthority 的其余调用方同一个线程，
// 所以权威端不用加锁；套接字都是异步的，UI 线程不会等网络）；测试里是一个独占调度器。所有回调都在 scheduler 上。
//
// 和 Mac 不一样的地方：
//   * 没有「缺辅助功能就不盖」（Windows 没有这个权限），所以没有 canCover / Ack 4；
//   * 端口被占时，Windows 还会因为 Hyper-V / WSL / Docker 保留端口段而报「拒绝访问」，也当占用处理、换端口；
//   * 地址变化用 NetworkChange.NetworkAddressChanged（Mac 用 NWPathMonitor）。

using System.Collections.Concurrent;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;

namespace LockCurtain.Phone;

internal enum GatewayState { Stopped, Starting, Listening, Failed }

/// 监听状态：Listening 带端口，Failed 带原因（占用换了几次还不行 / 防火墙 / 没有网络等）
internal readonly record struct GatewayStatus(GatewayState State, int Port = 0, string? Error = null)
{
    public static readonly GatewayStatus Stopped = new(GatewayState.Stopped);
}

/// 端口存哪儿：程序里是 settings.json，测试里是内存
internal interface INetworkPortStore
{
    int? Load();
    void Save(int port);
}

internal sealed class MemoryPortStore : INetworkPortStore
{
    public int? Port { get; set; }
    public int? Load() => Port;
    public void Save(int port) => Port = port;
}

internal enum PortChoice
{
    /// 49200–49999 里挑一个存起来，以后一直用
    Persisted,
    /// 系统分配（自测用）
    Ephemeral,
}

internal sealed class NetworkGateway
{
    /// 认出来的网络手机
    public sealed record Peer(Guid PhoneID, string? Name, string Remote);

    public const int PortMin = 49200, PortMax = 49999;

    // 加固参数（自测可以改短）
    public TimeSpan PingDeadline { get; set; } = TimeSpan.FromSeconds(5);
    public TimeSpan IdleTimeout { get; set; } = TimeSpan.FromSeconds(120);
    public int MaxUnauthenticated { get; set; } = 4;
    public int MaxBadFrames { get; set; } = 3;
    public TimeSpan BanDuration { get; set; } = TimeSpan.FromSeconds(60);
    /// 手机名最多存多少字节（和 Mac 一样 64；PhoneLink 换成自己的上限）
    public int MaxNameBytes { get; set; } = 64;
    /// 同时最多多少条连接（Mac 的 newConnectionLimit）
    public int MaxConnections { get; set; } = 64;

    // 接线（回调都在 scheduler 上）
    /// 放行的命令（ping 除外）：away、awake:off|1h|2h|5h|always（小写）、name:<名字>（原样）。
    /// 收据已经先发了；awake: 之后网关自己会把保持唤醒状态报给所有网络手机
    public Action<string, Guid> OnCommand { get; set; } = (_, _) => { };
    public Func<bool> CurtainClosed { get; set; } = () => false;
    public Func<KeepAwakeWireState> KeepAwakeState { get; set; } = () => KeepAwakeWireState.Off;
    /// 认出一台手机 / 一台断了 / 名字变了
    public Action? OnPeersChanged { get; set; }
    public Action? OnStatusChanged { get; set; }
    public Action? OnAddressesChanged { get; set; }
    /// 一条连接第一次验过（认出是哪台手机）：给 UI 记「最后连上」
    public Action<Guid>? OnPeerIdentified { get; set; }
    /// 日志：不写钥匙、不写 nonce
    public Action<string> Log { get; set; } = _ => { };
    /// 本机地址从哪儿来（测试可以换）
    public Func<List<NetworkAddressEntry>> AddressProvider { get; set; } = NetworkAddresses.Current;

    public GatewayStatus Status { get; private set; } = GatewayStatus.Stopped;
    /// 现在监听的端口；没在监听是 null
    public int? Port => Status.State == GatewayState.Listening ? Status.Port : null;
    public IReadOnlyList<NetworkAddressEntry> Addresses { get; private set; } = [];

    /// 认出身份的网络手机
    public IReadOnlyList<Peer> Peers => conns.Values
        .Where(c => c.Authenticated && c.PhoneID != null && !c.Closed)
        .Select(c => new Peer(c.PhoneID!.Value, c.Name, c.Ip))
        .OrderBy(p => PairingCrypto.IdString(p.PhoneID), StringComparer.Ordinal).ToList();

    /// 现在开着的连接数（含还没验过的）
    public int ConnectionCount => conns.Count;

    readonly PairingAuthority authority;
    readonly TaskScheduler scheduler;
    readonly PortChoice choice;
    readonly INetworkPortStore ports;
    readonly bool loopbackOnly;

    TcpListener? listener;
    readonly ConcurrentDictionary<Guid, Conn> conns = new();
    readonly Dictionary<string, DateTime> bans = new();
    int generation, portRetries;
    NetworkAddressChangedEventHandler? networkChanged;
    bool refreshing;

    sealed class Conn(TcpClient client, string ip)
    {
        public readonly Guid Id = Guid.NewGuid();
        public readonly TcpClient Client = client;
        public readonly NetworkStream Stream = client.GetStream();
        public readonly string Ip = ip;
        public readonly DateTime AcceptedAt = DateTime.UtcNow;
        public DateTime LastVerified = DateTime.UtcNow;
        public readonly NetFraming.Reader Reader = new();
        public Guid? PhoneID;
        public string? Name;
        public volatile bool Authenticated, Closed;
        public int BadFrames;
        public readonly Queue<(byte[] Data, string? ThenClose)> Writes = new();
        public bool Writing;
    }

    /// loopbackOnly：只绑 127.0.0.1（自测）
    public NetworkGateway(PairingAuthority authority, TaskScheduler scheduler, INetworkPortStore ports,
                          PortChoice port = PortChoice.Persisted, bool loopbackOnly = false)
    {
        this.authority = authority;
        this.scheduler = scheduler;
        this.ports = ports;
        choice = port;
        this.loopbackOnly = loopbackOnly;
    }

    // MARK: - 排队

    /// 在 scheduler 上跑（和 Mac 的 queue.async 一样）
    void Post(Action work) => Task.Factory.StartNew(() =>
    {
        try { work(); }
        catch (Exception e) { Log($"phone network: unexpected error: {e.GetType().Name}: {e.Message}"); }
    }, CancellationToken.None, TaskCreationOptions.DenyChildAttach, scheduler);

    /// 测试用：在 scheduler 上算一个值再拿回来
    public Task<T> RunAsync<T>(Func<T> work) =>
        Task.Factory.StartNew(work, CancellationToken.None, TaskCreationOptions.DenyChildAttach, scheduler);

    // MARK: - 端口

    /// 存着的端口；没有（或不在范围内）就挑一个存起来
    public int PersistedPort() =>
        ports.Load() is { } p && p is >= PortMin and <= PortMax ? p : ChoosePort();

    public int ChoosePort()
    {
        var p = Random.Shared.Next(PortMin, PortMax + 1);
        ports.Save(p);
        return p;
    }

    // MARK: - 开关

    /// 开始监听（异步，状态变化走 OnStatusChanged / Status）
    public void Start() => Post(() =>
    {
        if (listener != null || Status.State == GatewayState.Starting) return;
        portRetries = 0;
        BeginListening(choice == PortChoice.Persisted ? PersistedPort() : 0);
    });

    /// 停止监听并关掉所有连接（异步）
    public void Stop() => Post(StopNow);

    /// 必须在 scheduler 上调
    public void StopNow()
    {
        generation++;
        try { listener?.Stop(); } catch (SocketException) { }
        listener = null;
        if (networkChanged != null) NetworkChange.NetworkAddressChanged -= networkChanged;
        networkChanged = null;
        var open = conns.Values.ToList();
        var hadPeers = open.Any(c => c.Authenticated);
        foreach (var c in open) Close(c, "gateway stopped", notify: false);
        if (hadPeers) OnPeersChanged?.Invoke();
        if (Status.State != GatewayState.Stopped) Log("phone network stopped");
        SetStatus(GatewayStatus.Stopped);
        if (Addresses.Count > 0)
        {
            Addresses = [];
            OnAddressesChanged?.Invoke();
        }
    }

    void SetStatus(GatewayStatus s)
    {
        if (s == Status) return;
        Status = s;
        OnStatusChanged?.Invoke();
    }

    TcpListener MakeListener(int port, bool v6)
    {
        TcpListener l;
        if (loopbackOnly) l = new TcpListener(IPAddress.Loopback, port);
        else if (v6)
        {
            // 一个套接字同时收 IPv4 和 IPv6（Mac 的 NWListener 也是）
            l = new TcpListener(IPAddress.IPv6Any, port);
            l.Server.DualMode = true;
        }
        else l = new TcpListener(IPAddress.Any, port);
        // Windows 上默认能被别的进程用 SO_REUSEADDR 抢同一个端口；独占
        if (OperatingSystem.IsWindows()) l.ExclusiveAddressUse = true;
        return l;
    }

    void BeginListening(int port)
    {
        TcpListener made;
        try
        {
            try
            {
                made = MakeListener(port, Socket.OSSupportsIPv6);
                made.Start(MaxConnections);
            }
            catch (SocketException e) when (Socket.OSSupportsIPv6 && !loopbackOnly
                                            && e.SocketErrorCode is SocketError.AddressFamilyNotSupported or SocketError.ProtocolNotSupported)
            {
                made = MakeListener(port, v6: false);
                made.Start(MaxConnections);
            }
        }
        catch (SocketException e)
        {
            Fail(e, port);
            return;
        }
        generation++;
        var mine = generation;
        listener = made;
        var actual = ((IPEndPoint)made.LocalEndpoint).Port;
        SetStatus(new GatewayStatus(GatewayState.Starting));
        SetStatus(new GatewayStatus(GatewayState.Listening, actual));
        Log($"phone network listening on port {actual}");
        _ = AcceptLoop(made, mine);
        _ = TickLoop(mine);
        StartMonitoring(mine);
    }

    /// 监听没起来：端口被占了就换一个（存起来），最多 5 次
    void Fail(SocketException e, int port)
    {
        Log($"phone network: listen failed: {e.SocketErrorCode}");
        // Windows：Hyper-V / WSL / Docker 保留的端口段绑不上报 AccessDenied，和占用一样处理
        var inUse = e.SocketErrorCode is SocketError.AddressAlreadyInUse or SocketError.AccessDenied;
        if (choice == PortChoice.Persisted && inUse && portRetries < 5)
        {
            portRetries++;
            var next = ChoosePort();
            Log($"phone network: port {(port == 0 ? "?" : port.ToString())} busy, trying {next}");
            BeginListening(next);
            return;
        }
        SetStatus(new GatewayStatus(GatewayState.Failed, Error: e.SocketErrorCode.ToString()));
    }

    // MARK: - 地址

    void StartMonitoring(int mine)
    {
        if (networkChanged != null) NetworkChange.NetworkAddressChanged -= networkChanged;
        networkChanged = (_, _) => Post(() =>
        {
            if (generation == mine) RefreshAddresses();
        });
        NetworkChange.NetworkAddressChanged += networkChanged;
        RefreshAddresses();
    }

    /// 重新列本机地址（网络变了、睡眠醒来时）；列地址放到线程池上做，结果回到 scheduler 上比对
    public void RefreshAddresses() => Post(() => _ = RefreshAsync());

    async Task RefreshAsync()
    {
        if (Status.State != GatewayState.Listening || refreshing) return;
        refreshing = true;
        var mine = generation;
        try
        {
            var fresh = await Task.Run(AddressProvider);
            if (generation != mine || Status.State != GatewayState.Listening) return;
            if (fresh.SequenceEqual(Addresses)) return;
            Addresses = fresh;
            OnAddressesChanged?.Invoke();
        }
        catch (Exception e)
        {
            Log($"phone network: listing addresses failed: {e.GetType().Name}");
        }
        finally { refreshing = false; }
    }

    // MARK: - 定时检查

    async Task TickLoop(int mine)
    {
        while (generation == mine)
        {
            await Task.Delay(250);
            if (generation != mine) return;
            Tick();
        }
    }

    void Tick()
    {
        var now = DateTime.UtcNow;
        foreach (var k in bans.Where(b => b.Value <= now).Select(b => b.Key).ToList()) bans.Remove(k);
        foreach (var c in conns.Values.ToList().Where(c => !c.Closed))
        {
            if (!c.Authenticated)
            {
                if (now - c.AcceptedAt > PingDeadline) Close(c, $"no verified command within {(int)PingDeadline.TotalSeconds}s");
            }
            else if (now - c.LastVerified > IdleTimeout) Close(c, $"idle for {(int)IdleTimeout.TotalSeconds}s");
        }
    }

    /// 清掉 IP 封禁（自测用）
    public void ClearBans() => bans.Clear();

    public bool IsBanned(string ip) => bans.TryGetValue(ip, out var until) && until > DateTime.UtcNow;

    // MARK: - 连接

    static string IpOf(TcpClient client)
    {
        if (client.Client.RemoteEndPoint is not IPEndPoint ep) return "?";
        var address = ep.Address;
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        var text = address.ToString();
        var i = text.IndexOf('%');
        return i >= 0 ? text[..i] : text;
    }

    async Task AcceptLoop(TcpListener l, int mine)
    {
        while (generation == mine)
        {
            TcpClient client;
            try { client = await l.AcceptTcpClientAsync(); }
            catch (SocketException e) when (generation == mine && e.SocketErrorCode is SocketError.ConnectionReset or SocketError.ConnectionAborted)
            {
                continue;       // 对面在 accept 之前就断了，不影响监听
            }
            catch (Exception e) when (e is SocketException or ObjectDisposedException or InvalidOperationException)
            {
                if (generation == mine)
                {
                    // 不是我们自己停的：监听坏了
                    Log($"phone network: accept failed: {e.GetType().Name}");
                    var failed = new GatewayStatus(GatewayState.Failed, Error: e is SocketException se ? se.SocketErrorCode.ToString() : e.GetType().Name);
                    StopNow();
                    SetStatus(failed);
                }
                return;
            }
            if (generation != mine)
            {
                client.Dispose();
                return;
            }
            Accept(client);
        }
    }

    void Accept(TcpClient client)
    {
        var ip = IpOf(client);
        if (IsBanned(ip))
        {
            Log($"connection from {ip} refused: banned");
            client.Dispose();
            return;
        }
        var unauthenticated = conns.Values.Count(c => !c.Authenticated);
        if (unauthenticated >= MaxUnauthenticated)
        {
            Log($"connection from {ip} refused: {unauthenticated} unauthenticated connections already open");
            client.Dispose();
            return;
        }
        if (conns.Count >= MaxConnections)
        {
            Log($"connection from {ip} refused: too many connections");
            client.Dispose();
            return;
        }
        Conn c;
        try
        {
            client.NoDelay = true;
            var s = client.Client;
            s.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
            s.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveTime, 30);
            s.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveInterval, 10);
            s.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveRetryCount, 3);
            c = new Conn(client, ip);
        }
        catch (Exception e) when (e is SocketException or ObjectDisposedException or InvalidOperationException)
        {
            client.Dispose();
            return;
        }
        conns[c.Id] = c;
        _ = ReceiveLoop(c);
    }

    async Task ReceiveLoop(Conn c)
    {
        var buffer = new byte[4096];
        try
        {
            while (!c.Closed)
            {
                var n = await c.Stream.ReadAsync(buffer);
                if (c.Closed) return;
                if (n == 0)
                {
                    Close(c, "peer closed");
                    return;
                }
                foreach (var frame in c.Reader.Feed(buffer.AsSpan(0, n)))
                {
                    if (c.Closed) return;
                    Handle(frame, c);
                }
                if (!c.Closed && c.Reader.IsBroken)
                {
                    Close(c, "bad frame length");
                    return;
                }
            }
        }
        catch (Exception e) when (e is IOException or SocketException or ObjectDisposedException or InvalidOperationException)
        {
            Close(c, "receive error");
        }
    }

    void Close(Conn c, string why, bool notify = true)
    {
        if (c.Closed) return;
        c.Closed = true;
        conns.TryRemove(c.Id, out _);
        try { c.Client.Dispose(); } catch (SocketException) { }
        Log($"connection from {c.Ip} closed: {why}");
        if (c.Authenticated && notify) OnPeersChanged?.Invoke();
    }

    /// thenClose：写完这一条再断开（不再收这条连接上的东西）
    void Send(byte[] message, Conn c, string? thenClose = null)
    {
        if (c.Closed || NetFraming.Frame(message) is not { } framed) return;
        c.Writes.Enqueue((framed, thenClose));
        if (!c.Writing) _ = Pump(c);
    }

    async Task Pump(Conn c)
    {
        c.Writing = true;
        try
        {
            while (!c.Closed && c.Writes.TryDequeue(out var w))
            {
                await c.Stream.WriteAsync(w.Data);
                if (w.ThenClose != null)
                {
                    Close(c, w.ThenClose);
                    return;
                }
            }
        }
        catch (Exception e) when (e is IOException or SocketException or ObjectDisposedException or InvalidOperationException)
        {
            Close(c, "send failed");
        }
        finally { c.Writing = false; }
    }

    /// 坏帧：满 MaxBadFrames 个就断开并封这个 IP
    void BadFrame(Conn c, string why, byte[]? reply = null)
    {
        c.BadFrames++;
        Log($"bad frame from {c.Ip}: {why} ({c.BadFrames}/{MaxBadFrames})");
        var ban = c.BadFrames >= MaxBadFrames;
        if (ban)
        {
            bans[c.Ip] = DateTime.UtcNow + BanDuration;
            Log($"{c.Ip} banned for {(int)BanDuration.TotalSeconds}s");
        }
        if (reply != null) Send(reply, c, ban ? "too many bad frames" : null);
        else if (ban) Close(c, "too many bad frames");
    }

    // MARK: - 处理一帧

    void Handle(byte[] message, Conn c)
    {
        switch (PairingCrypto.KindOf(message))
        {
            case Kind.Command:
                HandleCommand(message, c);
                break;
            case Kind.PairRequest or Kind.PairConfirm or Kind.PairAbort:
                // 配对只走蓝牙：不交给权威端，不回话
                BadFrame(c, "pairing message over network");
                break;
            case Kind.Presence or Kind.LiftNow:
                // 撤下只走蓝牙：不交给权威端（不耗计数、够不到 LiftGate）
                BadFrame(c, "lift message over network");
                break;
            default:
                BadFrame(c, "unexpected message kind");
                break;
        }
    }

    void HandleCommand(byte[] message, Conn c)
    {
        var o = authority.HandleCommand(message, Transport.Network);
        if (o.Accepted)
        {
            var phoneID = o.PhoneID!.Value;
            if (c.PhoneID is { } known && known != phoneID)
            {
                BadFrame(c, "connection switched phone");
                return;
            }
            c.LastVerified = DateTime.UtcNow;
            Send(o.Ack!, c);
            Identify(c, phoneID);
            Dispatch(o.Command, phoneID, c);
            SendPoll(c, phoneID);
            return;
        }
        switch (o.Reason)
        {
            case RejectReason.NetworkForbidden:
                // 签名对、计数已记，只是不许：回签名的 Ack 5。不算认过身份，也不算坏帧
                if (o.Ack != null) Send(o.Ack, c);
                if (o.PhoneID is { } id && c.Authenticated)
                {
                    c.LastVerified = DateTime.UtcNow;
                    SendPoll(c, id);
                }
                break;
            case RejectReason.BadNonce:
                // nonce 缺 / 过期 / 用过：Ack 2，再给一个新的
                if (o.Ack != null) Send(o.Ack, c);
                if (o.PhoneID is { } nid) SendPoll(c, nid);
                break;
            case RejectReason.Replay or RejectReason.StoreFailed:
                if (o.Ack != null) Send(o.Ack, c);
                break;
            default:
                BadFrame(c, PairingAuthority.Describe(o.Reason), o.Ack);
                break;
        }
    }

    void Identify(Conn c, Guid phoneID)
    {
        if (c.Authenticated) return;
        c.Authenticated = true;
        c.PhoneID = phoneID;
        // 同一台手机的旧连接（网络换了、手机重连）让位
        foreach (var other in conns.Values.ToList())
            if (other != c && other.PhoneID == phoneID) Close(other, "replaced by a newer connection from the same phone", notify: false);
        Log($"network phone {PairingCrypto.IdString(phoneID)} identified from {c.Ip}");
        OnPeerIdentified?.Invoke(phoneID);
        OnPeersChanged?.Invoke();
    }

    void Dispatch(string command, Guid phoneID, Conn c)
    {
        if (command.StartsWith("name:", StringComparison.Ordinal))
        {
            var trimmed = command[5..].Trim();
            var name = Encoding.UTF8.GetString(PairingCrypto.Utf8Prefix(trimmed, MaxNameBytes));
            c.Name = name;
            OnPeersChanged?.Invoke();
            OnCommand("name:" + name, phoneID);
            return;
        }
        var lower = command.ToLowerInvariant();
        if (lower == "ping")
        {
            // 握手确认 / 重连时表明身份：把现在的幕布状态、保持唤醒状态告诉它
            if (authority.StateMessage(CurtainClosed(), phoneID) is { } state) Send(state, c);
            SendKeepAwake(c, phoneID);
            return;
        }
        OnCommand(lower, phoneID);
        if (lower.StartsWith("awake:", StringComparison.Ordinal)) PushKeepAwake();
    }

    void SendPoll(Conn c, Guid phoneID)
    {
        if (authority.NetworkPollMessage(phoneID) is { } poll) Send(poll, c);
    }

    void SendKeepAwake(Conn c, Guid phoneID)
    {
        if (authority.KeepAwakeStateMessage(KeepAwakeState(), phoneID) is { } m) Send(m, c);
    }

    void PushKeepAwake()
    {
        foreach (var c in conns.Values.ToList())
            if (c.Authenticated && c.PhoneID is { } id) SendKeepAwake(c, id);
    }

    // MARK: - 往手机推

    /// 幕布盖上 / 撤下了：报给所有认过身份的网络手机
    public void ReportCurtain(bool closed) => Post(() =>
    {
        foreach (var c in conns.Values.ToList())
            if (c.Authenticated && c.PhoneID is { } id && authority.StateMessage(closed, id) is { } m) Send(m, c);
    });

    /// 保持唤醒状态变了：报给所有认过身份的网络手机
    public void ReportKeepAwake() => Post(PushKeepAwake);

    /// 在电脑上撤销了这台手机：把签名的撤销通知发给它的网络连接，发完断开
    public void NotifyRevoked(Guid phoneID, byte[]? notice) => Post(() =>
    {
        authority.DropNetworkNonces(phoneID);
        foreach (var c in conns.Values.ToList().Where(c => c.PhoneID == phoneID))
        {
            if (notice != null) Send(notice, c, "phone revoked");
            else Close(c, "phone revoked");
        }
    });

    /// 断开这台手机的网络连接（不发通知）
    public void Disconnect(Guid phoneID) => Post(() =>
    {
        foreach (var c in conns.Values.ToList().Where(c => c.PhoneID == phoneID)) Close(c, "disconnected by the computer");
    });
}
