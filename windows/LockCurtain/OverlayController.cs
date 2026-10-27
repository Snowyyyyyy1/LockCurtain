// OverlayController.cs —— 遮罩的显示、撤除和退出路径
//
// 两种模式（Mac 版还有「锁屏」模式：Windows 的锁屏界面在安全桌面上，普通程序画不上去，
// 锁屏期间自动化工具也用不了，所以没有这一种）：
//   preview  菜单「遮罩预览」或 --send preview，真人输入后直接撤
//   away     菜单「进入离开模式」或 --send away，真人输入后先锁屏，确认锁上再撤
//
// 退出路径：
//   1. 真人按键 / 点击 / 滚轮 —— InputFilter（前台是管理员窗口时钩子看不到，InputFilter 事后发现）
//   2. 看门狗 —— 钩子连续 120 秒不可用时，先锁屏再撤遮罩，防止锁死
//   3. 会话被锁（Win+L、Ctrl+Alt+Del 里点锁定）—— 直接撤，锁屏本身就挡住了桌面
//   4. 菜单「紧急关闭遮罩」
//
// 安全约束和 Mac 版一样：离开模式下任何撤遮罩的路径都先锁屏，不会露出已解锁的桌面。

using System.Diagnostics;
using Microsoft.Win32;

namespace LockCurtain;

internal enum CurtainMode { Preview, Away }

internal sealed class OverlayController
{
    const int MaxUnguardedSeconds = 120;

    readonly List<OverlayForm> forms = new();
    readonly InputFilter input = new();
    readonly PowerGuard power = new();
    readonly System.Windows.Forms.Timer guardTimer = new() { Interval = 1000 };
    readonly System.Windows.Forms.Timer rebuildTimer = new() { Interval = 500 };
    readonly SynchronizationContext ui;
    readonly bool stealth;
    DateTime armedAt;
    bool locking;
    int unguardedSeconds;
    string? lastAbove;

    public CurtainMode? Mode { get; private set; }
    public event Action? StateChanged;

    public OverlayController(bool stealth)
    {
        this.stealth = stealth;
        ui = SynchronizationContext.Current ?? throw new InvalidOperationException("需要在 UI 线程上创建");
        guardTimer.Tick += (_, _) => Guard();
        // 插拔显示器、改分辨率时会连着来好几次，停 0.5 秒没有新的再重建
        rebuildTimer.Tick += (_, _) =>
        {
            rebuildTimer.Stop();
            if (forms.Count == 0) return;
            Log.Write("屏幕布局变了，重建遮罩窗口");
            RebuildForms();
        };
        SystemEvents.DisplaySettingsChanged += (_, _) => ui.Post(_ =>
        {
            if (forms.Count == 0) return;
            rebuildTimer.Stop();
            rebuildTimer.Start();
        }, null);
    }

    // MARK: - 显示
    public void Show(CurtainMode mode)
    {
        if (forms.Count > 0) return;    // 已在显示时不改模式
        Mode = mode;
        armedAt = DateTime.UtcNow.AddSeconds(1);
        unguardedSeconds = 0;
        lastAbove = null;
        if (mode == CurtainMode.Away) power.Engage();
        BuildForms();
        input.Start(() => ui.Post(_ => HandlePhysicalInput(), null));
        if (!input.IsRunning) Log.Write("⚠️ 无法安装输入钩子，遮罩只能靠看门狗或菜单关闭");
        guardTimer.Start();
        Log.Write($"overlay shown ({mode}), {forms.Count} windows, stealth={forms.All(f => f.Stealthed)}");
        StateChanged?.Invoke();
    }

    /// 每块屏建一个窗口，先黑底上屏；背景在后台准备，好了再补上
    void BuildForms()
    {
        var art = Settings.Current.CurtainArt;
        var background = Settings.Current.CurtainBackground;
        if (art == CurtainArt.Custom) CustomArt.Reload();
        foreach (var screen in Screen.AllScreens)
        {
            var form = new OverlayForm(screen, stealth, art, background);
            form.Show();
            form.Bounds = screen.Bounds;    // 建在另一块缩放不同的屏上时，系统可能按 DPI 改过尺寸
            form.EnsureTopmost();
            forms.Add(form);
        }
        _ = ApplyBackgroundAsync(forms.ToList(), background);
    }

    /// 先建新窗口、再关旧窗口，中间不留空档：离开模式下不会露出桌面（和 Mac 版 rebuildWindows 一样）。
    /// 不经过 Hide()，钩子、防休眠、看门狗都保持原样
    void RebuildForms()
    {
        var old = forms.ToList();
        forms.Clear();
        BuildForms();
        foreach (var f in old) f.Close();
    }

    /// 壁纸类先读壁纸文件；模糊壁纸再按系统铺法画整屏、缩小、模糊。程序画的图按每块屏的像素尺寸和缩放比例画。
    /// 都在后台线程，一块屏一块屏来（多块屏可能共用缓存里的同一张壁纸）。纯黑什么也不用做
    static async Task ApplyBackgroundAsync(List<OverlayForm> targets, CurtainBackground background)
    {
        if (background == CurtainBackground.Black) return;
        var clock = Stopwatch.StartNew();
        var screens = targets.Select(f => (Form: f, Bounds: f.Display.Bounds, f.ClientSize, Scale: f.DeviceDpi / 96f)).ToList();
        if (background.UsesWallpaper())
        {
            var wallpapers = await Task.Run(() => Wallpaper.Load(targets.Select(f => f.Display).ToList()));
            foreach (var (form, bounds, size, _) in screens)
            {
                if (!wallpapers.TryGetValue(form.Display.DeviceName, out var wallpaper)) continue;
                if (background == CurtainBackground.Wallpaper)
                {
                    if (!form.IsDisposed) form.SetWallpaper(wallpaper);
                    continue;
                }
                form.SetBackgroundImage(await Task.Run(() =>
                {
                    using var full = OverlayForm.RenderWallpaper(wallpaper, bounds, size);
                    return CurtainBackgrounds.Blur(full);
                }));
            }
        }
        else
            foreach (var (form, _, size, scale) in screens)
                if (await Task.Run(() => background.Render(size.Width, size.Height, scale)) is { } image)
                    form.SetBackgroundImage(image);
        Log.Write($"background {background} ready in {clock.ElapsedMilliseconds} ms");
    }

    // MARK: - 隐藏
    public void Hide()
    {
        if (Mode == null) return;
        Log.Write("overlay hide");
        guardTimer.Stop();
        rebuildTimer.Stop();
        input.Stop();
        power.Release();
        CloseForms();
        Mode = null;
        StateChanged?.Invoke();
    }

    void CloseForms()
    {
        foreach (var f in forms) f.Close();
        forms.Clear();
    }

    // MARK: - 退出路径
    void HandlePhysicalInput()
    {
        if (Mode == null || DateTime.UtcNow < armedAt) return;
        Log.Write($"真人输入 -> 撤遮罩 ({Mode})");
        _ = SafeHide();
    }

    /// 撤遮罩，但绝不露出已解锁的桌面：离开模式下先锁屏再撤
    public async Task SafeHide()
    {
        if (Mode == CurtainMode.Away) await LockThenHide();
        else Hide();
    }

    /// 先锁屏，确认锁上（最多等 5 秒）再撤遮罩。锁屏失败也照样撤，首要任务是防止锁死
    async Task LockThenHide()
    {
        if (locking) return;    // 滚轮等会连发，只处理第一次
        locking = true;
        try
        {
            if (!Session.IsLocked())
            {
                var ok = Native.LockWorkStation();
                Log.Write($"LockWorkStation -> {ok}");
                for (var i = 0; ok && i < 50 && !Session.IsLocked(); i++) await Task.Delay(100);
                if (!Session.IsLocked()) Log.Write("lockThenHide: 锁屏失败，直接撤遮罩");
            }
            Hide();
        }
        finally { locking = false; }
    }

    /// 会话锁上了：锁屏界面已经挡住桌面，遮罩没用了
    public void OnSessionLockChanged(bool locked)
    {
        Session.LockedByNotification = locked;
        Log.Write(locked ? "session locked" : "session unlocked");
        if (locked && !locking) Hide();
    }

    /// 每秒一次：钩子体检、看门狗、置顶保护
    void Guard()
    {
        input.Heartbeat();
        input.CheckHealth();
        unguardedSeconds = input.IsHealthy ? 0 : unguardedSeconds + 1;
        if (unguardedSeconds >= MaxUnguardedSeconds)
        {
            Log.Write($"watchdog: 退出路径不可用已 {MaxUnguardedSeconds}s，先锁屏再撤遮罩");
            _ = LockThenHide();
            return;
        }

        // 别的置顶窗口（任务管理器的「置顶」、录屏工具的浮窗）后来居上时，把遮罩重新排到最前。
        // 开始菜单、通知等系统界面在更高的层带里，普通程序盖不过，它们能露在遮罩上面
        foreach (var f in forms)
        {
            var above = f.EnsureTopmost();
            if (above != null && above != lastAbove) Log.Write($"guardTopmost: {above} 压住遮罩，重新置顶");
            if (above != null) lastAbove = above;
        }
    }

    // MARK: - 控制接口（ControlServer 调用，在 UI 线程上）
    public async Task<Dictionary<string, object>> HandleCommand(string cmd)
    {
        switch (cmd)
        {
            // 锁屏界面在安全桌面上，遮罩盖不上去；现在盖上，解锁回来的人一碰又锁屏
            case "away" or "preview" when Session.IsLocked():
                return new() { ["ok"] = false, ["running"] = true, ["locked"] = true,
                               ["error"] = "会话已锁屏，遮罩盖不到锁屏界面上；解锁后再发" };
            case "away": Show(CurtainMode.Away); break;
            case "preview": Show(CurtainMode.Preview); break;
            case "hide": await SafeHide(); break;
            case "status": break;
            default:
                return new() { ["ok"] = false, ["error"] = $"未知命令 {cmd}，可用：away / preview / hide / status / settings" };
        }
        var s = new Dictionary<string, object>
        {
            ["ok"] = true,
            ["running"] = true,
            ["mode"] = Mode?.ToString().ToLowerInvariant() ?? "none",
            ["locked"] = Session.IsLocked(),
        };
        if (Mode != null)
        {
            s["exitPathsHealthy"] = input.IsHealthy;
            s["stealth"] = forms.Count > 0 && forms.All(f => f.Stealthed);
            s["windows"] = forms.Count;
        }
        return s;
    }
}
