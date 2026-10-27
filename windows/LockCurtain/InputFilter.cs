// InputFilter.cs —— 区分「真人输入」与「程序合成输入」
//
// 判据：低级钩子里的 LLKHF_INJECTED / LLMHF_INJECTED 标志
//   SendInput、keybd_event、mouse_event 合成的输入 → 带标志 → 放行
//   键盘、鼠标、触控板的硬件输入                   → 不带   → 真人
//
// 对应 Mac 版 CurtainInputFilter 的宽松模式。Windows 的钩子拿不到合成输入来自哪个进程，
// 所以没有严格模式和豁免名单。
//
// 真人的按键、点击、滚轮被吞掉，不会落到 agent 正在操作的窗口上；鼠标移动放行（和 Mac 版一样，
// 只看按键和点击）。按下被吞掉的键，松开也吞掉；按下没吞的（遮罩出现前就按着的键）松开放行，
// 否则系统会以为它一直按着，比如 Ctrl 卡住以后 agent 合成的每个按键都变成 Ctrl+键。
//
// 钩子跑在单独的线程上，自带消息循环。钩子回调超时（LowLevelHooksTimeout）次数多了，
// 系统会不打招呼地把钩子摘掉，所以回调里只记时间、发通知，不做别的事。
// 摘掉之后的输入照样会更新 GetLastInputInfo，CheckHealth 靠这一点发现钩子失效并重装。
//
// UI 线程卡住时（超过 5 秒没报平安）遮罩撤不掉，再吞真人输入就把人锁在外面了：
// 钩子线程自己调一次锁屏，之后真人输入一律放行。
//
// 前台是权限更高的窗口（以管理员身份运行的程序）时，UIPI 不让普通权限的钩子看到发给它的输入：
// 真人的按键直接进了那个窗口，钩子吞不掉也看不见（实测 2026-10-26，前台是任务管理器）。
// 只能事后补：每 0.1 秒拿 GetLastInputInfo 和钩子看到的最后时刻比，有输入绕过了钩子、
// 前台又是更高权限的窗口，就按真人输入处理（离开模式下先锁屏）。普通权限的 agent 本来就
// 操作不了管理员窗口（UIPI 同样拦它的 SendInput），能绕过来的只有真人和管理员权限的程序。
// 发现之前的那零点几秒里，按键已经进了那个窗口。用 install.ps1 装成以最高权限运行后，
// 钩子能直接看到发给管理员窗口的输入，这条补救就只剩 SYSTEM 进程的窗口会用到。
//
// 不拦截的：Ctrl+Alt+Del（安全注意序列）、Win+L。这两个都会离开当前桌面，不会露出桌面内容。

using System.Runtime.InteropServices;

namespace LockCurtain;

internal sealed class InputFilter
{
    Thread? thread;
    uint threadId;
    nint keyboardHook, mouseHook;
    // 委托要一直被引用着，否则会被 GC 回收，钩子回调到已释放的内存
    readonly Native.HookProc keyboardProc, mouseProc;
    Action? onPhysical;

    /// 钩子最近看到的输入（真人和合成都算）的时刻，GetTickCount 基准
    volatile uint lastSeenTick;
    /// 最近一次发现「有输入钩子没看到」的时刻
    uint lastMissTick;
    bool hadMiss;
    /// UI 线程最近一次报平安的时刻
    volatile uint heartbeatTick;
    int failSafeFired;

    /// 多久查一次绕过钩子的输入。连着两次都查到才算，给钩子线程留出处理同一个输入的时间
    const int BypassPollMs = 100;
    const int BypassSlackMs = 50;
    System.Threading.Timer? bypassTimer;
    bool bypassSuspected;
    static readonly int OwnIntegrity = IntegrityLevel((uint)Environment.ProcessId) ?? 0x2000;

    /// 被吞掉的按下：键盘存 vkCode，鼠标存按钮号，松开时查这里决定吞不吞
    readonly HashSet<uint> swallowedKeys = new();
    readonly HashSet<int> swallowedButtons = new();

    public InputFilter()
    {
        keyboardProc = KeyboardHook;
        mouseProc = MouseHook;
    }

    public bool IsRunning => keyboardHook != 0 && mouseHook != 0;

    /// 钩子都在，且最近 5 秒没有漏掉的输入
    public bool IsHealthy => IsRunning && (!hadMiss || unchecked(Native.GetTickCount() - lastMissTick) > 5000);

    public void Start(Action onPhysical)
    {
        if (thread != null) return;
        this.onPhysical = onPhysical;
        lastSeenTick = Native.LastInputTick();
        heartbeatTick = Native.GetTickCount();
        failSafeFired = 0;
        swallowedKeys.Clear();
        swallowedButtons.Clear();
        using var ready = new ManualResetEventSlim();
        thread = new Thread(() => Run(ready)) { IsBackground = true, Name = "InputFilter" };
        thread.Start();
        ready.Wait(2000);
        bypassSuspected = false;
        bypassTimer = new System.Threading.Timer(_ => CheckBypass(), null, BypassPollMs, BypassPollMs);
        Log.Write($"InputFilter start keyboard={keyboardHook != 0} mouse={mouseHook != 0}");
    }

    public void Stop()
    {
        if (thread == null) return;
        bypassTimer?.Dispose();
        bypassTimer = null;
        Native.PostThreadMessageW(threadId, Native.WM_QUIT, 0, 0);
        thread.Join(2000);
        thread = null;
        Log.Write("InputFilter stop");
    }

    /// UI 线程每秒调一次
    public void Heartbeat() => heartbeatTick = Native.GetTickCount();

    /// UI 线程卡住了：锁一次屏，真人输入放行
    bool UiStalled()
    {
        if (unchecked(Native.GetTickCount() - heartbeatTick) <= 5000) return false;
        if (Interlocked.Exchange(ref failSafeFired, 1) == 0)
            ThreadPool.QueueUserWorkItem(_ =>
            {
                Log.Write("UI 线程无响应，锁屏并放行真人输入");
                Native.LockWorkStation();
            });
        return true;
    }

    /// 每秒调一次：GetLastInputInfo 比钩子看到的新，说明有输入绕过了钩子，重装一次
    public void CheckHealth()
    {
        if (thread == null) return;
        var last = Native.LastInputTick();
        var now = Native.GetTickCount();
        var missed = unchecked((int)(last - lastSeenTick)) > 1000 && unchecked((int)(now - last)) > 500;
        if (!missed && IsRunning) return;
        Log.Write($"InputFilter 钩子{(IsRunning ? "漏掉了输入" : "不在")}，重装");
        hadMiss = true;
        lastMissTick = now;
        var callback = onPhysical!;
        Stop();
        Start(callback);
    }

    /// 定时器线程上跑：有输入绕过了钩子，前台又是比我们权限高的窗口，按真人输入处理
    void CheckBypass()
    {
        var last = Native.LastInputTick();
        if (unchecked((int)(last - lastSeenTick)) <= BypassSlackMs) { bypassSuspected = false; return; }
        if (!bypassSuspected) { bypassSuspected = true; return; }
        bypassSuspected = false;
        if (!ForegroundOutranksUs()) return;
        lastSeenTick = last;    // 同一次输入只报一次
        Log.Write("前台是更高权限的窗口，有输入绕过了钩子，按真人输入处理");
        onPhysical?.Invoke();
    }

    /// 前台窗口所属的进程权限比我们高。查不到（比如 SYSTEM 进程的窗口）按高算，UIPI 同样拦着它
    static bool ForegroundOutranksUs()
    {
        Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out var pid);
        if (pid == 0) return false;     // 没有前台窗口，比如正在切到锁屏
        return (IntegrityLevel(pid) ?? int.MaxValue) > OwnIntegrity;
    }

    /// 进程的完整性级别：0x2000 普通，0x3000 管理员，0x4000 SYSTEM
    static int? IntegrityLevel(uint pid)
    {
        var process = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (process == 0) return null;
        nint token = 0, buf = 0;
        try
        {
            if (!Native.OpenProcessToken(process, Native.TOKEN_QUERY, out token)) return null;
            Native.GetTokenInformation(token, Native.TokenIntegrityLevel, 0, 0, out var size);
            buf = Marshal.AllocHGlobal(size);
            if (!Native.GetTokenInformation(token, Native.TokenIntegrityLevel, buf, size, out _)) return null;
            var sid = Marshal.ReadIntPtr(buf);      // TOKEN_MANDATORY_LABEL 的第一个字段是 SID 指针
            var lastIndex = Marshal.ReadByte(Native.GetSidSubAuthorityCount(sid)) - 1;
            return Marshal.ReadInt32(Native.GetSidSubAuthority(sid, (uint)lastIndex));
        }
        finally
        {
            if (buf != 0) Marshal.FreeHGlobal(buf);
            if (token != 0) Native.CloseHandle(token);
            Native.CloseHandle(process);
        }
    }

    void Run(ManualResetEventSlim ready)
    {
        threadId = Native.GetCurrentThreadId();
        var module = Native.GetModuleHandleW(null);
        keyboardHook = Native.SetWindowsHookExW(Native.WH_KEYBOARD_LL, keyboardProc, module, 0);
        mouseHook = Native.SetWindowsHookExW(Native.WH_MOUSE_LL, mouseProc, module, 0);
        if (keyboardHook == 0 || mouseHook == 0)
            Log.Write($"SetWindowsHookEx 失败 error={Marshal.GetLastWin32Error()}");
        ready.Set();

        while (Native.GetMessageW(out _, 0, 0, 0) > 0) { }

        if (keyboardHook != 0) Native.UnhookWindowsHookEx(keyboardHook);
        if (mouseHook != 0) Native.UnhookWindowsHookEx(mouseHook);
        keyboardHook = mouseHook = 0;
    }

    unsafe nint KeyboardHook(int nCode, nint wParam, nint lParam)
    {
        if (nCode >= 0)
        {
            var k = (Native.KBDLLHOOKSTRUCT*)lParam;
            lastSeenTick = k->time;
            if ((k->flags & Native.LLKHF_INJECTED) == 0 && !UiStalled())
            {
                var msg = (int)wParam;
                if (msg is Native.WM_KEYDOWN or Native.WM_SYSKEYDOWN)
                {
                    swallowedKeys.Add(k->vkCode);
                    onPhysical?.Invoke();
                    return 1;
                }
                if (swallowedKeys.Remove(k->vkCode)) return 1;
            }
        }
        return Native.CallNextHookEx(0, nCode, wParam, lParam);
    }

    unsafe nint MouseHook(int nCode, nint wParam, nint lParam)
    {
        if (nCode >= 0)
        {
            var m = (Native.MSLLHOOKSTRUCT*)lParam;
            lastSeenTick = m->time;
            if ((m->flags & Native.LLMHF_INJECTED) == 0 && !UiStalled())
            {
                var msg = (int)wParam;
                switch (msg)
                {
                    case Native.WM_LBUTTONDOWN or Native.WM_RBUTTONDOWN or Native.WM_MBUTTONDOWN or Native.WM_XBUTTONDOWN:
                        swallowedButtons.Add(Button(msg, m->mouseData));
                        onPhysical?.Invoke();
                        return 1;
                    case Native.WM_LBUTTONUP or Native.WM_RBUTTONUP or Native.WM_MBUTTONUP or Native.WM_XBUTTONUP:
                        if (swallowedButtons.Remove(Button(msg, m->mouseData))) return 1;
                        break;
                    case Native.WM_MOUSEWHEEL or Native.WM_MOUSEHWHEEL:
                        onPhysical?.Invoke();
                        return 1;
                }
            }
        }
        return Native.CallNextHookEx(0, nCode, wParam, lParam);
    }

    /// 左 1 右 2 中 3，X 键 4、5（mouseData 高 16 位是 XBUTTON1/2）
    static int Button(int msg, uint mouseData) => msg switch
    {
        Native.WM_LBUTTONDOWN or Native.WM_LBUTTONUP => 1,
        Native.WM_RBUTTONDOWN or Native.WM_RBUTTONUP => 2,
        Native.WM_MBUTTONDOWN or Native.WM_MBUTTONUP => 3,
        _ => 3 + (int)(mouseData >> 16),
    };
}
