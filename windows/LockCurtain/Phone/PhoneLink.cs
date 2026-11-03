// PhoneLink.cs —— Windows 端的「配对手机」（电脑是蓝牙中心，手机是外设），对照 Mac 的 Sources/PhonePairing.swift
//
// 手机广播 LockCurtain 的服务，电脑扫描、连上去、订阅手机的「发件箱」，往手机的「收件箱」写回复和幕布状态：
//   * 发件箱（…5A70，notify）：手机 → 电脑，配对握手（请求 / 确认 / 放弃）、签名命令、问询的回答
//   * 收件箱（…5A71，write）：电脑 → 手机，配对应答 / 拒绝、命令收据、幕布状态、撤销通知、问询、撤下结果
// 每条消息按 PairingFraming 切块。安全全在 Phone/Protocol（PairingCrypto / PairingAuthority / LiftGate），不靠系统蓝牙加密。
//
// 和 Mac 不一样的地方（WinRT 的蓝牙 API 和 CoreBluetooth 不同）：
//   * 扫描：BluetoothLEAdvertisementWatcher（主动扫描），不按服务 UUID 过滤，在回调里自己挑：
//       - 广播里有我们的服务 UUID 或名字「LockCurtain」（手机 App 在前台时就是这样，配对时一定在前台）；
//       - 或者是苹果的「溢出区」广播（厂商数据 0x004C、类型 0x01、16 字节位图）：iPhone App 在后台广播时，
//         服务 UUID 不出现在广播里，只在这张位图里占一位，只有苹果设备认得。Mac 的 CoreBluetooth 能按 UUID 找到它，
//         Windows 不能，所以已配对、没连着时把溢出区广播当候选去连，连上后用签名的 ping 认人（和 Mac 一样，说不出身份的
//         15 秒后断开、本次运行不再连）。连上认出来以后，从这台手机自己的溢出区广播里记下位图，以后只连位图对得上的。
//     如果用服务 UUID 过滤，手机锁屏 / App 在后台时 Windows 就再也找不到它（蓝牙关了又开、电脑睡醒以后重连不上）。
//   * 连接：BluetoothLEDevice.FromBluetoothAddressAsync + GattSession.MaintainConnection = true（相当于 Mac 的挂起式连接）。
//     配过的手机记住它最后的蓝牙地址（phone-link.json），没连着时每 10 秒试一次；iPhone 的地址会轮换，所以同时一直扫描兜底。
//   * RSSI：WinRT 没有「读已连接设备的 RSSI」（Mac 用 readRSSI）。改用这台手机的广播包 RSSI：手机连着以后照样在广播，
//     扫描器一直开着，每 2 秒取过去 2 秒里收到的、和连接同一个蓝牙地址的广播包的 RSSI 平均值当一次样本；
//     这 2 秒里一个都没收到就不记（不够 3 次就是「不够近」，宁可不撤）。门槛和 Mac 一样：最近 3 次的中位数 >= -65 dBm。
//   * 蓝牙开关：Windows.Devices.Radios 的 Radio.StateChanged。关了就把所有连接当作已断（和 Mac 1331f8f 的修正一样，
//     不等逐个断开回调），开了就重启扫描、重连记得的手机。
//   * 睡眠 / 唤醒：SystemEvents.PowerModeChanged。睡前丢掉所有连接、停扫描；醒来 3 秒后重新开始。
//   * 另外每 10 秒自检一次：该扫没在扫就重启扫描器；配过、没连着就重连记得的地址 —— 以上事件漏了也能在一分钟内接回来。
//
// 手机撤下幕布：幕布盖着、手机连着并认过身份时，每 2 秒往手机收件箱写一条签名的问询（Poll + 新 nonce），手机回签名的
// Presence（此刻解锁着 / 锁着 / 关着）。签名和计数由 PairingAuthority 验，撤不撤由 LiftGate 判（新鲜、边沿、近），
// 撤就调 OnLift（只撤 LockCurtain 的遮罩，不碰 Windows 锁屏，也绝不解锁 Windows），再回手机一条签名的 LiftResult。
//
// 所有状态只在 UI 线程上改：WinRT 的回调都 Post 回 UI 线程，await 也在 UI 线程上接着跑。
// 日志：%LOCALAPPDATA%\LockCurtain\ble.log（PhoneLog），每步一行，「lift:」行和 Mac 一字不差。不写码、不写钥匙。

using Microsoft.Win32;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Radios;
using Windows.Storage.Streams;

namespace LockCurtain.Phone;

internal enum PhonePhase
{
    Idle,           // 没在配对
    Waiting,        // 显示着码，等手机
    CodeDead,       // 码作废了（错 3 次 / 过期），等「换一个码」
    Paired,         // 刚配上（握手验过、手机签的第一条命令也验过）
    BluetoothOff,
    Unsupported,    // 没有蓝牙 / 不支持低功耗蓝牙中心模式
    Revoked,        // 刚撤销过配对
}

internal sealed class PhoneLink
{
    public static readonly Guid ServiceUuid = Guid.Parse("E9A1B2C3-D4E5-4F60-8A7B-1C2D3E4F5A6B");
    /// 手机 → 电脑
    public static readonly Guid OutboxUuid = Guid.Parse("E9A1B2C3-D4E5-4F60-8A7B-1C2D3E4F5A70");
    /// 电脑 → 手机
    public static readonly Guid InboxUuid = Guid.Parse("E9A1B2C3-D4E5-4F60-8A7B-1C2D3E4F5A71");
    const string LocalName = "LockCurtain";
    const ushort AppleCompanyId = 0x004C;

    const int MaxEarlyDrops = 5;
    /// 窗口关着时，连上的手机这么久还没用签名命令表明身份，就断开、本次运行不再连它
    static readonly TimeSpan IdentifyTimeout = TimeSpan.FromSeconds(15);
    /// 码开着多久作废（文案「过期」）
    static readonly TimeSpan CodeLifetime = TimeSpan.FromMinutes(10);
    /// 每次 RSSI 样本取多长时间窗里的广播包
    static readonly TimeSpan RssiWindow = TimeSpan.FromSeconds(2.5);
    /// 同一个地址的候选，多久之内不重复去连（溢出区候选可能是别人的手机）
    static readonly TimeSpan CandidateRetry = TimeSpan.FromSeconds(30);

    public PhonePhase Phase { get; private set; } = PhonePhase.Idle;
    public string Code { get; private set; } = "";
    /// 码或阶段变了（UI 线程上发）
    public event Action? Changed;
    /// 手机发来的命令（目前只认 away），接到原来的遮罩命令上
    public Func<string, Task>? OnCommand;
    /// 手机撤下幕布（条件都满足了）：只撤 LockCurtain 的遮罩
    public Action? OnLift;

    readonly SynchronizationContext ui;
    readonly PairingAuthority authority;
    readonly PhoneDeviceMemory memory = new();

    bool wantsBluetooth, initialized, initializing, windowOpen, stoppedAfterEarlyDrops, suspended;
    bool? radioOn;
    int earlyDrops;
    Radio? radio;
    BluetoothLEAdvertisementWatcher? watcher;
    bool connectingKnown;
    readonly System.Windows.Forms.Timer tick = new() { Interval = 2000 };
    readonly System.Windows.Forms.Timer health = new() { Interval = 10_000 };
    readonly System.Windows.Forms.Timer codeExpiry = new();

    /// 幕布现在是不是盖着；这次盖上的时刻 T（边沿规则从这里算）
    bool curtainClosed;
    DateTime? curtainClosedAt;
    /// 每台手机的撤下判断（按 phoneID，断开重连也留着「盖上之后见过锁着」）
    readonly Dictionary<Guid, LiftGate> gates = new();

    /// 一台连上（或正在连）的手机
    sealed class Peer(ulong address, BluetoothAddressType type)
    {
        public readonly ulong Address = address;
        public readonly BluetoothAddressType AddressType = type;
        public BluetoothLEDevice? Device;
        public GattSession? Session;
        public GattDeviceService? Service;
        public GattCharacteristic? Inbox, Outbox;
        public bool Subscribed, Closed;
        public readonly PairingFraming.Assembler Assembler = new();
        /// 验过签名命令之后才知道它是哪台手机
        public Guid? PhoneID;
        public DateTime? ConnectedAt;
        public readonly Queue<byte[]> WriteQueue = new();
        public bool Writing, DisconnectAfterWrites;
        public string Name => FormatAddress(Address);
        public int MaxChunk => Math.Max(20, (Session?.MaxPduSize ?? 23) - 3);
    }

    readonly Dictionary<ulong, Peer> peers = new();
    /// 本次运行不再理的地址（窗口关着时连上了却说不出自己是谁）
    readonly HashSet<ulong> ignored = new();
    /// 每个地址最近收到的广播 RSSI（只记相关的：我们的服务 / 溢出区 / 连着的）
    readonly Dictionary<ulong, List<(int Rssi, DateTime At)>> adverts = new();
    readonly Dictionary<ulong, DateTime> lastCandidateTry = new();

    public PhoneLink(SynchronizationContext ui, IPairingRecordStore? store = null)
    {
        this.ui = ui;
        authority = new PairingAuthority(store ?? new DpapiPairingStore(), PhoneLog.Write);
        tick.Tick += (_, _) => Tick();
        health.Tick += (_, _) => HealthCheck();
        codeExpiry.Tick += (_, _) =>
        {
            codeExpiry.Stop();
            if (Phase != PhonePhase.Waiting) return;
            authority.Expire();
            Code = "";
            SetPhase(PhonePhase.CodeDead);
        };
        SystemEvents.PowerModeChanged += (_, e) => ui.Post(_ => OnPowerMode(e.Mode), null);
    }

    public bool IsPaired => authority.IsPaired;

    static string FormatAddress(ulong a) =>
        string.Join(":", Enumerable.Range(0, 6).Select(i => ((a >> (8 * (5 - i))) & 0xFF).ToString("X2")));

    static string Who(Guid id) => PairingCrypto.IdString(id);

    void SetPhase(PhonePhase p)
    {
        Phase = p;
        Changed?.Invoke();
    }

    // MARK: - 开始 / 结束

    /// App 启动时（已配过手机）调用：开始找手机
    public void Prepare()
    {
        wantsBluetooth = true;
        if (!initialized) _ = InitializeAsync();
        else Resume();
    }

    async Task InitializeAsync()
    {
        if (initializing) return;
        initializing = true;
        PhoneLog.Write("central: create");
        try
        {
            var adapter = await BluetoothAdapter.GetDefaultAsync();
            if (adapter == null || !adapter.IsLowEnergySupported || !adapter.IsCentralRoleSupported)
            {
                PhoneLog.Write($"central: no usable bluetooth adapter (adapter {(adapter == null ? "missing" : $"le={adapter.IsLowEnergySupported} central={adapter.IsCentralRoleSupported}")})");
                SetPhase(PhonePhase.Unsupported);
                return;
            }
            radio = await adapter.GetRadioAsync();
            if (radio != null)
            {
                radio.StateChanged += (r, _) =>
                {
                    var state = r.State;
                    ui.Post(_ => OnRadioState(state), null);
                };
                radioOn = radio.State == RadioState.On;
                PhoneLog.Write($"central state {radio.State}");
            }
            else
            {
                radioOn = true;
                PhoneLog.Write("central state unknown (no radio object); assuming on");
            }
            initialized = true;
            health.Start();
            if (radioOn == false && (windowOpen || Phase == PhonePhase.Idle)) SetPhase(PhonePhase.BluetoothOff);
            Resume();
        }
        catch (Exception e)
        {
            PhoneLog.Write($"central: init failed: {e.GetType().Name}: {e.Message}");
            SetPhase(PhonePhase.Unsupported);
        }
        finally { initializing = false; }
    }

    /// 打开配对窗口时调用：生成一个新码，开始找手机
    public void Start()
    {
        var fresh = MakeCode();
        authority.OpenWindow(fresh);
        Code = fresh;
        windowOpen = true;
        ignored.Clear();
        lastCandidateTry.Clear();
        if (stoppedAfterEarlyDrops)
        {
            PhoneLog.Write("pairing window reopened: resuming after early-drop stop");
            stoppedAfterEarlyDrops = false;
            earlyDrops = 0;
        }
        RestartExpiry();
        SetPhase(radioOn == false ? PhonePhase.BluetoothOff : Phase == PhonePhase.Unsupported ? PhonePhase.Unsupported : PhonePhase.Waiting);
        Prepare();
    }

    /// 关窗口时调用：把码作废；没配过手机就不再找
    public void Stop()
    {
        authority.CloseWindow();
        codeExpiry.Stop();
        Code = "";
        windowOpen = false;
        if (Phase is not (PhonePhase.BluetoothOff or PhonePhase.Unsupported)) Phase = PhonePhase.Idle;
        Changed?.Invoke();
        if (!IsPaired)
        {
            PhoneLog.Write("pairing window closed and nothing paired: stop scanning");
            StopWatcher();
            foreach (var p in peers.Values.ToList()) Drop(p, "pairing window closed");
        }
    }

    /// 换一个码：老的立刻作废，次数重新算
    public void RefreshCode()
    {
        if (Phase is not (PhonePhase.Waiting or PhonePhase.CodeDead)) return;
        var fresh = MakeCode();
        authority.Refresh(fresh);
        Code = fresh;
        RestartExpiry();
        PhoneLog.Write("code refreshed");
        SetPhase(radioOn == false ? PhonePhase.BluetoothOff : PhonePhase.Waiting);
    }

    void RestartExpiry()
    {
        codeExpiry.Stop();
        codeExpiry.Interval = (int)CodeLifetime.TotalMilliseconds;
        codeExpiry.Start();
    }

    static string MakeCode() => System.Security.Cryptography.RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");

    /// 撤销这台电脑上记着的所有手机：连着的手机先收到签名的撤销通知（它会删掉自己的钥匙），再删电脑的钥匙
    public void UnpairAll()
    {
        var notices = authority.RevokeAll();
        foreach (var peer in peers.Values)
        {
            if (peer.PhoneID is not { } id) continue;
            peer.PhoneID = null;
            if (notices.TryGetValue(id, out var notice))
            {
                PhoneLog.Write($"revoke: notifying connected phone {Who(id)}");
                Send(notice, peer);
                peer.DisconnectAfterWrites = true;
            }
        }
        memory.Forget();
        gates.Clear();
        Code = "";
        SetPhase(PhonePhase.Revoked);
        if (!windowOpen)
        {
            StopWatcher();
            foreach (var p in peers.Values.ToList())
                if (!p.DisconnectAfterWrites) Drop(p, "unpaired");
        }
    }

    /// 幕布状态变了：告诉已连上的手机（签名的）
    public void ReportCurtainState(bool closed)
    {
        if (curtainClosed == closed) return;
        curtainClosed = closed;
        var now = DateTime.UtcNow;
        curtainClosedAt = closed ? now : null;
        foreach (var g in gates.Values)
            if (closed) g.Covered(now); else g.Uncovered();
        PhoneLog.Write($"lift: curtain {(closed ? "covered" : "uncovered")}");
        foreach (var peer in peers.Values)
            if (peer.PhoneID is { } id && authority.StateMessage(closed, id) is { } m) Send(m, peer);
    }

    // MARK: - 扫描 / 连接

    bool ShouldRun => wantsBluetooth && (windowOpen || IsPaired) && !stoppedAfterEarlyDrops && !suspended;

    bool HasIdentifiedPeer => peers.Values.Any(p => p.PhoneID != null && p.Subscribed);

    void Resume()
    {
        if (!initialized || radioOn != true || !ShouldRun) return;
        ConnectKnown("pending reconnect to known phone");
        StartWatcher();
    }

    /// 记得的手机：按地址连（它的地址没轮换、人在附近就能连上）
    void ConnectKnown(string reason)
    {
        if (!IsPaired || memory.Address is not { } address || peers.ContainsKey(address) || connectingKnown) return;
        if (HasIdentifiedPeer) return;
        // iPhone 用的是随机地址
        Connect(address, BluetoothAddressType.Random, reason);
    }

    void StartWatcher()
    {
        if (radioOn != true || !ShouldRun) return;
        if (watcher?.Status == BluetoothLEAdvertisementWatcherStatus.Started) return;
        StopWatcher();
        try
        {
            var nw = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
            nw.Received += OnReceived;
            nw.Stopped += (s, e) =>
            {
                var error = e.Error;
                ui.Post(_ =>
                {
                    if (!ReferenceEquals(watcher, s)) return;
                    PhoneLog.Write($"scan stopped ({error})");
                    watcher = null;
                }, null);
            };
            nw.Start();
            watcher = nw;
            PhoneLog.Write($"scan start (window {(windowOpen ? "open" : "closed")}, paired {IsPaired}, status {nw.Status})");
        }
        catch (Exception e)
        {
            PhoneLog.Write($"scan start failed: {e.GetType().Name}: {e.Message}");
            watcher = null;
        }
    }

    void StopWatcher()
    {
        if (watcher == null) return;
        var w = watcher;
        watcher = null;
        w.Received -= OnReceived;
        try { w.Stop(); } catch (Exception) { }
        PhoneLog.Write("scan stop");
    }

    /// 扫描回调（线程池上）：先在这里把无关的广播筛掉，只把相关的 Post 回 UI 线程
    void OnReceived(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementReceivedEventArgs args)
    {
        try
        {
            var ad = args.Advertisement;
            var ours = ad.ServiceUuids.Contains(ServiceUuid) || ad.LocalName == LocalName;
            byte[]? overflow = null;
            foreach (var m in ad.ManufacturerData)
            {
                if (m.CompanyId != AppleCompanyId || m.Data.Length < 17) continue;
                var data = ReadBuffer(m.Data);
                if (data[0] == 0x01) overflow = data[1..17];
            }
            var address = args.BluetoothAddress;
            if (!ours && overflow == null && !peers.ContainsKey(address)) return;
            var rssi = (int)args.RawSignalStrengthInDBm;
            var type = args.BluetoothAddressType;
            var name = ad.LocalName;
            var at = DateTime.UtcNow;
            ui.Post(_ => OnAdvertisement(address, type, rssi, ours, overflow, name, at), null);
        }
        catch (Exception) { }
    }

    void OnAdvertisement(ulong address, BluetoothAddressType type, int rssi, bool ours, byte[]? overflow, string name, DateTime at)
    {
        if (!adverts.TryGetValue(address, out var list)) adverts[address] = list = new();
        list.Add((rssi, at));
        list.RemoveAll(x => at - x.At > TimeSpan.FromSeconds(10));
        if (adverts.Count > 64)
            foreach (var stale in adverts.Where(kv => kv.Value.Count == 0 || at - kv.Value[^1].At > TimeSpan.FromSeconds(30)).Select(kv => kv.Key).ToList())
                adverts.Remove(stale);

        // 认出来的手机自己的溢出区位图：记下来，以后只连位图对得上的
        if (overflow != null && peers.TryGetValue(address, out var known) && known.PhoneID != null && known.Subscribed
            && (memory.OverflowMask == null || !memory.OverflowMask.AsSpan().SequenceEqual(overflow)))
        {
            PhoneLog.Write($"learned background advertisement bitmap of {Who(known.PhoneID.Value)}: {Bytes.Hex(overflow)}");
            memory.LearnOverflowMask(overflow);
        }

        if (!ShouldRun || peers.ContainsKey(address) || ignored.Contains(address)) return;
        // 已经有一台验明身份的手机连着、窗口也没开：不用再连别的
        if (!windowOpen && HasIdentifiedPeer) return;
        string reason;
        if (ours) reason = "discovered by scan";
        else
        {
            // 溢出区候选：只在配过、没连着的时候；学到过位图就要对得上
            if (overflow == null || !IsPaired || HasIdentifiedPeer) return;
            if (memory.OverflowMask is { } mask && !Contains(overflow, mask)) return;
            reason = "discovered by scan (apple background advertisement)";
        }
        if (lastCandidateTry.TryGetValue(address, out var last) && at - last < CandidateRetry) return;
        // 同一时间只连一台候选，免得一屋子 iPhone 都去连
        if (!ours && peers.Values.Any(p => p.ConnectedAt == null || p.PhoneID == null)) return;
        lastCandidateTry[address] = at;
        PhoneLog.Write($"discovered {FormatAddress(address)} name={(string.IsNullOrEmpty(name) ? "(no name)" : name)} rssi={rssi}{(ours ? "" : " (background)")}");
        Connect(address, type, reason);
    }

    static bool Contains(byte[] bits, byte[] mask)
    {
        for (var i = 0; i < 16; i++)
            if ((bits[i] & mask[i]) != mask[i]) return false;
        return true;
    }

    void Connect(ulong address, BluetoothAddressType type, string reason)
    {
        if (peers.ContainsKey(address)) return;
        var peer = new Peer(address, type);
        peers[address] = peer;
        PhoneLog.Write($"connect requested {peer.Name} ({reason})");
        _ = ConnectAsync(peer, isKnown: reason.StartsWith("pending"));
    }

    async Task ConnectAsync(Peer peer, bool isKnown)
    {
        if (isKnown) connectingKnown = true;
        try
        {
            var device = peer.AddressType == BluetoothAddressType.Unspecified
                ? await BluetoothLEDevice.FromBluetoothAddressAsync(peer.Address)
                : await BluetoothLEDevice.FromBluetoothAddressAsync(peer.Address, peer.AddressType);
            if (peer.Closed) { device?.Dispose(); return; }
            if (device == null)
            {
                FailConnect(peer, "device not available");
                return;
            }
            peer.Device = device;
            device.ConnectionStatusChanged += (d, _) =>
            {
                var status = d.ConnectionStatus;
                ui.Post(_ => OnConnectionStatus(peer, status), null);
            };
            try
            {
                var session = await GattSession.FromDeviceIdAsync(device.BluetoothDeviceId);
                if (peer.Closed) { session?.Dispose(); return; }
                if (session != null)
                {
                    session.MaintainConnection = true;
                    peer.Session = session;
                }
            }
            catch (Exception e) { PhoneLog.Write($"gatt session for {peer.Name} failed: {e.Message}"); }

            var services = await device.GetGattServicesForUuidAsync(ServiceUuid, BluetoothCacheMode.Uncached);
            if (peer.Closed) return;
            if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
            {
                // 连不上（Unreachable）或者没有我们的服务（不是 LockCurtain 手机）
                FailConnect(peer, services.Status == GattCommunicationStatus.Success ? "service not found" : $"gatt {services.Status}");
                return;
            }
            peer.ConnectedAt = DateTime.UtcNow;
            PhoneLog.Write($"connected {peer.Name}");
            peer.Service = services.Services[0];
            foreach (var extra in services.Services.Skip(1)) extra.Dispose();

            var chars = await peer.Service.GetCharacteristicsAsync(BluetoothCacheMode.Uncached);
            if (peer.Closed) return;
            if (chars.Status == GattCommunicationStatus.Success)
                foreach (var c in chars.Characteristics)
                {
                    if (c.Uuid == OutboxUuid) peer.Outbox = c;
                    if (c.Uuid == InboxUuid) peer.Inbox = c;
                }
            if (peer.Outbox == null || peer.Inbox == null)
            {
                PhoneLog.Write($"characteristics missing on {peer.Name}: {chars.Status}");
                Disconnected(peer, "characteristics missing");
                return;
            }
            PhoneLog.Write($"services ready on {peer.Name} (max write {peer.MaxChunk})");
            peer.Outbox.ValueChanged += (_, e) =>
            {
                var chunk = ReadBuffer(e.CharacteristicValue);
                ui.Post(_ => OnChunk(peer, chunk), null);
            };
            var sub = await peer.Outbox.WriteClientCharacteristicConfigurationDescriptorWithResultAsync(
                GattClientCharacteristicConfigurationDescriptorValue.Notify);
            if (peer.Closed) return;
            if (sub.Status != GattCommunicationStatus.Success)
            {
                PhoneLog.Write($"subscribe failed on {peer.Name}: {sub.Status}{(sub.ProtocolError is { } pe ? $" (att error {pe})" : "")}");
                Disconnected(peer, "subscribe failed");
                return;
            }
            peer.Subscribed = true;
            earlyDrops = 0;
            PhoneLog.Write($"subscribed outbox on {peer.Name}");
            UpdateTick();
            if (!windowOpen) ScheduleIdentifyCheck(peer);
        }
        catch (Exception e)
        {
            if (peer.Closed) return;
            if (peer.ConnectedAt == null) FailConnect(peer, $"{e.GetType().Name}: {e.Message}");
            else Disconnected(peer, $"{e.GetType().Name}: {e.Message}");
        }
        finally
        {
            if (isKnown) connectingKnown = false;
        }
    }

    /// 没连上（对应 Mac 的 didFailToConnect）：丢掉，继续扫
    void FailConnect(Peer peer, string why)
    {
        PhoneLog.Write($"failed to connect {peer.Name}: {why}");
        Drop(peer, null);
        StartWatcher();
    }

    void OnConnectionStatus(Peer peer, BluetoothConnectionStatus status)
    {
        if (peer.Closed) return;
        PhoneLog.Write($"connection status {peer.Name}: {status}");
        if (status == BluetoothConnectionStatus.Disconnected && peer.ConnectedAt != null) Disconnected(peer, "link lost");
    }

    /// 断了（对应 Mac 的 didDisconnectPeripheral）
    void Disconnected(Peer peer, string why)
    {
        if (peer.Closed) return;
        var wasReady = peer.Subscribed;
        var duration = peer.ConnectedAt is { } t ? $"{(DateTime.UtcNow - t).TotalSeconds:0.0}s" : "?";
        PhoneLog.Write($"disconnected {peer.Name} after {duration}, ready={wasReady.ToString().ToLowerInvariant()}: {why}");
        var wasIdentified = peer.PhoneID != null;
        Drop(peer, null);

        if (!wasReady && ShouldRun && !ignored.Contains(peer.Address))
        {
            earlyDrops++;
            PhoneLog.Write($"early drop {earlyDrops}/{MaxEarlyDrops}");
            if (earlyDrops >= MaxEarlyDrops)
            {
                stoppedAfterEarlyDrops = true;
                StopWatcher();
                foreach (var p in peers.Values.ToList()) Drop(p, null);
                PhoneLog.Write($"stopped after {MaxEarlyDrops} early drops; reopen the pairing window to retry");
                return;
            }
        }
        if (!ShouldRun || ignored.Contains(peer.Address)) return;
        if (wasIdentified && IsPaired) ConnectKnown("pending reconnect after drop");
        StartWatcher();
    }

    /// 释放这条连接的所有 WinRT 对象（Windows 上释放了才真的断开）
    void Drop(Peer peer, string? why)
    {
        if (peer.Closed) return;
        peer.Closed = true;
        if (why != null) PhoneLog.Write($"dropping {peer.Name}: {why}");
        if (peers.TryGetValue(peer.Address, out var cur) && ReferenceEquals(cur, peer)) peers.Remove(peer.Address);
        if (peer.PhoneID is { } id && gates.TryGetValue(id, out var g)) g.ResetRSSI();
        peer.WriteQueue.Clear();
        try { peer.Service?.Dispose(); } catch (Exception) { }
        try { peer.Session?.Dispose(); } catch (Exception) { }
        try { peer.Device?.Dispose(); } catch (Exception) { }
        peer.Service = null;
        peer.Session = null;
        peer.Device = null;
        peer.Inbox = peer.Outbox = null;
        UpdateTick();
    }

    void DropAll(string why)
    {
        if (peers.Count == 0) return;
        PhoneLog.Write($"{why}: dropping {peers.Count} stale peer(s)");
        foreach (var p in peers.Values.ToList()) Drop(p, null);
    }

    /// 窗口关着时连上一台说不出身份的手机：等一会儿，还不说就断开、本次运行不再连它
    void ScheduleIdentifyCheck(Peer peer)
    {
        var t = new System.Windows.Forms.Timer { Interval = (int)IdentifyTimeout.TotalMilliseconds };
        t.Tick += (_, _) =>
        {
            t.Stop();
            t.Dispose();
            if (peer.Closed || peer.PhoneID != null || windowOpen) return;
            PhoneLog.Write($"peripheral {peer.Name} did not identify within {(int)IdentifyTimeout.TotalSeconds}s; ignoring it this session");
            ignored.Add(peer.Address);
            Drop(peer, null);
            StartWatcher();
        };
        t.Start();
    }

    // MARK: - 系统事件

    void OnRadioState(RadioState state)
    {
        PhoneLog.Write($"central state {state}");
        var on = state == RadioState.On;
        if (radioOn == on) return;
        radioOn = on;
        if (!on)
        {
            // 蓝牙关掉时不一定逐个回调断开：清掉旧连接，否则重新开蓝牙后以为手机还连着，不再扫也不再连
            DropAll("bluetooth off");
            StopWatcher();
            if (windowOpen) SetPhase(PhonePhase.BluetoothOff);
        }
        else
        {
            if (Phase == PhonePhase.BluetoothOff) SetPhase(windowOpen ? (Code.Length > 0 ? PhonePhase.Waiting : PhonePhase.CodeDead) : PhonePhase.Idle);
            ignored.Clear();
            lastCandidateTry.Clear();
            Resume();
        }
    }

    void OnPowerMode(PowerModes mode)
    {
        if (mode == PowerModes.Suspend)
        {
            PhoneLog.Write("system suspend");
            suspended = true;
            DropAll("system suspend");
            StopWatcher();
        }
        else if (mode == PowerModes.Resume)
        {
            PhoneLog.Write("system resume: restarting in 3s");
            var t = new System.Windows.Forms.Timer { Interval = 3000 };
            t.Tick += (_, _) =>
            {
                t.Stop();
                t.Dispose();
                suspended = false;
                // 睡眠中蓝牙栈可能重置过，旧连接全当作废
                DropAll("system resume");
                StopWatcher();
                ignored.Clear();
                lastCandidateTry.Clear();
                Resume();
            };
            t.Start();
        }
    }

    /// 每 10 秒：该扫没在扫就重启扫描器；配过、没连着就重连记得的地址
    void HealthCheck()
    {
        if (!initialized || radioOn != true || !ShouldRun) return;
        if (watcher == null || watcher.Status != BluetoothLEAdvertisementWatcherStatus.Started)
        {
            PhoneLog.Write($"health: scanner {(watcher == null ? "not running" : watcher.Status.ToString())}, restarting");
            StartWatcher();
        }
        if (IsPaired && !HasIdentifiedPeer) ConnectKnown("pending reconnect to known phone (health check)");
    }

    // MARK: - 每 2 秒：RSSI 样本 + 问询

    void UpdateTick()
    {
        var anyConnected = peers.Values.Any(p => p.Subscribed);
        if (anyConnected && !tick.Enabled) tick.Start();
        else if (!anyConnected && tick.Enabled) tick.Stop();
    }

    void Tick()
    {
        var now = DateTime.UtcNow;
        foreach (var peer in peers.Values.Where(p => p.Subscribed && !p.Closed).ToList())
        {
            SampleRssi(peer, now);
            Poll(peer);
        }
    }

    /// 这台手机过去 2.5 秒的广播包 RSSI 平均值算一次样本（见文件头「RSSI」）
    void SampleRssi(Peer peer, DateTime now)
    {
        var recent = adverts.TryGetValue(peer.Address, out var list)
            ? list.Where(x => now - x.At <= RssiWindow).Select(x => x.Rssi).Where(v => v < 0).ToList() : [];
        if (recent.Count == 0)
        {
            PhoneLog.Write($"rssi {peer.Name} read failed: no advertisement in the last {RssiWindow.TotalSeconds:0.#}s");
            return;
        }
        var value = (int)Math.Round(recent.Average());
        PhoneLog.Write($"rssi {peer.Name} {value} (advertisements n={recent.Count}, [{string.Join(",", recent)}])");
        if (peer.PhoneID is { } id) Gate(id).RecordRSSI(value, now);
    }

    LiftGate Gate(Guid phoneID)
    {
        if (gates.TryGetValue(phoneID, out var g)) return g;
        g = new LiftGate();
        if (curtainClosed && curtainClosedAt is { } at) g.Covered(at);
        gates[phoneID] = g;
        return g;
    }

    /// 幕布盖着、手机认过身份：发一条签名的问询（新 nonce）
    void Poll(Peer peer)
    {
        if (!curtainClosed || peer.PhoneID is not { } id || !peer.Subscribed || peer.Inbox == null) return;
        // 上一条还没写完（手机没回执）就不再堆
        if (peer.WriteQueue.Count > 0 || peer.Writing)
        {
            PhoneLog.Write($"lift: poll skipped for {Who(id)}: previous write still pending");
            return;
        }
        var nonce = PairingCrypto.MakeNonce();
        if (authority.PollMessage(nonce, id) is not { } message) return;
        Gate(id).Issue(nonce, DateTime.UtcNow);
        PhoneLog.Write($"lift: poll sent to {Who(id)} nonce {Short(nonce)}");
        Send(message, peer);
    }

    static string Short(byte[] nonce) => Bytes.Hex(nonce.AsSpan(0, 4));

    // MARK: - 收发

    static byte[] ReadBuffer(IBuffer buffer)
    {
        var bytes = new byte[buffer.Length];
        using var reader = DataReader.FromBuffer(buffer);
        reader.ReadBytes(bytes);
        return bytes;
    }

    static IBuffer ToBuffer(byte[] bytes)
    {
        using var writer = new DataWriter();
        writer.WriteBytes(bytes);
        return writer.DetachBuffer();
    }

    void Send(byte[] message, Peer peer)
    {
        if (peer.Inbox == null || peer.Closed)
        {
            PhoneLog.Write($"send skipped: inbox of {peer.Name} not ready");
            return;
        }
        // 不走长写：按单包上限切块，每块都要回执
        foreach (var c in PairingFraming.Chunks(message, peer.MaxChunk)) peer.WriteQueue.Enqueue(c);
        _ = Pump(peer);
    }

    async Task Pump(Peer peer)
    {
        while (!peer.Writing && !peer.Closed)
        {
            if (peer.WriteQueue.Count == 0)
            {
                if (peer.DisconnectAfterWrites)
                {
                    peer.DisconnectAfterWrites = false;
                    PhoneLog.Write($"disconnecting {peer.Name} after final message");
                    Drop(peer, null);
                    if (ShouldRun) StartWatcher(); else StopWatcher();
                }
                return;
            }
            var inbox = peer.Inbox;
            if (inbox == null) return;
            peer.Writing = true;
            var chunk = peer.WriteQueue.Dequeue();
            try
            {
                var r = await inbox.WriteValueWithResultAsync(ToBuffer(chunk), GattWriteOption.WriteWithResponse);
                if (r.Status != GattCommunicationStatus.Success)
                {
                    PhoneLog.Write($"write to inbox of {peer.Name} failed: {r.Status}{(r.ProtocolError is { } pe ? $" (att error {pe})" : "")}");
                    peer.WriteQueue.Clear();
                }
            }
            catch (Exception e)
            {
                PhoneLog.Write($"write to inbox of {peer.Name} failed: {e.GetType().Name}: {e.Message}");
                peer.WriteQueue.Clear();
            }
            finally { peer.Writing = false; }
        }
    }

    void OnChunk(Peer peer, byte[] chunk)
    {
        if (peer.Closed) return;
        if (peer.Assembler.Feed(chunk) is { } message) Receive(message, peer);
    }

    void Receive(byte[] message, Peer peer)
    {
        switch (PairingCrypto.KindOf(message))
        {
            case Kind.PairRequest or Kind.PairConfirm or Kind.PairAbort:
                PhoneLog.Write($"pair message received from peripheral {peer.Name}");
                var o = authority.HandlePair(message);
                if (o.Reply != null) Send(o.Reply, peer);
                if (authority.IsLocked && windowOpen)
                {
                    Code = "";
                    codeExpiry.Stop();
                    SetPhase(PhonePhase.CodeDead);
                }
                else Changed?.Invoke();
                break;
            case Kind.Presence or Kind.LiftNow:
                HandleAnswer(message, peer);
                break;
            case Kind.Command:
                var c = authority.HandleCommand(message);
                if (!c.Accepted)
                {
                    if (c.Ack != null) Send(c.Ack, peer);
                    break;
                }
                var phoneID = c.PhoneID!.Value;
                peer.PhoneID = phoneID;
                memory.Remember(peer.Address);
                Send(c.Ack!, peer);
                if (c.ConfirmedPairing)
                {
                    codeExpiry.Stop();
                    SetPhase(PhonePhase.Paired);
                    Log.Write($"LockCurtain paired with a phone ({Who(phoneID)})");
                }
                Handle(c.Command, phoneID, peer);
                break;
            default:
                PhoneLog.Write($"message of unknown kind ({message.Length} bytes) from {peer.Name} ignored");
                break;
        }
    }

    void Handle(string command, Guid phoneID, Peer peer)
    {
        switch (command.ToLowerInvariant())
        {
            case "ping":
                // 握手确认 / 重连时表明身份：把现在的幕布状态告诉它
                if (authority.StateMessage(curtainClosed, phoneID) is { } state) Send(state, peer);
                break;
            case "unpair":
                PhoneLog.Write($"phone {Who(phoneID)} asked to unpair");
                authority.Revoke(phoneID);
                gates.Remove(phoneID);
                peer.PhoneID = null;
                if (!IsPaired) memory.Forget();
                peer.DisconnectAfterWrites = true;
                _ = Pump(peer);
                if (!ShouldRun) StopWatcher();
                Changed?.Invoke();
                break;
            case "away":
                if (OnCommand is { } run) _ = run("away");
                break;
            case var other when other.Length > 0:
                // Mac 把别的命令也交给命令通道；这里只认手机真会发的 away，别的不执行
                PhoneLog.Write($"command \"{other}\" from {Who(phoneID)} not supported on Windows; ignored");
                break;
        }
    }

    // MARK: - 撤下

    void HandleAnswer(byte[] message, Peer peer)
    {
        var outcome = authority.HandleAnswer(message);
        if (outcome.Answer is not { } answer) return;
        var id = answer.PhoneID;
        // 签名对，但不是这条连接上认过的那台手机：不理
        if (peer.PhoneID != id)
        {
            PhoneLog.Write($"lift: answer from {Who(id)} on a connection identified as {(peer.PhoneID is { } p ? Who(p) : "nobody")}; ignored");
            return;
        }
        var now = DateTime.UtcNow;
        var gate = Gate(id);
        var wasArmed = gate.EdgeArmed;
        var (median, samples) = gate.RssiMedian(now);
        var rssiText = $"rssi median {(median?.ToString() ?? "-")} of [{string.Join(",", samples)}], need >= {LiftGate.NearMedianDBm}";
        LiftDecision decision;
        if (!answer.IsLiftNow)
        {
            var word = answer.Status switch { PresenceStatus.Unlocked => "unlocked", PresenceStatus.Locked => "locked", _ => "off" };
            PhoneLog.Write($"lift: presence from {Who(id)}: {word}, nonce {Short(answer.Nonce)}, counter {answer.Counter}, {rssiText}");
            decision = gate.Presence(answer.Status, answer.Nonce, now);
            if (!wasArmed && gate.EdgeArmed) PhoneLog.Write($"lift: edge armed for {Who(id)} (locked seen after cover)");
        }
        else
        {
            PhoneLog.Write($"lift: lift-now request from {Who(id)}, nonce {Short(answer.Nonce)}, counter {answer.Counter}, {rssiText}");
            decision = gate.LiftNow(answer.Nonce, now);
        }
        var label = answer.IsLiftNow ? "lift-now result" : "lift decision";
        if (decision.Lift)
        {
            PhoneLog.Write($"lift: {label}: lifted ({rssiText})");
            if (authority.LiftResultMessage(LiftStatus.Lifted, answer.Counter, id) is { } reply) Send(reply, peer);
            OnLift?.Invoke();
        }
        else
        {
            PhoneLog.Write($"lift: {label}: refused, {Describe(decision)}");
            if (answer.IsLiftNow && authority.LiftResultMessage(LiftGate.ResultStatus(decision.Why), answer.Counter, id) is { } reply)
                Send(reply, peer);
        }
    }

    static string Describe(LiftDecision d) => d.Why switch
    {
        Refusal.NotCovered => "curtain not covered",
        Refusal.UnknownNonce => "nonce unknown or already used",
        Refusal.StaleNonce => $"nonce stale (older than {(int)LiftGate.ChallengeLifetime}s or from before cover)",
        Refusal.ToggleOff => "phone setting off",
        Refusal.PhoneLocked => "phone locked",
        Refusal.EdgeNotArmed => "edge rule: no locked report from this phone since cover",
        Refusal.NotNear => $"not near (median {d.Value} < {LiftGate.NearMedianDBm})",
        _ => $"not near (only {d.Value} fresh rssi samples, need {LiftGate.RssiSamples})",
    };
}
