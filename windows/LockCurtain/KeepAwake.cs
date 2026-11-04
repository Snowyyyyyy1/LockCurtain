// KeepAwake.cs —— 保持唤醒：不盖遮罩，只让电脑不睡（对应 Mac 版 KeepAwake.swift）
//
// 用电源请求 PowerSetRequest(SystemRequired)，不要求显示器：屏幕照样会熄灭，合盖、按电源键照样睡。
// 和离开模式的 PowerGuard（SetThreadExecutionState，跟着 UI 线程走）互不干扰。
// 请求的原因写「LockCurtain 保持唤醒」，powercfg /requests 里看得到；托盘面板列阻止睡眠的程序时不列自己。
// 三种：一直；到某个时刻（定的时长，或「到指定时间…」定的时刻）；某个程序开着时（它退出就结束）。每 2 秒查一次到点没有、程序还在不在。
// 手机也能开关（awake:*，protocol v3）：只有一直 / 1、2、5 小时 / 关；每次变了都发 KeepAwakeState 给手机（TrayApp 接线）。
// 会话存进 settings.json，退出 LockCurtain 不结束，下次启动接着来：已经过点的、绑定的程序没在运行的不恢复。

using System.Diagnostics;
using LockCurtain.Phone;

namespace LockCurtain;

/// 保持唤醒的三种方式
internal abstract record KeepAwakeMode
{
    public sealed record Forever : KeepAwakeMode;
    /// Clock：「到指定时间…」定的时刻（手机显示「到 18:30」）；否则是定的时长（手机显示「还剩 …」）
    public sealed record Until(DateTime EndUtc, bool Clock = false) : KeepAwakeMode;
    /// 绑定一个进程：Pid 加启动时间认准是同一个（pid 会被复用），Path 用来下次启动时再找它
    public sealed record WhileRunning(int Pid, DateTime Started, string Path, string Name) : KeepAwakeMode;
}

/// 存进 settings.json 的样子，和 Mac 版 keepAwake 的字典对应：kind 是 forever / date / app
internal sealed record KeepAwakeSaved(string Kind, DateTime? End = null, string? Path = null, string? Name = null,
                                      bool Clock = false, bool Phone = false);

internal sealed class KeepAwake : IDisposable
{
    const string Reason = "LockCurtain 保持唤醒";

    readonly System.Windows.Forms.Timer check = new() { Interval = 2000 };
    nint request;

    public KeepAwakeMode? Mode { get; private set; }
    /// 这一次是手机开的（设置页详情后面加「· 手机开的」）
    public bool StartedByPhone { get; private set; }
    public event Action? Changed;

    public KeepAwake() => check.Tick += (_, _) => Check();

    public void Start(KeepAwakeMode mode, bool byPhone = false)
    {
        if (request == 0)
        {
            var context = new Native.REASON_CONTEXT { Flags = Native.POWER_REQUEST_CONTEXT_SIMPLE_STRING, SimpleReasonString = Reason };
            var h = Native.PowerCreateRequest(ref context);
            if (h == -1 || h == 0 || !Native.PowerSetRequest(h, Native.PowerRequestSystemRequired))
            {
                Log.Write($"KeepAwake: 电源请求失败 error={System.Runtime.InteropServices.Marshal.GetLastWin32Error()}");
                if (h != -1 && h != 0) Native.CloseHandle(h);
                return;
            }
            request = h;
        }
        Mode = mode;
        StartedByPhone = byPhone;
        check.Start();
        Save();
        Log.Write($"KeepAwake start {mode}{(byPhone ? " (phone)" : "")}");
        Changed?.Invoke();
    }

    public void Stop()
    {
        if (Mode == null) return;
        Release();
        Mode = null;
        StartedByPhone = false;
        check.Stop();
        Save();
        Log.Write("KeepAwake stop");
        Changed?.Invoke();
    }

    /// 启动时调：接着上次没结束的那次
    public void Restore()
    {
        var saved = Settings.Current.KeepAwake;
        if (saved == null) return;
        KeepAwakeMode? mode = saved.Kind switch
        {
            "forever" => new KeepAwakeMode.Forever(),
            "date" when saved.End is { } end && end.ToUniversalTime() > DateTime.UtcNow => new KeepAwakeMode.Until(end.ToUniversalTime(), saved.Clock),
            "app" when saved.Path != null => FindRunning(saved.Path, saved.Name ?? Path.GetFileNameWithoutExtension(saved.Path)),
            _ => null,
        };
        if (mode != null) Start(mode, saved.Phone);
        else Settings.Update(s => s.KeepAwake = null);
    }

    /// 绑定某个正在运行的程序
    public static KeepAwakeMode.WhileRunning? Bind(Process p, string name)
    {
        try { return ProcessInfo.PathOf(p.Id) is { } path ? new(p.Id, p.StartTime, path, name) : null; }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { return null; }
    }

    static KeepAwakeMode.WhileRunning? FindRunning(string path, string name)
    {
        foreach (var p in Process.GetProcesses())
            using (p)
                if (string.Equals(ProcessInfo.PathOf(p.Id), path, StringComparison.OrdinalIgnoreCase) && Bind(p, name) is { } bound)
                    return bound;
        return null;
    }

    void Check()
    {
        var over = Mode switch
        {
            KeepAwakeMode.Until u => DateTime.UtcNow >= u.EndUtc,
            KeepAwakeMode.WhileRunning w => !IsRunning(w),
            _ => false,
        };
        if (over) Stop();
    }

    static bool IsRunning(KeepAwakeMode.WhileRunning w)
    {
        try
        {
            using var p = Process.GetProcessById(w.Pid);
            return !p.HasExited && p.StartTime == w.Started;
        }
        catch (ArgumentException) { return false; }                     // 没有这个 pid 了
        catch (InvalidOperationException) { return false; }             // 刚退出
        catch (System.ComponentModel.Win32Exception) { return true; }   // 没权限查，当它还在
    }

    void Save() => Settings.Update(s => s.KeepAwake = Mode switch
    {
        KeepAwakeMode.Forever => new("forever", Phone: StartedByPhone),
        KeepAwakeMode.Until u => new("date", End: u.EndUtc, Clock: u.Clock, Phone: StartedByPhone),
        KeepAwakeMode.WhileRunning w => new("app", Path: w.Path, Name: w.Name, Phone: StartedByPhone),
        _ => null,
    });

    /// 发给手机的现状（KeepAwakeState）
    public KeepAwakeWireState Wire() => Mode switch
    {
        KeepAwakeMode.Forever => KeepAwakeWireState.Make(KeepAwakeWireMode.Always),
        KeepAwakeMode.Until u => KeepAwakeWireState.Make(u.Clock ? KeepAwakeWireMode.UntilClock : KeepAwakeWireMode.Timed, u.EndUtc),
        KeepAwakeMode.WhileRunning w => KeepAwakeWireState.Make(KeepAwakeWireMode.WhileApp, app: w.Name),
        _ => KeepAwakeWireState.Off,
    };

    /// 手机的 awake:*：一直 / 从现在起多久 / 关
    public void Apply(AwakeRequest request)
    {
        switch (request.Kind)
        {
            case AwakeRequestKind.Off: Stop(); break;
            case AwakeRequestKind.Always: Start(new KeepAwakeMode.Forever(), byPhone: true); break;
            case AwakeRequestKind.For: Start(new KeepAwakeMode.Until(DateTime.UtcNow + request.Duration), byPhone: true); break;
        }
    }

    // MARK: - 界面上的字（托盘面板、设置 › 保持唤醒、右键菜单共用）

    /// 面板 / 设置页那一行的详情（三种写法）
    public string Detail() => Mode switch
    {
        KeepAwakeMode.Forever => "直到你点停止；屏幕照样会熄灭",
        KeepAwakeMode.Until u => $"到{(u.EndUtc.ToLocalTime().Date == DateTime.Today ? "" : "明天 ")}{u.EndUtc.ToLocalTime():HH:mm}，还剩 {UiText.Duration(u.EndUtc - DateTime.UtcNow)}",
        KeepAwakeMode.WhileRunning w => $"{w.Name} 退出就结束",
        _ => "",
    };

    /// 右键菜单「保持唤醒 ▸」在跑时置灰的那行（copy v15.1 §17.4）
    public string MenuStatus() => Mode switch
    {
        KeepAwakeMode.Forever => "一直开着，点「停止」才停",
        KeepAwakeMode.Until { Clock: true } u => $"到 {u.EndUtc.ToLocalTime():HH:mm}，到点自己停",
        KeepAwakeMode.Until u => $"{UiText.Remaining(u.EndUtc - DateTime.UtcNow)}，到点自己停",
        KeepAwakeMode.WhileRunning w => $"{w.Name} 开着，关掉就停",
        _ => "关",
    };

    void Release()
    {
        if (request == 0) return;
        Native.PowerClearRequest(request, Native.PowerRequestSystemRequired);
        Native.CloseHandle(request);
        request = 0;
    }

    /// 退出 LockCurtain：放掉电源请求，但存着的会话留着，下次启动接着来
    public void Dispose()
    {
        check.Dispose();
        Release();
    }
}
