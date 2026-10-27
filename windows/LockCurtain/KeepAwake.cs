// KeepAwake.cs —— 保持唤醒：不盖遮罩，只让电脑不睡（对应 Mac 版 KeepAwake.swift）
//
// 用电源请求 PowerSetRequest(SystemRequired)，不要求显示器：屏幕照样会熄灭，合盖、按电源键照样睡。
// 和离开模式的 PowerGuard（SetThreadExecutionState，跟着 UI 线程走）互不干扰。
// 请求的原因写「LockCurtain 保持唤醒」，powercfg /requests 里看得到；托盘面板列阻止睡眠的程序时不列自己。
// 三种：一直；到某个时刻；某个程序开着时（它退出就结束）。每 2 秒查一次到点没有、程序还在不在。
// 会话存进 settings.json，退出 LockCurtain 不结束，下次启动接着来：已经过点的、绑定的程序没在运行的不恢复。

using System.Diagnostics;

namespace LockCurtain;

/// 保持唤醒的三种方式
internal abstract record KeepAwakeMode
{
    public sealed record Forever : KeepAwakeMode;
    public sealed record Until(DateTime EndUtc) : KeepAwakeMode;
    /// 绑定一个进程：Pid 加启动时间认准是同一个（pid 会被复用），Path 用来下次启动时再找它
    public sealed record WhileRunning(int Pid, DateTime Started, string Path, string Name) : KeepAwakeMode;
}

/// 存进 settings.json 的样子，和 Mac 版 keepAwake 的字典对应：kind 是 forever / date / app
internal sealed record KeepAwakeSaved(string Kind, DateTime? End = null, string? Path = null, string? Name = null);

internal sealed class KeepAwake : IDisposable
{
    const string Reason = "LockCurtain 保持唤醒";

    readonly System.Windows.Forms.Timer check = new() { Interval = 2000 };
    nint request;

    public KeepAwakeMode? Mode { get; private set; }
    public event Action? Changed;

    public KeepAwake() => check.Tick += (_, _) => Check();

    public void Start(KeepAwakeMode mode)
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
        check.Start();
        Save();
        Log.Write($"KeepAwake start {mode}");
        Changed?.Invoke();
    }

    public void Stop()
    {
        if (Mode == null) return;
        Release();
        Mode = null;
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
            "date" when saved.End is { } end && end.ToUniversalTime() > DateTime.UtcNow => new KeepAwakeMode.Until(end.ToUniversalTime()),
            "app" when saved.Path != null => FindRunning(saved.Path, saved.Name ?? Path.GetFileNameWithoutExtension(saved.Path)),
            _ => null,
        };
        if (mode != null) Start(mode);
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
        KeepAwakeMode.Forever => new("forever"),
        KeepAwakeMode.Until u => new("date", End: u.EndUtc),
        KeepAwakeMode.WhileRunning w => new("app", Path: w.Path, Name: w.Name),
        _ => null,
    });

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
