// TrayApp.cs —— 通知区域图标和菜单，对应 Mac 版的菜单栏图标
//
// 图标（TrayGlyphs.cs）：显示器上的锁开着表示没有遮罩，锁上表示遮罩显示中，杯子表示保持唤醒中（遮罩优先）。
// 左键弹面板（StatusPanel：离开模式、预览、保持唤醒、谁在阻止睡眠），右键弹系统原生菜单。

using System.Drawing;
using System.Runtime.InteropServices;

namespace LockCurtain;

internal sealed partial class TrayApp : ApplicationContext
{
    /// 面板关掉后这么久之内的左键不再打开它：面板开着时点图标，按下时面板已经因失去焦点关了，松开时不能又弹出来
    const int PanelReopenGuardMs = 300;

    readonly OverlayController overlay;
    readonly RuleStore rules = new();
    readonly RuleEngine ruleEngine;
    readonly ControlServer server;
    readonly SessionWatcher watcher;
    readonly NotifyIcon tray;
    readonly Icon openIcon, closedIcon, cupIcon;
    readonly KeepAwake keepAwake = new();
    /// 右键菜单的主人：TrackPopupMenu 要一个本线程的窗口
    readonly NativeWindow menuOwner = new();
    StatusPanel? panel;
    bool panelOpening;
    long panelClosedAt;
    SettingsWindow? settings;

    public TrayApp(bool stealth, bool preview)
    {
        overlay = new OverlayController(stealth);
        server = new ControlServer(HandleCommand);
        watcher = new SessionWatcher();
        watcher.LockChanged += overlay.OnSessionLockChanged;
        ruleEngine = new RuleEngine(rules, _ => overlay.Show(CurtainMode.Away));
        menuOwner.CreateHandle(new CreateParams());
        // 以管理员身份运行时，资源管理器（普通权限）重启后广播的 TaskbarCreated 会被 UIPI 挡掉，
        // NotifyIcon 收不到就不会重新添加图标，托盘图标从此消失
        Native.ChangeWindowMessageFilter(Native.RegisterWindowMessageW("TaskbarCreated"), Native.MSGFLT_ADD);

        openIcon = LockIcon(locked: false);
        closedIcon = LockIcon(locked: true);
        cupIcon = CupIcon();
        tray = new NotifyIcon { Icon = openIcon, Text = $"LockCurtain · {Status()}", Visible = Settings.Current.ShowTrayIcon };
        Settings.Changed += () => tray.Visible = Settings.Current.ShowTrayIcon;
        tray.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) ShowPanel();
            else if (e.Button == MouseButtons.Right) ShowMenu(Cursor.Position);
        };
        overlay.StateChanged += UpdateTrayIcon;
        keepAwake.Changed += UpdateTrayIcon;

        server.Start();
        ruleEngine.Start();
        var ui = SynchronizationContext.Current!;
        Updater.Start(idle: () => overlay.Mode == null, exit: () => ui.Post(_ => ExitAfterUpdate(), null));
        keepAwake.Restore();
        Log.Write($"LockCurtain started, stealth={stealth}, locked={Session.QueryLocked()?.ToString() ?? "unknown"}");
        if (preview) SynchronizationContext.Current!.Post(_ => overlay.Show(CurtainMode.Preview), null);
    }

    protected override void ExitThreadCore()
    {
        Log.Write("LockCurtain exit");
        panel?.Close();
        keepAwake.Dispose();
        settings?.Close();
        overlay.Hide();
        server.Stop();
        watcher.Dispose();
        menuOwner.DestroyHandle();
        tray.Visible = false;
        tray.Dispose();
        Updater.Stop();
        base.ExitThreadCore();
    }

    /// 更新装好了：遮罩没在显示就退出（新版本由计划任务拉起）。WinSparkle 点安装前问过可不可以退出，
    /// 但这之后规则或命令还可能把遮罩打开，这时等它撤掉再退
    void ExitAfterUpdate()
    {
        if (overlay.Mode == null)
        {
            ExitThread();
            return;
        }
        Log.Write("更新已装好，遮罩撤掉后退出");
        void OnChanged()
        {
            if (overlay.Mode != null) return;
            overlay.StateChanged -= OnChanged;
            ExitThread();
        }
        overlay.StateChanged += OnChanged;
    }

    void UpdateTrayIcon()
    {
        tray.Icon = overlay.Mode != null ? closedIcon : keepAwake.Mode != null ? cupIcon : openIcon;
        tray.Text = $"LockCurtain · {Status()}";
    }

    string Status() => overlay.Mode switch
    {
        null when keepAwake.Mode != null => "保持唤醒中",
        null => "遮罩未开启",
        CurtainMode.Preview => "预览中 · 按任意键或点击关闭",
        _ => "离开模式中 · 真人按键会先锁屏",
    };

    /// 右键菜单的命令
    List<TrayCommand> Commands()
    {
        var idle = overlay.Mode == null;
        return
        [
            new("进入离开模式", () => overlay.Show(CurtainMode.Away), idle),
            new("遮罩预览", () => overlay.Show(CurtainMode.Preview), idle),
            new("紧急关闭遮罩", overlay.Hide, !idle),
            new("设置…", ShowSettings, SeparatorBefore: true),
            .. Updater.Available ? new[] { new TrayCommand("检查更新…", Updater.CheckNow) } : [],
            new("打开日志文件夹", Log.OpenDir),
            new("退出 LockCurtain", ExitThread, SeparatorBefore: true),
        ];
    }

    /// settings 命令在这里处理，其余交给遮罩
    Task<Dictionary<string, object>> HandleCommand(string cmd)
    {
        if (cmd != "settings") return overlay.HandleCommand(cmd);
        ShowSettings();
        return Task.FromResult(new Dictionary<string, object> { ["ok"] = true, ["running"] = true });
    }

    /// 只开一个设置窗口，已开着就提到前面
    void ShowSettings()
    {
        if (settings == null)
        {
            settings = new SettingsWindow(rules, () => overlay.Show(CurtainMode.Away));
            settings.FormClosed += (_, _) => settings = null;
        }
        if (settings.WindowState == FormWindowState.Minimized) settings.WindowState = FormWindowState.Normal;
        settings.Show();
        settings.Activate();
    }

    /// 先在后台读谁在阻止睡眠（powercfg 要一两百毫秒）和过去 24 小时的睡眠，读完再弹，省得面板弹出来再变高
    async void ShowPanel()
    {
        if (panel != null || panelOpening || Environment.TickCount64 - panelClosedAt < PanelReopenGuardMs) return;
        var anchor = Cursor.Position;
        panelOpening = true;
        SleepBlockerSnapshot? blockers = null;
        (List<Span>? Sleeps, string? Error) history = (null, "没读");
        try
        {
            var reading = Task.Run(SleepEventLog.Load);
            blockers = await Task.Run(SleepBlockers.Snapshot);
            history = await reading;
        }
        catch (Exception e) { Log.Write($"托盘面板读数据出错: {e.Message}"); }
        finally { panelOpening = false; }

        panel = new StatusPanel(anchor, overlay.Mode == null, blockers, history, keepAwake,
                                () => overlay.Show(CurtainMode.Away), () => overlay.Show(CurtainMode.Preview), ShowSettings);
        panel.FormClosed += (_, _) =>
        {
            panel = null;
            panelClosedAt = Environment.TickCount64;
        };
        panel.Show();
        if (Native.SetForegroundWindow(panel.Handle) && Native.GetForegroundWindow() == panel.Handle) return;
        // 拿不到前台的面板点外面不会关，改弹菜单
        Log.Write("托盘面板拿不到前台，改弹菜单");
        panel.Close();
        ShowMenu(anchor);
    }

    void ShowMenu(Point at) => NativeMenu.Show(menuOwner.Handle, at, Commands());
}

/// 收 WM_WTSSESSION_CHANGE 用的隐藏窗口
internal sealed class SessionWatcher : NativeWindow, IDisposable
{
    public event Action<bool>? LockChanged;

    public SessionWatcher()
    {
        CreateHandle(new CreateParams());
        if (!Native.WTSRegisterSessionNotification(Handle, Native.NOTIFY_FOR_THIS_SESSION))
            Log.Write($"WTSRegisterSessionNotification 失败 error={Marshal.GetLastWin32Error()}");
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == Native.WM_WTSSESSION_CHANGE)
        {
            if ((int)m.WParam == Native.WTS_SESSION_LOCK) LockChanged?.Invoke(true);
            else if ((int)m.WParam == Native.WTS_SESSION_UNLOCK) LockChanged?.Invoke(false);
        }
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        Native.WTSUnRegisterSessionNotification(Handle);
        DestroyHandle();
    }
}
