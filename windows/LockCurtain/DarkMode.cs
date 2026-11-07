// DarkMode.cs —— 窗口里的标准控件跟着系统深浅色走
//
// .NET 9 起 WinForms 有 Application.SetColorMode，.NET Framework 4.8 没有。页面上的字和卡片本来就是自己按 Theme 画的，
// 这里只管系统画的那几样：标题栏（DWM）、按钮、输入框、数字框、滚动条（uxtheme 的 DarkMode_Explorer / DarkMode_CFD 主题），
// 还有没单独设颜色的文字（窗口的 ForeColor，子控件继承）。浅色时什么都不改，和以前一样。
// 按钮统一交给系统画（FlatStyle.System）：WinForms 自己画的按钮不认 uxtheme 的深色主题。强调色按钮（FlatStyle.Flat）自己有颜色，不动。

using System.Runtime.InteropServices;

namespace LockCurtain;

internal static class DarkMode
{
    /// 在窗口的 OnHandleCreated 里调：标题栏、现有的和以后加进来的控件都换成 theme 的深浅色
    public static void Apply(Form form, Theme theme)
    {
        Native.UseDarkTitleBar(form.Handle, theme.Dark);
        if (!theme.Dark) return;
        form.ForeColor = theme.Text;
        Walk(form, theme);
    }

    static void Walk(Control control, Theme theme)
    {
        Style(control, theme);
        foreach (Control child in control.Controls) Walk(child, theme);
        control.ControlAdded += (_, e) => Walk(e.Control, theme);
    }

    static void Style(Control control, Theme theme)
    {
        switch (control)
        {
            case Button b when b.FlatStyle != FlatStyle.Flat:
                b.FlatStyle = FlatStyle.System;
                UseTheme(b, "DarkMode_Explorer");
                break;
            case TextBoxBase t:
                t.BackColor = Field(theme);
                t.ForeColor = theme.Text;
                UseTheme(t, "DarkMode_CFD");
                break;
            case NumericUpDown n:
                n.BackColor = Field(theme);
                n.ForeColor = theme.Text;
                UseTheme(n, "DarkMode_CFD");
                break;
            case ScrollableControl { AutoScroll: true } s:
                UseTheme(s, "DarkMode_Explorer");   // 滚动条
                break;
        }
    }

    /// 输入框的底色：比卡片亮一点（Win11 深色设置里输入框的样子）
    static Color Field(Theme theme) => Theme.Mix(theme.Card, Color.White, 93);

    static void UseTheme(Control control, string name)
    {
        if (control.IsHandleCreated) SetWindowTheme(control.Handle, name, null);
        else control.HandleCreated += (_, _) => SetWindowTheme(control.Handle, name, null);
    }

    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(nint hwnd, string? subAppName, string? subIdList);
}
