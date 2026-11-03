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
//         订阅上 30 秒后断开、这个地址暂时不理，30 s → … → 5 min 到点放出来）。连上认出来以后，从这台手机自己的溢出区广播里
//         学位图（多次观察取交集，只留每次都在的位），以后只连位图对得上的；配过、没连着、2 分钟都没有对得上的，就先不看位图。
//     如果用服务 UUID 过滤，手机锁屏 / App 在后台时 Windows 就再也找不到它（蓝牙关了又开、电脑睡醒以后重连不上）。
//   * 连接：BluetoothLEDevice.FromBluetoothAddressAsync + GattSession.MaintainConnection = true（相当于 Mac 的挂起式连接）。
//     配过的手机记住它最后的蓝牙地址（phone-link.json），没连着时去连它，失败了退避 10 s → 20 s → … → 5 min，
//     看到我们的广播就清零；iPhone 的地址会轮换，所以同时一直扫描兜底，扫到的「我们的」广播可以打断正在连的旧地址。
//   * RSSI：WinRT 没有「读已连接设备的 RSSI」（Mac 用 readRSSI）。改用这台手机的广播包 RSSI：手机连着以后照样在广播，
//     扫描器一直开着，每 2 秒取过去 2 秒里收到的、和连接同一个蓝牙地址的广播包的 RSSI 平均值当一次样本；
//     这 2 秒里一个都没收到就不记（不够 3 次就是「不够近」，宁可不撤）。门槛和 Mac 一样：最近 3 次的中位数 >= -65 dBm。
//   * 蓝牙开关：Windows.Devices.Radios 的 Radio.StateChanged。关了就把所有连接当作已断（和 Mac 1331f8f 的修正一样，
//     不等逐个断开回调），开了就重启扫描、重连记得的手机。
//   * 睡眠 / 唤醒：SystemEvents.PowerModeChanged。睡前丢掉所有连接、停扫描；醒来 3 秒后重新开始。
//   * 重连不停手（见 ReconnectPolicy.cs 的不变式：配过对 + 蓝牙开着 + 没连上 ⇒ 一直在试，间隔翻倍、最长 5 分钟）：
//       - 早断（订阅好之前就断）：没配过（只开着配对窗口）时连续 5 次硬停，等重新打开窗口；配过时从第 5 次起只是退避
//         （30 s → … → 5 min，只拉开去连记得的地址；扫描照开，看到我们的广播马上连、清零）。
//       - 连续 3 次写失败（不只是超时）、手机的 GATT 服务变了（GattServicesChanged）：当断开处理，交给正常重连。
//   * 另外每 10 秒自检一次（配过就一直跑，不管早断）：扫描器没在跑 / 状态是 Aborted 或 Stopped 就重启；
//     「睡着了」挂了超过 60 秒（漏了 Resume 事件）就当醒了；放出到点的不理地址；配过、没连着就（按退避）重连记得的地址。
//
// 手机撤下幕布：幕布盖着、手机连着并认过身份时，每 2 秒往手机收件箱写一条签名的问询（Poll + 新 nonce），手机回签名的
// Presence（此刻解锁着 / 锁着 / 关着）。签名和计数由 PairingAuthority 验，撤不撤由 LiftGate 判（新鲜、边沿、近），
// 撤就调 OnLift（只撤 LockCurtain 的遮罩，不碰 Windows 锁屏，也绝不解锁 Windows），再回手机一条签名的 LiftResult。
//
// 线程（1.0.4-beta.2 起，修「手机走开再回来，程序无响应」）：
//   * 状态（peers、gates、码、阶段…）仍然只在 UI 线程上读写，不加锁。
//   * 但 UI 线程上不做任何会等蓝牙的事：连接、查服务、订阅、写、开关扫描器、释放 BluetoothLEDevice / GattSession /
//     GattDeviceService，全部在线程池上做（Task.Run + ConfigureAwait(false)），每个 WinRT 异步调用最多等 10 秒（超时取消）。
//     做完把结果 Post 回 UI 线程。释放对象从不在它自己的事件回调里做。
//   * 连接和释放排成一队（bleGate）：新连接要等旧对象放掉；同一时间只连一台（connecting），重连不会叠在一起。
//   * 扫描回调不碰 UI 的字典：广播先进一个并发队列，攒着一次 Post 回 UI 线程处理。
//   * UiWatchdog：UI 线程超过 2 秒没处理消息就往 ble.log 写一行（带这里的状态），卡在哪里下次看日志就知道。
// 日志：%LOCALAPPDATA%\LockCurtain\ble.log（PhoneLog），每步一行，「lift:」行和 Mac 一字不差。不写码、不写钥匙。

using Microsoft.Win32;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Radios;
using Windows.Foundation;
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

    /// 窗口关着时，订阅上的手机这么久还没用签名命令表明身份，就断开、这个地址暂时不理（限时，见 TimedIgnoreList）
    static readonly TimeSpan IdentifyTimeout = TimeSpan.FromSeconds(30);
    /// 去连记得的地址失败后的退避
    static readonly TimeSpan KnownBackoffBase = TimeSpan.FromSeconds(10);
    /// 「睡着了」挂了这么久还没醒（漏了 Resume 事件）：当醒了（自检的计时器只在醒着时跑）
    static readonly TimeSpan StaleSuspend = TimeSpan.FromSeconds(60);
    /// 配过、没连着，这么久没有对得上位图的溢出区广播：先不看位图
    static readonly TimeSpan OverflowFallbackAfter = TimeSpan.FromMinutes(2);
    /// 连续写失败这么多次：当断开
    const int MaxWriteErrors = 3;
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

    bool wantsBluetooth, initialized, initializing, windowOpen, suspended;
    /// 只在没配过手机（配对窗口模式）时会变 true
    bool stoppedAfterEarlyDrops;
    DateTime? suspendedAt;
    bool? radioOn;
    readonly EarlyDropPolicy earlyDrops = new();
    /// 去连记得的地址的退避（失败一次翻倍，看到我们的广播清零）
    readonly ReconnectBackoff knownBackoff = new(KnownBackoffBase, Reconnect.Cap);
    /// 最近一次「对得上」：认出身份的手机连着，或者位图对得上的溢出区广播（2 分钟没有就先不看位图）
    DateTime lastOverflowMatch = DateTime.UtcNow;
    /// 留着引用，StateChanged 才一直有
    Radio? radio;
    BluetoothLEAdvertisementWatcher? watcher;
    bool watcherStarting;
    /// 正在连的那一台：同一时间只连一台（记得的地址、扫描发现、溢出区候选都走这一个口子）
    Peer? connecting;
    readonly System.Windows.Forms.Timer tick = new() { Interval = 2000 };
    readonly System.Windows.Forms.Timer health = new() { Interval = 10_000 };
    readonly System.Windows.Forms.Timer codeExpiry = new();

    /// 每个 WinRT 异步调用最多等多久
    static readonly TimeSpan OpTimeout = TimeSpan.FromSeconds(10);
    /// 等前一次连接 / 释放做完最多等多久（释放卡住了也不能让以后永远连不上）
    static readonly TimeSpan GateTimeout = TimeSpan.FromSeconds(20);
    /// 连接和释放蓝牙对象排成一队（都在线程池上）
    readonly SemaphoreSlim bleGate = new(1, 1);

    /// 扫描回调线程上判断「这个地址连着没有」用的副本：UI 线程每次改 peers 都换一份新的（不在原地改）
    volatile HashSet<ulong> peerAddresses = new();
    readonly record struct Advert(ulong Address, BluetoothAddressType Type, int Rssi, bool Ours, byte[]? Overflow, string Name, DateTime At);
    readonly System.Collections.Concurrent.ConcurrentQueue<Advert> advertQueue = new();
    int advertDrainPosted;
    const int MaxQueuedAdverts = 2000;

    /// UI 线程上最近一次进入的蓝牙处理（UiWatchdog 卡住时写进日志）
    volatile string uiStep = "idle";

    /// 幕布现在是不是盖着；这次盖上的时刻 T（边沿规则从这里算）
    bool curtainClosed;
    DateTime? curtainClosedAt;
    /// 每台手机的撤下判断（按 phoneID，断开重连也留着「盖上之后见过锁着」）
    readonly Dictionary<Guid, LiftGate> gates = new();

    /// 一条连好的链路上的 WinRT 对象。在线程池上建、在线程池上放
    sealed class Link
    {
        public BluetoothLEDevice? Device;
        public GattSession? Session;
        public GattDeviceService? Service;
        public GattCharacteristic? Inbox, Outbox;
        public TypedEventHandler<BluetoothLEDevice, object>? StatusHandler;
        public TypedEventHandler<GattCharacteristic, GattValueChangedEventArgs>? ValueHandler;
        public TypedEventHandler<BluetoothLEDevice, object>? ServicesChangedHandler;
        public int MaxChunk = 20;
    }

    /// 一台连上（或正在连）的手机（只在 UI 线程上用）
    sealed class Peer(ulong address, BluetoothAddressType type)
    {
        public readonly ulong Address = address;
        public readonly BluetoothAddressType AddressType = type;
        /// 连好、订阅好以后才有
        public Link? Link;
        public bool Subscribed, Closed, LostWhileConnecting;
        public readonly CancellationTokenSource Cts = new();
        public readonly PairingFraming.Assembler Assembler = new();
        /// 链路交到 UI 线程之前就到了的通知块，交到以后按顺序补处理
        public readonly List<byte[]> EarlyChunks = new();
        /// 验过签名命令之后才知道它是哪台手机
        public Guid? PhoneID;
        public DateTime? ConnectedAt;
        public readonly Queue<byte[]> WriteQueue = new();
        public bool Writing, DisconnectAfterWrites;
        /// 连续写失败几次
        public int WriteErrors;
        /// 去连的是记得的地址（ConnectKnown）：扫到我们的广播时可以打断它
        public bool ViaKnown;
        public string Name => FormatAddress(Address);
        public int MaxChunk => Link?.MaxChunk ?? 20;
    }

    readonly Dictionary<ulong, Peer> peers = new();
    /// 暂时不理的地址（窗口关着时订阅上了却说不出自己是谁）；到点自动放出来
    readonly TimedIgnoreList<ulong> ignored = new();
    /// 每个地址最近收到的广播 RSSI（只记相关的：我们的服务 / 溢出区 / 连着的）
    readonly Dictionary<ulong, List<(int Rssi, DateTime At)>> adverts = new();
    readonly Dictionary<ulong, DateTime> lastCandidateTry = new();
    /// 系统醒了以后 3 秒再重启：只有一个计时器，再来一次 Resume 就重新计时
    readonly System.Windows.Forms.Timer resumeTimer = new() { Interval = 3000 };
    readonly ResumeDebounce resumeDebounce = new();
    int resumeArmed;
    /// 反复出现的日志（退避 / RSSI / 问询）：只在状态变了时写，或每分钟最多一行
    readonly LogThrottle logThrottle = new();
    static readonly TimeSpan RepeatLogEvery = TimeSpan.FromMinutes(1);

    public PhoneLink(SynchronizationContext ui, IPairingRecordStore? store = null)
    {
        this.ui = ui;
        authority = new PairingAuthority(store ?? new DpapiPairingStore(), PhoneLog.Write);
        tick.Tick += (_, _) => Tick();
        health.Tick += (_, _) => HealthCheck();
        resumeTimer.Tick += (_, _) => OnResumeTimer();
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
            var (r, state, problem) = await Task.Run(InitWork);
            if (problem != null)
            {
                PhoneLog.Write(problem);
                SetPhase(PhonePhase.Unsupported);
                return;
            }
            radio = r;
            if (state is { } s)
            {
                radioOn = s == RadioState.On;
                PhoneLog.Write($"central state {s}");
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

    /// 线程池上：找蓝牙适配器和它的无线电
    async Task<(Radio? Radio, RadioState? State, string? Problem)> InitWork()
    {
        var adapter = await Op("BluetoothAdapter.GetDefaultAsync", t => BluetoothAdapter.GetDefaultAsync().AsTask(t), CancellationToken.None).ConfigureAwait(false);
        if (adapter == null || !adapter.IsLowEnergySupported || !adapter.IsCentralRoleSupported)
            return (null, null, $"central: no usable bluetooth adapter (adapter {(adapter == null ? "missing" : $"le={adapter.IsLowEnergySupported} central={adapter.IsCentralRoleSupported}")})");
        var r = await Op("BluetoothAdapter.GetRadioAsync", t => adapter.GetRadioAsync().AsTask(t), CancellationToken.None).ConfigureAwait(false);
        if (r == null) return (null, null, null);
        r.StateChanged += (sender, _) =>
        {
            RadioState s;
            try { s = sender.State; } catch (Exception) { return; }
            ui.Post(_ => OnRadioState(s), null);
        };
        return (r, r.State, null);
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
        }
        ResetBackoffs("pairing window opened");
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

    /// 早断 / 记得的地址的退避全清零（唤醒、蓝牙重新打开、打开配对窗口、看到手机的广播）
    void ResetBackoffs(string why)
    {
        if (earlyDrops.Drops > 0 || knownBackoff.Step > 0)
            PhoneLog.Write($"backoff: reset ({why}; early drops {earlyDrops.Drops}, known-address step {knownBackoff.Step})");
        earlyDrops.Reset();
        knownBackoff.Reset();
    }

    /// 记得的手机：按地址连（它的地址没轮换、人在附近就能连上）。失败了退避（10 s → … → 5 min）
    void ConnectKnown(string reason)
    {
        if (!IsPaired || memory.Address is not { } address || peers.ContainsKey(address) || connecting != null) return;
        if (HasIdentifiedPeer) return;
        var now = DateTime.UtcNow;
        // 自检每 10 秒都会走到这里：同一个退避状态只写一行
        if (earlyDrops.Holding(now))
        {
            if (logThrottle.Changed("connectKnown", $"hold {earlyDrops.Drops}"))
                PhoneLog.Write($"backoff: early-drop hold, {earlyDrops.Remaining(now).TotalSeconds:0}s left; not connecting known address ({reason})");
            return;
        }
        if (knownBackoff.Holding(now))
        {
            if (logThrottle.Changed("connectKnown", $"known {knownBackoff.Step}"))
                PhoneLog.Write($"backoff: known address {FormatAddress(address)} retry in {knownBackoff.Remaining(now).TotalSeconds:0}s (step {knownBackoff.Step}); skipping ({reason})");
            return;
        }
        logThrottle.Changed("connectKnown", "connect");
        // iPhone 用的是随机地址
        Connect(address, BluetoothAddressType.Random, reason, viaKnown: true);
    }

    void StartWatcher()
    {
        if (radioOn != true || !ShouldRun || watcher != null || watcherStarting) return;
        watcherStarting = true;
        // 建扫描器、Start() 都在线程池上（Start 会去找蓝牙服务）
        _ = Task.Run(() =>
        {
            try
            {
                var nw = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
                nw.Received += OnReceived;
                nw.Stopped += OnWatcherStopped;
                nw.Start();
                var status = nw.Status;
                ui.Post(_ => WatcherStarted(nw, status, null), null);
            }
            catch (Exception e)
            {
                var error = $"{e.GetType().Name}: {e.Message}";
                ui.Post(_ => WatcherStarted(null, default, error), null);
            }
        });
    }

    void WatcherStarted(BluetoothLEAdvertisementWatcher? nw, BluetoothLEAdvertisementWatcherStatus status, string? error)
    {
        uiStep = "WatcherStarted";
        watcherStarting = false;
        if (nw == null)
        {
            PhoneLog.Write($"scan start failed: {error}");
            return;
        }
        // 开扫描器的这一会儿里又不该扫了（蓝牙关了 / 睡了 / 撤销了）：马上停
        if (radioOn != true || !ShouldRun)
        {
            StopOff(nw);
            return;
        }
        watcher = nw;
        PhoneLog.Write($"scan start (window {(windowOpen ? "open" : "closed")}, paired {IsPaired}, status {status})");
    }

    void OnWatcherStopped(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementWatcherStoppedEventArgs e)
    {
        var error = e.Error;
        ui.Post(_ =>
        {
            if (!ReferenceEquals(watcher, sender)) return;
            PhoneLog.Write($"scan stopped ({error})");
            watcher = null;
        }, null);
    }

    void StopWatcher()
    {
        if (watcher == null) return;
        var w = watcher;
        watcher = null;
        StopOff(w);
        PhoneLog.Write("scan stop");
    }

    /// 线程池上停扫描器
    void StopOff(BluetoothLEAdvertisementWatcher w) => _ = Task.Run(() =>
    {
        try
        {
            w.Received -= OnReceived;
            w.Stopped -= OnWatcherStopped;
            w.Stop();
        }
        catch (Exception) { }
    });

    /// 扫描回调（扫描器的线程上）：先在这里把无关的广播筛掉，相关的进队列，攒着一次 Post 回 UI 线程
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
            if (!ours && overflow == null && !peerAddresses.Contains(address)) return;
            if (advertQueue.Count >= MaxQueuedAdverts) return;
            advertQueue.Enqueue(new Advert(address, args.BluetoothAddressType, args.RawSignalStrengthInDBm, ours, overflow, ad.LocalName, DateTime.UtcNow));
            if (Interlocked.Exchange(ref advertDrainPosted, 1) == 0) ui.Post(_ => DrainAdverts(), null);
        }
        catch (Exception) { }
    }

    void DrainAdverts()
    {
        uiStep = "DrainAdverts";
        Volatile.Write(ref advertDrainPosted, 0);
        // 一次最多处理这么多，剩下的下一轮：UI 线程不会被一阵广播占住
        for (var n = 0; n < 200 && advertQueue.TryDequeue(out var a); n++)
            OnAdvertisement(a.Address, a.Type, a.Rssi, a.Ours, a.Overflow, a.Name, a.At);
        if (!advertQueue.IsEmpty && Interlocked.Exchange(ref advertDrainPosted, 1) == 0) ui.Post(_ => DrainAdverts(), null);
    }
    void OnAdvertisement(ulong address, BluetoothAddressType type, int rssi, bool ours, byte[]? overflow, string name, DateTime at)
    {
        if (!adverts.TryGetValue(address, out var list)) adverts[address] = list = new();
        list.Add((rssi, at));
        list.RemoveAll(x => at - x.At > TimeSpan.FromSeconds(10));
        if (adverts.Count > 64)
            foreach (var stale in adverts.Where(kv => kv.Value.Count == 0 || at - kv.Value[^1].At > TimeSpan.FromSeconds(30)).Select(kv => kv.Key).ToList())
                adverts.Remove(stale);

        // 认出来的手机自己的溢出区位图：和以前学的取交集（只留每次都在的位），以后只连位图对得上的
        if (overflow != null && peers.TryGetValue(address, out var known) && known.PhoneID != null && known.Subscribed)
        {
            var learned = OverflowBitmap.Intersect(memory.OverflowMask, overflow);
            if (memory.OverflowMask == null || !memory.OverflowMask.AsSpan().SequenceEqual(learned))
            {
                PhoneLog.Write($"learned background advertisement bitmap of {Who(known.PhoneID.Value)}: {Bytes.Hex(learned)} (observed {Bytes.Hex(overflow)})");
                memory.LearnOverflowMask(learned);
            }
        }
        if (HasIdentifiedPeer) lastOverflowMatch = at;

        // 我们的广播（手机 App 在前台）：手机就在附近、App 在跑，退避全清零
        if (ours && IsPaired && !HasIdentifiedPeer && (knownBackoff.Step > 0 || earlyDrops.Drops > 0)) ResetBackoffs("our advertisement seen");

        if (!ShouldRun || peers.ContainsKey(address) || ignored.Contains(address, at)) return;
        // 已经有一台验明身份的手机连着、窗口也没开：不用再连别的
        if (!windowOpen && HasIdentifiedPeer) return;
        string reason;
        if (ours) reason = "discovered by scan";
        else
        {
            // 溢出区候选：只在配过、没连着的时候；学到过位图就要对得上（2 分钟都没对得上的，先不看位图）
            if (overflow == null || !IsPaired || HasIdentifiedPeer) return;
            if (memory.OverflowMask is { } mask && !OverflowBitmap.Contains(overflow, mask))
            {
                if (at - lastOverflowMatch < OverflowFallbackAfter) return;
                reason = "discovered by scan (apple background advertisement, unfiltered fallback: no bitmap match for 2 min)";
            }
            else
            {
                if (memory.OverflowMask != null) lastOverflowMatch = at;
                reason = "discovered by scan (apple background advertisement)";
            }
        }
        // 正在连记得的旧地址（可能已经轮换掉了），而扫到的是我们的广播：打断它，先连扫到的
        if (ours && connecting is { ViaKnown: true } oldTry && oldTry.Address != address && !oldTry.Closed)
        {
            PhoneLog.Write($"connect to known address {oldTry.Name} pre-empted: our advertisement seen from {FormatAddress(address)}");
            Drop(oldTry, null);
            connecting = null;
        }
        // 同一时间只连一台：正在连就先不理（不记这次尝试，下一个广播再来）
        if (connecting != null) return;
        if (lastCandidateTry.TryGetValue(address, out var last) && at - last < CandidateRetry) return;
        // 同一时间只连一台候选，免得一屋子 iPhone 都去连
        if (!ours && peers.Values.Any(p => p.ConnectedAt == null || p.PhoneID == null)) return;
        lastCandidateTry[address] = at;
        PhoneLog.Write($"discovered {FormatAddress(address)} name={(string.IsNullOrEmpty(name) ? "(no name)" : name)} rssi={rssi}{(ours ? "" : " (background)")}");
        Connect(address, type, reason);
    }

    void Connect(ulong address, BluetoothAddressType type, string reason, bool viaKnown = false)
    {
        if (peers.ContainsKey(address)) return;
        if (connecting != null)
        {
            PhoneLog.Write($"connect to {FormatAddress(address)} ({reason}) deferred: still connecting {connecting.Name}");
            return;
        }
        var peer = new Peer(address, type) { ViaKnown = viaKnown };
        peers[address] = peer;
        RefreshPeerAddresses();
        PhoneLog.Write($"connect requested {peer.Name} ({reason})");
        _ = ConnectAsync(peer);
    }

    void RefreshPeerAddresses() => peerAddresses = new HashSet<ulong>(peers.Keys);

    async Task ConnectAsync(Peer peer)
    {
        connecting = peer;
        (Link? Link, bool Connected, string? Error) r;
        try { r = await Task.Run(() => ConnectWork(peer)); }
        catch (Exception e) { r = (null, false, $"{e.GetType().Name}: {e.Message}"); }
        uiStep = "ConnectAsync result";
        if (ReferenceEquals(connecting, peer)) connecting = null;
        if (peer.Closed)
        {
            if (r.Link != null) DisposeOff(r.Link, peer.Name);
            return;
        }
        if (r.Link == null)
        {
            if (!r.Connected) FailConnect(peer, r.Error ?? "unknown");
            else
            {
                peer.ConnectedAt ??= DateTime.UtcNow;
                Disconnected(peer, r.Error ?? "unknown");
            }
            return;
        }
        peer.Link = r.Link;
        peer.ConnectedAt = DateTime.UtcNow;
        peer.Subscribed = true;
        ResetBackoffs("subscribed");
        PhoneLog.Write($"subscribed outbox on {peer.Name}");
        UpdateTick();
        if (!windowOpen) ScheduleIdentifyCheck(peer);
        var early = peer.EarlyChunks.ToList();
        peer.EarlyChunks.Clear();
        foreach (var c in early) OnChunk(peer, c);
        if (peer.LostWhileConnecting && !peer.Closed) Disconnected(peer, "link lost while connecting");
    }

    /// 线程池上：连接的全过程，每一步最多等 OpTimeout。成功时把链路交出去，失败时自己放掉（还在线程池上）
    async Task<(Link? Link, bool Connected, string? Error)> ConnectWork(Peer peer)
    {
        var ct = peer.Cts.Token;
        var held = false;
        Link? link = new();
        var connected = false;
        try
        {
            // 等前面的连接 / 释放做完：同一台手机的旧对象还没放掉就去连新的，蓝牙栈可能卡住
            held = await bleGate.WaitAsync(GateTimeout, ct).ConfigureAwait(false);
            if (!held) PhoneLog.Write($"ble: previous connect/release still running after {GateTimeout.TotalSeconds:0}s; connecting {peer.Name} anyway");

            var address = peer.Address;
            var type = peer.AddressType;
            var device = link.Device = await Op("FromBluetoothAddressAsync", t => (type == BluetoothAddressType.Unspecified
                ? BluetoothLEDevice.FromBluetoothAddressAsync(address)
                : BluetoothLEDevice.FromBluetoothAddressAsync(address, type)).AsTask(t), ct).ConfigureAwait(false);
            if (device == null) return (null, false, "device not available");
            link.StatusHandler = (d, _) =>
            {
                BluetoothConnectionStatus s;
                try { s = d.ConnectionStatus; } catch (Exception) { return; }
                ui.Post(_ => OnConnectionStatus(peer, s), null);
            };
            device.ConnectionStatusChanged += link.StatusHandler;
            // 手机的 GATT 服务变了（App 重启而连接没断）：旧的特征都作废了，当断开处理
            link.ServicesChangedHandler = (_, _) => ui.Post(_ => OnServicesChanged(peer), null);
            device.GattServicesChanged += link.ServicesChangedHandler;
            try
            {
                var session = link.Session = await Op("GattSession.FromDeviceIdAsync",
                    t => GattSession.FromDeviceIdAsync(device.BluetoothDeviceId).AsTask(t), ct).ConfigureAwait(false);
                if (session != null) session.MaintainConnection = true;
            }
            catch (Exception e) when (!ct.IsCancellationRequested)
            {
                PhoneLog.Write($"gatt session for {peer.Name} failed: {e.Message}");
            }

            var services = await Op("GetGattServicesForUuidAsync",
                t => device.GetGattServicesForUuidAsync(ServiceUuid, BluetoothCacheMode.Uncached).AsTask(t), ct).ConfigureAwait(false);
            if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
            {
                foreach (var s in services.Services) s.Dispose();
                // 连不上（Unreachable）或者没有我们的服务（不是 LockCurtain 手机）
                return (null, false, services.Status == GattCommunicationStatus.Success ? "service not found" : $"gatt {services.Status}");
            }
            var service = link.Service = services.Services[0];
            foreach (var extra in services.Services.Skip(1)) extra.Dispose();
            connected = true;
            PhoneLog.Write($"connected {peer.Name}");

            var chars = await Op("GetCharacteristicsAsync",
                t => service.GetCharacteristicsAsync(BluetoothCacheMode.Uncached).AsTask(t), ct).ConfigureAwait(false);
            if (chars.Status == GattCommunicationStatus.Success)
                foreach (var c in chars.Characteristics)
                {
                    if (c.Uuid == OutboxUuid) link.Outbox = c;
                    if (c.Uuid == InboxUuid) link.Inbox = c;
                }
            if (link.Outbox is not { } outbox || link.Inbox == null)
                return (null, true, $"characteristics missing ({chars.Status})");
            link.MaxChunk = Math.Max(20, (link.Session?.MaxPduSize ?? 23) - 3);
            PhoneLog.Write($"services ready on {peer.Name} (max write {link.MaxChunk})");

            link.ValueHandler = (_, e) =>
            {
                byte[] chunk;
                try { chunk = ReadBuffer(e.CharacteristicValue); } catch (Exception) { return; }
                ui.Post(_ => OnChunk(peer, chunk), null);
            };
            outbox.ValueChanged += link.ValueHandler;
            var sub = await Op("subscribe outbox",
                t => outbox.WriteClientCharacteristicConfigurationDescriptorWithResultAsync(
                    GattClientCharacteristicConfigurationDescriptorValue.Notify).AsTask(t), ct).ConfigureAwait(false);
            if (sub.Status != GattCommunicationStatus.Success)
                return (null, true, $"subscribe failed: {sub.Status}{(sub.ProtocolError is { } pe ? $" (att error {pe})" : "")}");

            var done = link;
            link = null;
            return (done, true, null);
        }
        catch (Exception e)
        {
            return (null, connected, ct.IsCancellationRequested ? "cancelled" : $"{e.GetType().Name}: {e.Message}");
        }
        finally
        {
            if (link != null) ReleaseNow(link, peer.Name);
            if (held) bleGate.Release();
        }
    }

    /// 线程池上调一个 WinRT 异步方法，最多等 OpTimeout：到时取消；取消也不理的，再多等 2 秒就不等了
    /// （晚到的结果是可释放的就在线程池上放掉）。超时抛 TimeoutException
    static async Task<T> Op<T>(string what, Func<CancellationToken, Task<T>> start, CancellationToken outer)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(outer);
        cts.CancelAfter(OpTimeout);
        var task = start(cts.Token);
        try
        {
            return await task.WaitAsync(OpTimeout + TimeSpan.FromSeconds(2), outer).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!outer.IsCancellationRequested)
        {
            Abandon(task);
            throw new TimeoutException($"{what} timed out after {OpTimeout.TotalSeconds:0}s");
        }
        catch (TimeoutException)
        {
            Abandon(task);
            throw new TimeoutException($"{what} ignored cancellation after {OpTimeout.TotalSeconds:0}s");
        }
        catch (OperationCanceledException)
        {
            Abandon(task);
            throw;
        }
    }

    static void Abandon<T>(Task<T> task) => task.ContinueWith(t =>
    {
        if (t.IsCompletedSuccessfully && t.Result is IDisposable d)
            try { d.Dispose(); } catch (Exception) { }
        _ = t.Exception;
    }, TaskScheduler.Default);

    /// 放掉一条链路的 WinRT 对象（Windows 上放掉了才真的断开）。只在线程池上调：Dispose 可能要等好几秒
    static void ReleaseNow(Link l, string name)
    {
        var clock = System.Diagnostics.Stopwatch.StartNew();
        try { if (l.Outbox != null && l.ValueHandler != null) l.Outbox.ValueChanged -= l.ValueHandler; } catch (Exception) { }
        try { if (l.Device != null && l.StatusHandler != null) l.Device.ConnectionStatusChanged -= l.StatusHandler; } catch (Exception) { }
        try { if (l.Device != null && l.ServicesChangedHandler != null) l.Device.GattServicesChanged -= l.ServicesChangedHandler; } catch (Exception) { }
        try { if (l.Session != null) l.Session.MaintainConnection = false; } catch (Exception) { }
        try { l.Service?.Dispose(); } catch (Exception) { }
        try { l.Session?.Dispose(); } catch (Exception) { }
        try { l.Device?.Dispose(); } catch (Exception) { }
        if (clock.ElapsedMilliseconds > 500) PhoneLog.Write($"ble: releasing {name} took {clock.ElapsedMilliseconds} ms");
    }

    /// 排进队里、在线程池上放掉
    void DisposeOff(Link l, string name) => _ = Task.Run(async () =>
    {
        var held = await bleGate.WaitAsync(GateTimeout).ConfigureAwait(false);
        try { ReleaseNow(l, name); }
        finally { if (held) bleGate.Release(); }
    });

    /// 没连上（对应 Mac 的 didFailToConnect）：丢掉，继续扫
    void FailConnect(Peer peer, string why)
    {
        PhoneLog.Write($"failed to connect {peer.Name}: {why}");
        Drop(peer, null);
        if (peer.ViaKnown && IsPaired)
        {
            // 记得的地址连不上（地址轮换掉了 / 手机 App 没在跑）：退避，别一直占着唯一的连接口子
            var d = knownBackoff.Fail(DateTime.UtcNow);
            PhoneLog.Write($"backoff: known address {peer.Name} failed (step {knownBackoff.Step}); next try in {d.TotalSeconds:0}s");
        }
        StartWatcher();
    }

    void OnServicesChanged(Peer peer)
    {
        uiStep = "OnServicesChanged";
        if (peer.Closed || peer.Link == null) return;
        PhoneLog.Write($"gatt services changed on {peer.Name}");
        peer.ConnectedAt ??= DateTime.UtcNow;
        Disconnected(peer, "gatt services changed", ownCancel: true);
    }

    void OnConnectionStatus(Peer peer, BluetoothConnectionStatus status)
    {
        uiStep = "OnConnectionStatus";
        if (peer.Closed) return;
        PhoneLog.Write($"connection status {peer.Name}: {status}");
        if (peer.Link == null)
        {
            // 还在连：等连接那边做完再算
            peer.LostWhileConnecting = status == BluetoothConnectionStatus.Disconnected;
            return;
        }
        if (status == BluetoothConnectionStatus.Disconnected) Disconnected(peer, "link lost");
    }

    /// 断了（对应 Mac 的 didDisconnectPeripheral）。ownCancel = 我们自己判定链路死了（服务变了 / 写失败），不算早断
    void Disconnected(Peer peer, string why, bool ownCancel = false)
    {
        if (peer.Closed) return;
        var wasReady = peer.Subscribed;
        var duration = peer.ConnectedAt is { } t ? $"{(DateTime.UtcNow - t).TotalSeconds:0.0}s" : "?";
        PhoneLog.Write($"disconnected {peer.Name} after {duration}, ready={wasReady.ToString().ToLowerInvariant()}: {why}");
        var wasIdentified = peer.PhoneID != null;
        Drop(peer, null);
        var now = DateTime.UtcNow;

        if (!ownCancel && !wasReady && ShouldRun && !ignored.Contains(peer.Address, now))
        {
            var (outcome, delay) = earlyDrops.NoteDrop(IsPaired, now);
            switch (outcome)
            {
                case EarlyDropOutcome.KeepGoing:
                    PhoneLog.Write($"early drop {earlyDrops.Drops}/{EarlyDropPolicy.MaxEarlyDrops}");
                    break;
                case EarlyDropOutcome.Backoff:
                    // 配过对：不停手，只是先不去连记得的地址；扫描照开，看到我们的广播马上连
                    PhoneLog.Write($"early drop {earlyDrops.Drops} (paired): backoff {delay.TotalSeconds:0}s before reconnecting the known address; scanning stays on");
                    break;
                case EarlyDropOutcome.Stop:
                    // 没配过手机（只开着配对窗口）：硬停，等重新打开窗口
                    stoppedAfterEarlyDrops = true;
                    StopWatcher();
                    foreach (var p in peers.Values.ToList()) Drop(p, null);
                    PhoneLog.Write($"stopped after {EarlyDropPolicy.MaxEarlyDrops} early drops (not paired); reopen the pairing window to retry");
                    return;
            }
        }
        if (!ShouldRun) return;
        if (!ignored.Contains(peer.Address, now) && wasIdentified && IsPaired) ConnectKnown("pending reconnect after drop");
        StartWatcher();
    }

    /// 从 UI 的状态里拿掉这台；它的 WinRT 对象排进队里在线程池上放（绝不在 UI 线程上，也不在它自己的事件回调里）
    void Drop(Peer peer, string? why)
    {
        if (peer.Closed) return;
        uiStep = "Drop";
        peer.Closed = true;
        if (why != null) PhoneLog.Write($"dropping {peer.Name}: {why}");
        if (peers.TryGetValue(peer.Address, out var cur) && ReferenceEquals(cur, peer))
        {
            peers.Remove(peer.Address);
            RefreshPeerAddresses();
        }
        if (peer.PhoneID is { } id && gates.TryGetValue(id, out var g)) g.ResetRSSI();
        peer.WriteQueue.Clear();
        peer.EarlyChunks.Clear();
        peer.Subscribed = false;
        // 取消正在等的 WinRT 调用：CancelAsync 在线程池上跑回调（回调里是 IAsyncInfo.Cancel，跨进程）
        _ = peer.Cts.CancelAsync();
        if (peer.Link is { } link)
        {
            peer.Link = null;
            DisposeOff(link, peer.Name);
        }
        UpdateTick();
    }
    void DropAll(string why)
    {
        if (peers.Count == 0) return;
        PhoneLog.Write($"{why}: dropping {peers.Count} stale peer(s)");
        foreach (var p in peers.Values.ToList()) Drop(p, null);
    }

    /// 窗口关着时订阅上一台说不出身份的手机：等 IdentifyTimeout，还不说就断开、这个地址暂时不理（30 s → … → 5 min，到点放出来）
    void ScheduleIdentifyCheck(Peer peer)
    {
        var t = new System.Windows.Forms.Timer { Interval = (int)IdentifyTimeout.TotalMilliseconds };
        t.Tick += (_, _) =>
        {
            t.Stop();
            t.Dispose();
            if (peer.Closed || peer.PhoneID != null || windowOpen) return;
            var d = ignored.Ignore(peer.Address, DateTime.UtcNow);
            PhoneLog.Write($"peripheral {peer.Name} did not identify within {(int)IdentifyTimeout.TotalSeconds}s of subscribing; ignoring it for {d.TotalSeconds:0}s");
            Drop(peer, null);
            StartWatcher();
        };
        t.Start();
    }

    // MARK: - 系统事件

    void OnRadioState(RadioState state)
    {
        uiStep = "OnRadioState";
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
            ResetBackoffs("bluetooth on");
            Resume();
        }
    }

    void OnPowerMode(PowerModes mode)
    {
        uiStep = "OnPowerMode";
        if (mode == PowerModes.Suspend)
        {
            PhoneLog.Write("system suspend");
            resumeTimer.Stop();
            resumeDebounce.Cancel();
            suspended = true;
            suspendedAt = DateTime.UtcNow;
            DropAll("system suspend");
            StopWatcher();
        }
        else if (mode == PowerModes.Resume)
        {
            // 同一次醒来常常连报两次 Resume：只留一个计时，重新计时（第二个计时到点会把第一个刚连上的断掉）
            PhoneLog.Write(resumeDebounce.Pending ? "system resume again: restarting the 3s timer" : "system resume: restarting in 3s");
            resumeArmed = resumeDebounce.Arm();
            resumeTimer.Stop();
            resumeTimer.Start();
        }
    }

    void OnResumeTimer()
    {
        uiStep = "OnResumeTimer";
        resumeTimer.Stop();
        if (!resumeDebounce.Fire(resumeArmed)) return;
        suspended = false;
        suspendedAt = null;
        // 睡眠中蓝牙栈可能重置过，旧连接全当作废
        DropAll("system resume");
        StopWatcher();
        ignored.Clear();
        lastCandidateTry.Clear();
        ResetBackoffs("system resume");
        Resume();
    }

    /// 每 10 秒（配过就一直跑，不管早断）：漏了 Resume 的「睡着了」超过 60 秒就当醒了；扫描器没在跑 / Aborted / Stopped 就重启；
    /// 放出到点的不理地址；配过、没连着就（按退避）重连记得的地址
    void HealthCheck()
    {
        uiStep = "HealthCheck";
        var now = DateTime.UtcNow;
        // 这个计时器只在醒着时跑：「睡着了」挂了这么久，一定是漏了 Resume 事件
        if (suspended && suspendedAt is { } since && now - since > StaleSuspend)
        {
            PhoneLog.Write($"health: suspended for {(now - since).TotalSeconds:0}s without a resume event; treating as resumed");
            suspended = false;
            suspendedAt = null;
            ignored.Clear();
            lastCandidateTry.Clear();
            ResetBackoffs("stale suspend cleared");
        }
        var released = ignored.Expire(now);
        if (released.Count > 0) PhoneLog.Write($"health: ignore expired for {string.Join(", ", released.Select(FormatAddress))}");
        if (!initialized || radioOn != true || !ShouldRun) return;
        if (watcher is { } w)
        {
            BluetoothLEAdvertisementWatcherStatus status;
            try { status = w.Status; } catch (Exception) { status = BluetoothLEAdvertisementWatcherStatus.Aborted; }
            if (status is BluetoothLEAdvertisementWatcherStatus.Aborted or BluetoothLEAdvertisementWatcherStatus.Stopped)
            {
                PhoneLog.Write($"health: scanner status {status}, restarting");
                watcher = null;
                StopOff(w);
                StartWatcher();
            }
        }
        else if (!watcherStarting)
        {
            PhoneLog.Write("health: scanner not running, restarting");
            StartWatcher();
        }
        if (IsPaired && !HasIdentifiedPeer) ConnectKnown("pending reconnect to known phone (health check)");
    }

    /// UiWatchdog 用（在它自己的线程上调）：这里的状态一行字。读的是 UI 线程的字段，读乱了就少写点
    public string DescribeState()
    {
        try
        {
            var list = peers.Values.ToList().Select(p =>
                $"{p.Name}{(p.PhoneID != null ? " identified" : "")}{(p.Subscribed ? " subscribed" : p.Link == null ? " connecting" : "")}" +
                $"{(p.Writing ? " writing" : "")} q={p.WriteQueue.Count}");
            return $"last ble step on UI: {uiStep}; radio {(radioOn?.ToString() ?? "?")}, scanner {(watcher != null ? "on" : watcherStarting ? "starting" : "off")}, " +
                   $"connecting {connecting?.Name ?? "-"}, window {(windowOpen ? "open" : "closed")}, covered {curtainClosed}, " +
                   $"queued adverts {advertQueue.Count}, peers [{string.Join("; ", list)}]";
        }
        catch (Exception e) { return $"last ble step on UI: {uiStep}; (state unreadable: {e.GetType().Name})"; }
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
        uiStep = "Tick";
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
            if (logThrottle.ShouldLog($"rssi.{peer.Address}", "failed", now, RepeatLogEvery))
                PhoneLog.Write($"rssi {peer.Name} read failed: no advertisement in the last {RssiWindow.TotalSeconds:0.#}s");
            return;
        }
        var value = (int)Math.Round(recent.Average());
        // 每 2 秒一个样本：每分钟最多写一行
        if (logThrottle.ShouldLog($"rssi.{peer.Address}", "ok", now, RepeatLogEvery))
            PhoneLog.Write($"rssi {peer.Name} {value} (advertisements n={recent.Count}, [{string.Join(",", recent)}]; logged at most once a minute)");
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
        if (!curtainClosed || peer.PhoneID is not { } id || !peer.Subscribed || peer.Link == null) return;
        // 上一条还没写完（手机没回执）就不再堆
        if (peer.WriteQueue.Count > 0 || peer.Writing)
        {
            if (logThrottle.ShouldLog($"poll.{id}", "skipped", DateTime.UtcNow, RepeatLogEvery))
                PhoneLog.Write($"lift: poll skipped for {Who(id)}: previous write still pending");
            return;
        }
        var nonce = PairingCrypto.MakeNonce();
        if (authority.PollMessage(nonce, id) is not { } message) return;
        Gate(id).Issue(nonce, DateTime.UtcNow);
        if (logThrottle.ShouldLog($"poll.{id}", "sent", DateTime.UtcNow, RepeatLogEvery))
            PhoneLog.Write($"lift: poll sent to {Who(id)} nonce {Short(nonce)} (logged at most once a minute)");
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
        if (peer.Link == null || peer.Closed)
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
            if (peer.Link?.Inbox is not { } inbox) return;
            peer.Writing = true;
            var chunk = peer.WriteQueue.Dequeue();
            var token = peer.Cts.Token;
            (string? Error, bool TimedOut) r;
            try { r = await Task.Run(() => WriteWork(inbox, chunk, token)); }
            finally { peer.Writing = false; }
            uiStep = "Pump result";
            if (peer.Closed) return;
            if (r.Error == null)
            {
                peer.WriteErrors = 0;
                continue;
            }
            peer.WriteErrors++;
            PhoneLog.Write($"write to inbox of {peer.Name} failed ({peer.WriteErrors}/{MaxWriteErrors}): {r.Error}");
            peer.WriteQueue.Clear();
            // 写了 10 秒没回执：链路已经死了（手机走远了），当断开处理，好重新连
            if (r.TimedOut)
            {
                peer.ConnectedAt ??= DateTime.UtcNow;
                Disconnected(peer, "write timed out");
                return;
            }
            // 连着写失败好几次（Unreachable / ATT 错误…）：链路也是死的，当断开处理
            if (peer.WriteErrors >= MaxWriteErrors)
            {
                peer.ConnectedAt ??= DateTime.UtcNow;
                Disconnected(peer, $"{peer.WriteErrors} consecutive write failures", ownCancel: true);
                return;
            }
        }
    }

    /// 线程池上：写一块，要回执
    static async Task<(string? Error, bool TimedOut)> WriteWork(GattCharacteristic inbox, byte[] chunk, CancellationToken ct)
    {
        try
        {
            var r = await Op("write inbox", t => inbox.WriteValueWithResultAsync(ToBuffer(chunk), GattWriteOption.WriteWithResponse).AsTask(t), ct)
                .ConfigureAwait(false);
            return r.Status == GattCommunicationStatus.Success
                ? (null, false)
                : ($"{r.Status}{(r.ProtocolError is { } pe ? $" (att error {pe})" : "")}", false);
        }
        catch (TimeoutException e) { return (e.Message, true); }
        catch (OperationCanceledException) { return ("cancelled", false); }
        catch (Exception e) { return ($"{e.GetType().Name}: {e.Message}", false); }
    }

    void OnChunk(Peer peer, byte[] chunk)
    {
        uiStep = "OnChunk";
        if (peer.Closed) return;
        if (peer.Link == null)
        {
            peer.EarlyChunks.Add(chunk);
            return;
        }
        if (peer.Assembler.Feed(chunk) is { } message) Receive(message, peer);
    }

    void Receive(byte[] message, Peer peer)
    {
        uiStep = $"Receive {PairingCrypto.KindOf(message)}";
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
                ignored.Forgive(peer.Address);
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
            // 每 2 秒一条：状态变了才写，没变每分钟最多一行
            if (logThrottle.ShouldLog($"presence.{id}", word, now, RepeatLogEvery))
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
            var why = Describe(decision);
            if (answer.IsLiftNow || logThrottle.ShouldLog($"refuse.{id}", why, now, RepeatLogEvery))
                PhoneLog.Write($"lift: {label}: refused, {why}");
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
