// WinForms48.cs —— .NET Framework 4.8 的 WinForms 没有、主程序用到的几样：TaskDialog（.NET 5）、TextBox.PlaceholderText（.NET Core 3）、
// Application.IsDarkModeEnabled（.NET 9）、Icon.ExtractIcon（.NET 8）。不依赖 WinForms 的补丁在 Compat48.cs
//
// WarningDialog 直接调 comctl32 的 TaskDialogIndirect（就是 .NET 的 TaskDialog 底下那个），样子和以前一样：
// 警告图标、粗体标题、正文、自定义文字的两个按钮、默认选中「取消」。
// CueTextBox 用系统的 EM_SETCUEBANNER 显示占位文字，获得焦点时隐藏，和 .NET 的 PlaceholderText 一样。

using System.Runtime.InteropServices;

namespace LockCurtain;

internal static class WarningDialog
{
    const int CancelId = 100, ConfirmId = 101;

    /// 「取消 / {confirm}」两个按钮，默认是取消；按了 confirm 才返回 true（关窗口、按 Esc 都算取消）。
    /// owner 为 null 时居中在屏幕上
    public static bool Confirm(IWin32Window? owner, string caption, string heading, string text, string confirm)
    {
        var buttons = new[] { (CancelId, "取消"), (ConfirmId, confirm) };
        var size = Marshal.SizeOf<TASKDIALOG_BUTTON>();
        var array = Marshal.AllocHGlobal(size * buttons.Length);
        var texts = new List<nint>();
        try
        {
            for (var i = 0; i < buttons.Length; i++)
            {
                var label = Marshal.StringToHGlobalUni(buttons[i].Item2);
                texts.Add(label);
                Marshal.StructureToPtr(new TASKDIALOG_BUTTON { nButtonID = buttons[i].Item1, pszButtonText = label }, array + i * size, false);
            }
            var config = new TASKDIALOGCONFIG
            {
                cbSize = (uint)Marshal.SizeOf<TASKDIALOGCONFIG>(),
                hwndParent = owner?.Handle ?? IntPtr.Zero,
                dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | (owner != null ? TDF_POSITION_RELATIVE_TO_WINDOW : 0),
                pszWindowTitle = caption,
                hMainIcon = TD_WARNING_ICON,
                pszMainInstruction = heading,
                pszContent = text,
                cButtons = (uint)buttons.Length,
                pButtons = array,
                nDefaultButton = CancelId,
            };
            return TaskDialogIndirect(ref config, out var picked, out _, out _) == 0 && picked == ConfirmId;
        }
        catch (EntryPointNotFoundException)
        {
            // 没加载到 v6 的 comctl32（不该发生：app.manifest 声明了）。退回普通消息框
            return MessageBox.Show(owner, heading + "\n\n" + text, caption, MessageBoxButtons.OKCancel,
                MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) == DialogResult.OK;
        }
        finally
        {
            foreach (var t in texts) Marshal.FreeHGlobal(t);
            Marshal.FreeHGlobal(array);
        }
    }

    const int TDF_ALLOW_DIALOG_CANCELLATION = 0x0008, TDF_POSITION_RELATIVE_TO_WINDOW = 0x1000;
    static readonly nint TD_WARNING_ICON = 0xFFFF;   // MAKEINTRESOURCEW(-1)

    // commctrl.h 里这两个结构在 pshpack1.h 里，按 1 字节对齐
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct TASKDIALOG_BUTTON
    {
        public int nButtonID;
        public nint pszButtonText;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1, CharSet = CharSet.Unicode)]
    struct TASKDIALOGCONFIG
    {
        public uint cbSize;
        public nint hwndParent;
        public nint hInstance;
        public int dwFlags;
        public int dwCommonButtons;
        public string? pszWindowTitle;
        public nint hMainIcon;
        public string? pszMainInstruction;
        public string? pszContent;
        public uint cButtons;
        public nint pButtons;
        public int nDefaultButton;
        public uint cRadioButtons;
        public nint pRadioButtons;
        public int nDefaultRadioButton;
        public string? pszVerificationText;
        public string? pszExpandedInformation;
        public string? pszExpandedControlText;
        public string? pszCollapsedControlText;
        public nint hFooterIcon;
        public string? pszFooter;
        public nint pfCallback;
        public nint lpCallbackData;
        public uint cxWidth;
    }

    [DllImport("comctl32.dll", CharSet = CharSet.Unicode)]
    static extern int TaskDialogIndirect(ref TASKDIALOGCONFIG config, out int button, out int radioButton, out bool verificationChecked);
}

/// 带占位文字的输入框（.NET Framework 的 TextBox 没有 PlaceholderText）
internal sealed class CueTextBox : TextBox
{
    string placeholder = "";

    public string PlaceholderText
    {
        get => placeholder;
        set
        {
            placeholder = value;
            if (IsHandleCreated) Apply();
        }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Apply();
    }

    // wParam = 0：获得焦点后隐藏占位文字
    void Apply() => SendMessageW(Handle, EM_SETCUEBANNER, 0, placeholder);

    const int EM_SETCUEBANNER = 0x1501;
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern nint SendMessageW(nint hwnd, int msg, nint wParam, string lParam);
}

internal static class WinFormsCompat
{
    extension(Icon)
    {
        /// 从 exe/dll 里取指定大小的图标（.NET 8 的 Icon.ExtractIcon）；取不到返回 null
        public static Icon? ExtractIcon(string filePath, int id, int size)
        {
            var handles = new nint[1];
            if (PrivateExtractIconsW(filePath, id, size, size, handles, null, 1, 0) != 1 || handles[0] == 0) return null;
            try { return (Icon)Icon.FromHandle(handles[0]).Clone(); }
            finally { DestroyIcon(handles[0]); }
        }
    }

    extension(Application)
    {
        /// 系统「应用模式」是不是深色（设置 › 个性化 › 颜色）。.NET 9 的 Application.IsDarkModeEnabled 看的也是这个
        public static bool IsDarkModeEnabled
        {
            get
            {
                try
                {
                    using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
                    return key?.GetValue("AppsUseLightTheme") is int light && light == 0;
                }
                catch { return false; }
            }
        }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern uint PrivateExtractIconsW(string file, int index, int cx, int cy, nint[] icons, int[]? ids, uint count, uint flags);
    [DllImport("user32.dll")] static extern bool DestroyIcon(nint icon);
}
