// TrayApp.cs —— 通知区域图标和菜单，对应 Mac 版的菜单栏图标
//
// 图标：幕布拉开表示没有遮罩，合上表示遮罩显示中。
// 左键弹浮窗（TrayFlyout），右键弹系统原生菜单，两边的命令是同一份（和 Ledge Windows 版一样）。

using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace LockCurtain;

internal sealed class TrayApp : ApplicationContext
{
    /// 浮窗关掉后这么久之内的左键不再打开它：浮窗开着时点图标，按下时浮窗已经因失去焦点关了，松开时不能又弹出来
    const int FlyoutReopenGuardMs = 300;

    readonly OverlayController overlay;
    readonly ControlServer server;
    readonly SessionWatcher watcher;
    readonly NotifyIcon tray;
    readonly Icon openIcon, closedIcon;
    /// 右键菜单的主人：TrackPopupMenu 要一个本线程的窗口
    readonly NativeWindow menuOwner = new();
    TrayFlyout? flyout;
    long flyoutClosedAt;

    public TrayApp(bool stealth, bool preview)
    {
        overlay = new OverlayController(stealth);
        server = new ControlServer(overlay.HandleCommand);
        watcher = new SessionWatcher();
        watcher.LockChanged += overlay.OnSessionLockChanged;
        menuOwner.CreateHandle(new CreateParams());
        // 以管理员身份运行时，资源管理器（普通权限）重启后广播的 TaskbarCreated 会被 UIPI 挡掉，
        // NotifyIcon 收不到就不会重新添加图标，托盘图标从此消失
        Native.ChangeWindowMessageFilter(Native.RegisterWindowMessageW("TaskbarCreated"), Native.MSGFLT_ADD);

        openIcon = CurtainIcon(closed: false);
        closedIcon = CurtainIcon(closed: true);
        tray = new NotifyIcon { Icon = openIcon, Text = $"LockCurtain · {Status()}", Visible = true };
        tray.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) ShowFlyout();
            else if (e.Button == MouseButtons.Right) ShowMenu(Cursor.Position);
        };
        overlay.StateChanged += () =>
        {
            tray.Icon = overlay.Mode == null ? openIcon : closedIcon;
            tray.Text = $"LockCurtain · {Status()}";
        };

        server.Start();
        Log.Write($"LockCurtain started, stealth={stealth}, locked={Session.QueryLocked()?.ToString() ?? "unknown"}");
        if (preview) SynchronizationContext.Current!.Post(_ => overlay.Show(CurtainMode.Preview), null);
    }

    protected override void ExitThreadCore()
    {
        Log.Write("LockCurtain exit");
        flyout?.Close();
        overlay.Hide();
        server.Stop();
        watcher.Dispose();
        menuOwner.DestroyHandle();
        tray.Visible = false;
        tray.Dispose();
        base.ExitThreadCore();
    }

    string Status() => overlay.Mode switch
    {
        null => "遮罩未开启",
        CurtainMode.Preview => "预览中 · 按任意键或点击关闭",
        _ => "离开模式中 · 真人按键会先锁屏",
    };

    /// 托盘的命令，左键浮窗和右键菜单都从这里取
    List<TrayCommand> Commands()
    {
        var idle = overlay.Mode == null;
        return new()
        {
            new("进入离开模式", () => overlay.Show(CurtainMode.Away), idle),
            new("遮罩预览", () => overlay.Show(CurtainMode.Preview), idle),
            new("紧急关闭遮罩", overlay.Hide, !idle),
            new("打开日志文件夹", () => Process.Start(new ProcessStartInfo(Log.Dir) { UseShellExecute = true }),
                SeparatorBefore: true),
            new("退出 LockCurtain", ExitThread, SeparatorBefore: true),
        };
    }

    void ShowFlyout()
    {
        if (flyout != null || Environment.TickCount64 - flyoutClosedAt < FlyoutReopenGuardMs) return;
        var anchor = Cursor.Position;
        flyout = new TrayFlyout("LockCurtain", Status(), Commands(), anchor);
        flyout.FormClosed += (_, _) =>
        {
            flyout = null;
            flyoutClosedAt = Environment.TickCount64;
        };
        flyout.Show();
        if (Native.SetForegroundWindow(flyout.Handle) && Native.GetForegroundWindow() == flyout.Handle) return;
        // 拿不到前台的浮窗点外面不会关，改弹菜单
        Log.Write("托盘浮窗拿不到前台，改弹菜单");
        flyout.Close();
        ShowMenu(anchor);
    }

    /// 系统原生菜单，跟着「应用」的深浅色走
    void ShowMenu(Point at)
    {
        var commands = Commands();
        var menu = Native.CreatePopupMenu();
        for (var i = 0; i < commands.Count; i++)
        {
            if (commands[i].SeparatorBefore) Native.AppendMenuW(menu, Native.MF_SEPARATOR, 0, null);
            Native.AppendMenuW(menu, commands[i].Enabled ? Native.MF_STRING : Native.MF_GRAYED, (nuint)(i + 1), commands[i].Label);
        }
        MatchMenusToAppTheme();
        // 菜单的主人先到前台，点到菜单外面菜单才会关；关掉后补一条空消息（TrackPopupMenu 文档的备注）
        Native.SetForegroundWindow(menuOwner.Handle);
        var picked = Native.TrackPopupMenuEx(menu, Native.TPM_RIGHTBUTTON | Native.TPM_RETURNCMD, at.X, at.Y, menuOwner.Handle, 0);
        Native.PostMessageW(menuOwner.Handle, Native.WM_NULL, 0, 0);
        Native.DestroyMenu(menu);
        if (picked > 0) commands[picked - 1].Run();
    }

    /// 让原生菜单用深色或浅色画。Windows 没有公开的接口，用 uxtheme 的未公开导出，和 Ledge 一样
    static void MatchMenusToAppTheme()
    {
        if (Environment.OSVersion.Version.Build < 18362) return;
        const int ForceDark = 2, ForceLight = 3;
        Native.SetPreferredAppMode(TrayFlyout.AppsUseDarkTheme() ? ForceDark : ForceLight);
        Native.FlushMenuThemes();
    }

    /// 横杆加两片帘子。拉开：帘子收在两边；合上：两片在中间相接。颜色跟着任务栏深浅色走
    static Icon CurtainIcon(bool closed)
    {
        var size = SystemInformation.SmallIconSize.Width;
        using var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var light = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                                          "SystemUsesLightTheme", 0) is int v && v == 1;
            using var brush = new SolidBrush(light ? Color.Black : Color.White);
            float s = size / 16f;
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
        }
        var hicon = bmp.GetHicon();
        var icon = (Icon)Icon.FromHandle(hicon).Clone();
        DestroyIcon(hicon);
        return icon;
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
