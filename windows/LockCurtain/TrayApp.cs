// TrayApp.cs —— 通知区域图标和菜单，对应 Mac 版的菜单栏图标
//
// 图标：幕布拉开表示没有遮罩，合上表示遮罩显示中，杯子表示保持唤醒中（遮罩优先）。
// 左键弹面板（StatusPanel：离开模式、预览、保持唤醒、谁在阻止睡眠），右键弹系统原生菜单。

using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace LockCurtain;

internal sealed class TrayApp : ApplicationContext
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

        openIcon = CurtainIcon(closed: false);
        closedIcon = CurtainIcon(closed: true);
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
        base.ExitThreadCore();
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
        return new()
        {
            new("进入离开模式", () => overlay.Show(CurtainMode.Away), idle),
            new("遮罩预览", () => overlay.Show(CurtainMode.Preview), idle),
            new("紧急关闭遮罩", overlay.Hide, !idle),
            new("设置…", ShowSettings, SeparatorBefore: true),
            new("打开日志文件夹", Log.OpenDir),
            new("退出 LockCurtain", ExitThread, SeparatorBefore: true),
        };
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

    /// 横杆加两片帘子。拉开：帘子收在两边；合上：两片在中间相接
    internal static Icon CurtainIcon(bool closed) => Glyph((g, brush, s) =>
    {
        g.FillRectangle(brush, 1 * s, 1.5f * s, 14 * s, 1.5f * s);
        var w = closed ? 6.5f : 3f;
        foreach (var left in new[] { true, false })
        {
            using var path = new GraphicsPath();
            float x0 = left ? 1.5f : 14.5f, x1 = left ? 1.5f + w : 14.5f - w;
            // 顶边贴着横杆，内侧往下收出一点弧度
            path.AddLines(new[] { new PointF(x0 * s, 3 * s), new PointF(x1 * s, 3 * s) });
            path.AddBezier(x1 * s, 3 * s, (x1 + (left ? -1 : 1)) * s, 8 * s, x1 * s, 12 * s, (x1 + (left ? -0.5f : 0.5f)) * s, 14.5f * s);
            path.AddLine((x1 + (left ? -0.5f : 0.5f)) * s, 14.5f * s, x0 * s, 14.5f * s);
            path.CloseFigure();
            g.FillPath(brush, path);
        }
    });

    /// 保持唤醒中：托盘上的杯子和碟子（Mac 版是 SF Symbol cup.and.saucer.fill）
    static Icon CupIcon() => Glyph(DrawCup);

    /// 托盘面板「LockCurtain 保持唤醒」那一行的图标
    internal static Bitmap CupImage(int size, Color color) => GlyphImage(size, color, DrawCup);

    static void DrawCup(Graphics g, Brush brush, float s)
    {
        // 杯身：上宽下窄，底边圆角
        using (var cup = new GraphicsPath())
        {
            cup.AddLine(2 * s, 3.5f * s, 11.5f * s, 3.5f * s);
            cup.AddLine(11.5f * s, 3.5f * s, 10.5f * s, 9.5f * s);
            cup.AddBezier(10.5f * s, 9.5f * s, 10.2f * s, 11.2f * s, 9.2f * s, 11.5f * s, 8 * s, 11.5f * s);
            cup.AddLine(8 * s, 11.5f * s, 5.5f * s, 11.5f * s);
            cup.AddBezier(5.5f * s, 11.5f * s, 4.3f * s, 11.5f * s, 3.3f * s, 11.2f * s, 3 * s, 9.5f * s);
            cup.CloseFigure();
            g.FillPath(brush, cup);
        }
        // 把手
        using (var pen = new Pen(brush, 1.4f * s))
            g.DrawArc(pen, 9.6f * s, 4.6f * s, 4.4f * s, 4.2f * s, -80, 190);
        // 碟子
        using var saucer = new GraphicsPath();
        saucer.AddArc(0.8f * s, 12.6f * s, 1.6f * s, 1.6f * s, 90, 180);
        saucer.AddArc(12.6f * s, 12.6f * s, 1.6f * s, 1.6f * s, 270, 180);
        saucer.CloseFigure();
        g.FillPath(brush, saucer);
    }

    /// 托盘小图标：在 16×16 的设计网格里画（s 是一格的像素），颜色跟着任务栏深浅色走
    static Icon Glyph(Action<Graphics, Brush, float> draw)
    {
        var light = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                                      "SystemUsesLightTheme", 0) is int v && v == 1;
        using var bmp = GlyphImage(SystemInformation.SmallIconSize.Width, light ? Color.Black : Color.White, draw);
        var hicon = bmp.GetHicon();
        var icon = (Icon)Icon.FromHandle(hicon).Clone();
        DestroyIcon(hicon);
        return icon;
    }

    static Bitmap GlyphImage(int size, Color color, Action<Graphics, Brush, float> draw)
    {
        var bmp = new Bitmap(size, size);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var brush = new SolidBrush(color);
        draw(g, brush, size / 16f);
        return bmp;
    }

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(nint hicon);
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
