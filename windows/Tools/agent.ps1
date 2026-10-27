# agent.ps1 —— 在 Windows 里扮演自动化 agent，验证遮罩「挡人不挡 agent」
#
#   agent.ps1 capture <out.png>     用 BitBlt 截整块主屏（pyautogui、mss、PIL ImageGrab 都是这条路），
#                                   打印中心 200x200 区域的平均亮度
#   agent.ps1 click <x> <y>         SendInput 合成一次左键点击（物理像素坐标）
#   agent.ps1 rclick <x> <y>        同上，右键
#   agent.ps1 type <text>           SendInput 逐字合成 Unicode 按键
#   agent.ps1 key <vk>              SendInput 合成一次虚拟键，比如 13 是回车
#   agent.ps1 fg                    打印前台窗口标题
#
# SendInput 合成的输入带 LLKHF_INJECTED / LLMHF_INJECTED，LockCurtain 应该放行。
param([Parameter(Mandatory)][string]$Cmd, [string]$A, [string]$B)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
public static class Agent {
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] public struct U { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public U u; }
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);

    public static void Init() { SetProcessDPIAware(); }
    static uint Send(params INPUT[] a) { return SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT))); }
    static INPUT Mouse(int dx, int dy, uint flags) { var i = new INPUT { type = 0 }; i.u.mi = new MOUSEINPUT { dx = dx, dy = dy, dwFlags = flags }; return i; }
    static INPUT Key(ushort vk, ushort scan, uint flags) { var i = new INPUT { type = 1 }; i.u.ki = new KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags }; return i; }

    public static uint Click(int x, int y, bool right = false) {
        int w = GetSystemMetrics(0), h = GetSystemMetrics(1);
        int ax = x * 65535 / (w - 1), ay = y * 65535 / (h - 1);
        uint down = right ? 0x8008u : 0x8002u, up = right ? 0x8010u : 0x8004u;
        return Send(Mouse(ax, ay, 0x8001), Mouse(ax, ay, down), Mouse(ax, ay, up));
    }
    public static uint Type(string s) {
        uint n = 0;
        foreach (var c in s) n += Send(Key(0, c, 0x4), Key(0, c, 0x4 | 0x2));
        return n;
    }
    public static uint Vk(ushort vk) { return Send(Key(vk, 0, 0), Key(vk, 0, 0x2)); }
    public static string Foreground() { var sb = new StringBuilder(512); GetWindowTextW(GetForegroundWindow(), sb, sb.Capacity); return sb.ToString(); }

    public static double Capture(string path) {
        int w = GetSystemMetrics(0), h = GetSystemMetrics(1);
        using (var bmp = new Bitmap(w, h))
        {
            using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(0, 0, 0, 0, new Size(w, h));
            bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            double sum = 0; int count = 0;
            for (int y = h / 2 - 100; y < h / 2 + 100; y += 4)
                for (int x = w / 2 - 100; x < w / 2 + 100; x += 4) { var p = bmp.GetPixel(x, y); sum += (p.R + p.G + p.B) / 3.0; count++; }
            return sum / count;
        }
    }
}
'@ -ReferencedAssemblies System.Drawing
[Agent]::Init()
switch ($Cmd) {
    'capture' { "capture $A centerMean=$([math]::Round([Agent]::Capture($A), 1))" }
    'click'   { "click ($A,$B) sent=$([Agent]::Click([int]$A, [int]$B))" }
    'rclick'  { "rclick ($A,$B) sent=$([Agent]::Click([int]$A, [int]$B, $true))" }
    'type'    { "type sent=$([Agent]::Type($A))" }
    'key'     { "key $A sent=$([Agent]::Vk([uint16]$A))" }
    'fg'      { "foreground: $([Agent]::Foreground())" }
    default   { throw "unknown command $Cmd" }
}
