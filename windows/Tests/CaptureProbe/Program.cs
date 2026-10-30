// CaptureProbe —— 遮罩下面的窗口，各种抓屏方式能不能拍到、拍到的是不是实时的（会在屏幕上真的盖一层遮罩）
//
// 在 Mac 上编（第一次要从 NuGet 下 Windows SDK 的投影包），拷进 Windows，在登录用户的会话里跑：
//   cd windows/Tests/CaptureProbe && dotnet publish -c Release -r win-arm64 --self-contained -p:PublishSingleFile=true -o out
//   CaptureProbe.exe            用已安装的 LockCurtain 的预览遮罩（--send preview / hide）；全部透过去返回 0，否则 1
//   CaptureProbe.exe control    对照：起一个 --no-stealth --preview 的临时实例，抓屏应该拍到遮罩。
//                               先停掉正式实例（它以最高权限运行，要管理员 taskkill），测完 schtasks /run /tn LockCurtain
// LockCurtainApp.exe 默认在 C:\Program Files\LockCurtain，别处用环境变量 LOCKCURTAIN_EXE 指定。
//
// 开一块绿色的置顶窗口，拉起遮罩，变色（洋红）前后各抓一次：BitBlt（SRCCOPY | CAPTUREBLT，pyautogui、mss、PIL 的抓法）、
// DXGI 桌面复制、Windows.Graphics.Capture、PrintWindow（只画目标窗口自己，不受遮罩影响）。
// 只取目标窗口中心一个像素，不存图。结果追加写到 exe 旁边的 capture-probe.txt（WinExe 没有控制台）。
// 2026-10-28 Win11 ARM（Parallels）：正式遮罩下四种都拍到绿 → 洋红；对照组前三种拍到的是遮罩。

using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Graphics.Imaging;
using WinRT;

string exe = Environment.GetEnvironmentVariable("LOCKCURTAIN_EXE") ?? @"C:\Program Files\LockCurtain\LockCurtainApp.exe";
string resultFile = Path.Combine(AppContext.BaseDirectory, "capture-probe.txt");
bool control = args.Contains("control");

void Log(string s) { File.AppendAllText(resultFile, s + "\r\n", System.Text.Encoding.UTF8); }

Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
var form = new Target();
form.Shown += async (_, _) =>
{
    try { await Run(); } catch (Exception e) { Log("出错: " + e); }
    form.Close();
};
Application.Run(form);

async Task Run()
{
    await Task.Delay(800);
    Process? temp = null;
    if (control) temp = Process.Start(exe, "--no-stealth --preview");
    else Send("preview");
    await Task.Delay(1500);
    var before = await Cap.All(form);
    form.BackColor = Color.FromArgb(255, 0, 255);
    form.Refresh();
    await Task.Delay(1000);
    var after = await Cap.All(form);
    string status = control ? "（对照：不隐身的临时实例）" : "status " + Send("status");
    if (control) { temp!.Kill(); temp.WaitForExit(); } else Send("hide");
    // 正式遮罩：三种整屏抓法都要拍到绿 → 洋红（PrintWindow 不受遮罩影响，不算）
    bool ok = !control && before.Screen.All(c => c == "绿") && after.Screen.All(c => c == "洋红");
    if (!control) Environment.ExitCode = ok ? 0 : 1;
    Log($"{(control ? "[对照 --no-stealth]" : ok ? "✅ [正式遮罩]" : "❌ [正式遮罩]")} {status}\r\n    变色前: {before.Text}\r\n    变色后: {after.Text}");
}

string Send(string cmd)
{
    var p = Process.Start(new ProcessStartInfo(exe, "--send " + cmd) { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true })!;
    var o = p.StandardOutput.ReadToEnd();
    p.WaitForExit();
    return o.Trim();
}

sealed class Target : Form
{
    public Target()
    {
        FormBorderStyle = FormBorderStyle.None;
        BackColor = Color.FromArgb(0, 255, 0);
        TopMost = true;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        var s = Screen.PrimaryScreen!.Bounds;
        Bounds = new Rectangle(s.X + s.Width / 2 - 300, s.Y + s.Height / 2 - 200, 600, 400);
    }
    protected override bool ShowWithoutActivation => true;
}

static class Cap
{
    public record Result(string[] Screen, string Text);

    public static async Task<Result> All(Form f)
    {
        N.GetWindowRect(f.Handle, out var r);
        int cx = (r.Left + r.Right) / 2, cy = (r.Top + r.Bottom) / 2;
        var hmon = N.MonitorFromWindow(f.Handle, 2);
        var mi = new N.MONITORINFO { cbSize = Marshal.SizeOf<N.MONITORINFO>() };
        N.GetMonitorInfo(hmon, ref mi);
        int mx = cx - mi.rcMonitor.Left, my = cy - mi.rcMonitor.Top;
        string bitblt = Try(() => BitBlt(cx, cy));
        string dda = Try(() => Dda(f.Handle, mx, my));
        string wgc;
        try { wgc = await Wgc(hmon, mx, my); } catch (Exception e) { wgc = Fail(e); }
        string pw = Try(() => PrintWin(f.Handle));
        string Head(string v) => v.Split(' ')[0];
        return new Result([Head(bitblt), Head(dda), Head(wgc)], $"BitBlt={bitblt}  DXGI桌面复制={dda}  WGC={wgc}  PrintWindow={pw}");
    }

    static string Fail(Exception e) => "失败 " + e.GetType().Name + ": " + e.Message;
    static string Try(Func<string> f) { try { return f(); } catch (Exception e) { return Fail(e); } }

    static string Classify(Color c) =>
        c.G > 180 && c.R < 90 && c.B < 90 ? "绿" :
        c.R > 180 && c.B > 180 && c.G < 90 ? "洋红" :
        $"其他({c.R},{c.G},{c.B})";

    static string BitBlt(int x, int y)
    {
        using var bmp = new Bitmap(1, 1);
        using (var g = Graphics.FromImage(bmp))
        {
            var dst = g.GetHdc();
            var src = N.GetDC(0);
            N.BitBlt(dst, 0, 0, 1, 1, src, x, y, 0x00CC0020 | 0x40000000);   // SRCCOPY | CAPTUREBLT，mss / PIL ImageGrab 的抓法
            N.ReleaseDC(0, src);
            g.ReleaseHdc(dst);
        }
        return Classify(bmp.GetPixel(0, 0));
    }

    static string PrintWin(IntPtr h)
    {
        N.GetWindowRect(h, out var r);
        int w = r.Right - r.Left, ht = r.Bottom - r.Top;
        using var bmp = new Bitmap(w, ht);
        using (var g = Graphics.FromImage(bmp))
        {
            var hdc = g.GetHdc();
            N.PrintWindow(h, hdc, 2);
            g.ReleaseHdc(hdc);
        }
        return Classify(bmp.GetPixel(w / 2, ht / 2));
    }

    // ---- D3D11 / DXGI：按 vtable 槽位直接调 ----
    static readonly Guid IID_IDXGIDevice = new("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
    static readonly Guid IID_ID3D11Texture2D = new("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
    static IntPtr device, context;
    static IDirect3DDevice? winrtDevice;

    static void EnsureDevice()
    {
        if (device != 0) return;
        Check(N.D3D11CreateDevice(0, 1, 0, 0x20, 0, 0, 7, out device, out _, out context), "D3D11CreateDevice");
    }
    static unsafe IntPtr Vt(IntPtr o, int slot) => (*(IntPtr**)o)[slot];
    static IntPtr QI(IntPtr o, Guid iid) { Check(Marshal.QueryInterface(o, in iid, out var p), "QueryInterface"); return p; }
    static void Check(int hr, string what) { if (hr < 0) throw new Exception($"{what} 0x{hr:X8}"); }
    static void Rel(IntPtr p) { if (p != 0) Marshal.Release(p); }

    static unsafe string Dda(IntPtr target, int x, int y)
    {
        EnsureDevice();
        IntPtr dxgiDev = QI(device, IID_IDXGIDevice), adapter = 0, output = 0, dup = 0;
        try
        {
            Check(((delegate* unmanaged<IntPtr, IntPtr*, int>)Vt(dxgiDev, 7))(dxgiDev, &adapter), "GetAdapter");
            Check(((delegate* unmanaged<IntPtr, uint, IntPtr*, int>)Vt(adapter, 7))(adapter, 0, &output), "EnumOutputs");
            // IDXGIOutput1::DuplicateOutput（槽 22）。EnumOutputs 拿到的对象本身就实现了 IDXGIOutput1
            int hr = ((delegate* unmanaged<IntPtr, IntPtr, IntPtr*, int>)Vt(output, 22))(output, device, &dup);
            if (hr < 0) return $"DuplicateOutput 失败 0x{hr:X8}";
            byte* info = stackalloc byte[64];
            IntPtr res = 0;
            int tries = 0;
            for (; tries < 12; tries++)
            {
                N.InvalidateRect(target, 0, true);
                N.UpdateWindow(target);
                hr = ((delegate* unmanaged<IntPtr, uint, byte*, IntPtr*, int>)Vt(dup, 8))(dup, 500, info, &res);
                if (hr == unchecked((int)0x887A0027)) continue;   // DXGI_ERROR_WAIT_TIMEOUT
                if (hr < 0) break;
                if (*(long*)info != 0) break;                     // LastPresentTime：0 表示这一帧只有鼠标更新、没有画面
                Rel(res); res = 0;
                ((delegate* unmanaged<IntPtr, int>)Vt(dup, 14))(dup);
            }
            if (hr < 0) return $"AcquireNextFrame 失败 0x{hr:X8}";
            if (res == 0) return "12 次都没拿到带画面的帧";
            IntPtr tex = 0, staging = 0;
            try
            {
                tex = QI(res, IID_ID3D11Texture2D);
                uint* desc = stackalloc uint[11];
                ((delegate* unmanaged<IntPtr, uint*, void>)Vt(tex, 10))(tex, desc);
                desc[2] = 1; desc[3] = 1; desc[7] = 3; desc[8] = 0; desc[9] = 0x20000; desc[10] = 0;   // STAGING，CPU 可读
                Check(((delegate* unmanaged<IntPtr, uint*, IntPtr, IntPtr*, int>)Vt(device, 5))(device, desc, 0, &staging), "CreateTexture2D");
                ((delegate* unmanaged<IntPtr, IntPtr, IntPtr, void>)Vt(context, 47))(context, staging, tex);
                byte* mapped = stackalloc byte[16];
                Check(((delegate* unmanaged<IntPtr, IntPtr, uint, int, uint, byte*, int>)Vt(context, 14))(context, staging, 0, 1, 0, mapped), "Map");
                byte* data = *(byte**)mapped;
                uint pitch = *(uint*)(mapped + 8);
                byte* px = data + y * pitch + x * 4;
                var c = Color.FromArgb(px[2], px[1], px[0]);
                ((delegate* unmanaged<IntPtr, IntPtr, uint, void>)Vt(context, 15))(context, staging, 0);
                return Classify(c) + $" ({desc[0]}x{desc[1]}，第 {tries + 1} 帧)";
            }
            finally
            {
                Rel(staging); Rel(tex); Rel(res);
                ((delegate* unmanaged<IntPtr, int>)Vt(dup, 14))(dup);   // ReleaseFrame
            }
        }
        finally { Rel(dup); Rel(output); Rel(adapter); Rel(dxgiDev); }
    }

    // ---- Windows.Graphics.Capture ----
    [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IGraphicsCaptureItemInterop
    {
        IntPtr CreateForWindow([In] IntPtr window, [In] ref Guid iid);
        IntPtr CreateForMonitor([In] IntPtr monitor, [In] ref Guid iid);
    }

    static async Task<string> Wgc(IntPtr hmon, int x, int y)
    {
        EnsureDevice();
        if (winrtDevice == null)
        {
            var dxgi = QI(device, IID_IDXGIDevice);
            Check(N.CreateDirect3D11DeviceFromDXGIDevice(dxgi, out var insp), "CreateDirect3D11DeviceFromDXGIDevice");
            Rel(dxgi);
            winrtDevice = MarshalInterface<IDirect3DDevice>.FromAbi(insp);
        }
        var interop = ActivationFactory.Get("Windows.Graphics.Capture.GraphicsCaptureItem").AsInterface<IGraphicsCaptureItemInterop>();
        var iid = new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760");
        var itemPtr = interop.CreateForMonitor(hmon, ref iid);
        var item = GraphicsCaptureItem.FromAbi(itemPtr);
        Marshal.Release(itemPtr);

        using var pool = Direct3D11CaptureFramePool.CreateFreeThreaded(winrtDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 1, item.Size);
        var tcs = new TaskCompletionSource<Direct3D11CaptureFrame>(TaskCreationOptions.RunContinuationsAsynchronously);
        pool.FrameArrived += (p, _) => { var fr = p.TryGetNextFrame(); if (fr != null && !tcs.TrySetResult(fr)) fr.Dispose(); };
        using var session = pool.CreateCaptureSession(item);
        try { session.IsCursorCaptureEnabled = false; } catch { }
        session.StartCapture();
        if (await Task.WhenAny(tcs.Task, Task.Delay(3000)) != tcs.Task) return "3 秒内没拿到帧";
        using var frame = tcs.Task.Result;
        using var sb = await SoftwareBitmap.CreateCopyFromSurfaceAsync(frame.Surface, BitmapAlphaMode.Premultiplied);
        var buf = new Windows.Storage.Streams.Buffer((uint)(sb.PixelWidth * sb.PixelHeight * 4));
        sb.CopyToBuffer(buf);
        var bytes = buf.ToArray();
        int o = (y * sb.PixelWidth + x) * 4;
        return Classify(Color.FromArgb(bytes[o + 2], bytes[o + 1], bytes[o])) + $" ({sb.PixelWidth}x{sb.PixelHeight})";
    }
}

static class N
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("user32.dll")] public static extern bool InvalidateRect(IntPtr h, IntPtr rect, bool erase);
    [DllImport("user32.dll")] public static extern bool UpdateWindow(IntPtr h);
    [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
    [DllImport("d3d11.dll")]
    public static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, IntPtr levels, uint numLevels,
                                               uint sdk, out IntPtr device, out int level, out IntPtr context);
    [DllImport("d3d11.dll")] public static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);
}
