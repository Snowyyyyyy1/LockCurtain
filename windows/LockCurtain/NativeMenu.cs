// NativeMenu.cs —— 系统原生的弹出菜单，跟着「应用」的深浅色走
//
// 托盘右键菜单、托盘面板的「保持唤醒」、规则编辑器里「运行中的程序」这类挑选菜单都用它。

using System.Drawing;

namespace LockCurtain;

/// 菜单里的一个命令。有 Submenu 时是一个子菜单，Run 不用
internal sealed record TrayCommand(string Label, Action Run, bool Enabled = true, bool SeparatorBefore = false,
                                   IReadOnlyList<TrayCommand>? Submenu = null);

internal static class NativeMenu
{
    /// 在 at 处弹出菜单，选中哪项就执行哪项。owner 是本线程的一个窗口
    public static void Show(nint owner, Point at, IReadOnlyList<TrayCommand> commands)
    {
        var all = new List<TrayCommand>();
        var menu = Build(commands, all);
        MatchMenusToAppTheme();
        // 菜单的主人先到前台，点到菜单外面菜单才会关；关掉后补一条空消息（TrackPopupMenu 文档的备注）
        Native.SetForegroundWindow(owner);
        var picked = Native.TrackPopupMenuEx(menu, Native.TPM_RIGHTBUTTON | Native.TPM_RETURNCMD, at.X, at.Y, owner, 0);
        Native.PostMessageW(owner, Native.WM_NULL, 0, 0);
        Native.DestroyMenu(menu);   // 子菜单跟着一起销毁
        if (picked > 0) all[picked - 1].Run();
    }

    /// 建一层菜单；命令按出现顺序编号（从 1 起），子菜单里的也编进 all
    static nint Build(IReadOnlyList<TrayCommand> commands, List<TrayCommand> all)
    {
        var menu = Native.CreatePopupMenu();
        foreach (var c in commands)
        {
            if (c.SeparatorBefore) Native.AppendMenuW(menu, Native.MF_SEPARATOR, 0, null);
            var grayed = c.Enabled ? 0 : Native.MF_GRAYED;
            if (c.Submenu != null)
                Native.AppendMenuW(menu, Native.MF_POPUP | grayed, (nuint)Build(c.Submenu, all), c.Label);
            else
            {
                all.Add(c);
                Native.AppendMenuW(menu, Native.MF_STRING | grayed, (nuint)all.Count, c.Label);
            }
        }
        return menu;
    }

    /// 让原生菜单用深色或浅色画。Windows 没有公开的接口，用 uxtheme 的未公开导出，和 Ledge 一样
    static void MatchMenusToAppTheme()
    {
        if (Environment.OSVersion.Version.Build < 18362) return;
        const int ForceDark = 2, ForceLight = 3;
        Native.SetPreferredAppMode(Application.IsDarkModeEnabled ? ForceDark : ForceLight);
        Native.FlushMenuThemes();
    }
}
