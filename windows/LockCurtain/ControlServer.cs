// ControlServer.cs —— 给 agent、脚本和远程控制用的命令通道
//
// 和 Mac 版的 Unix 域套接字对应，这里用命名管道 \\.\pipe\LockCurtain-<用户 SID>：
//   只有当前用户能连   管道的 ACL 只给当前用户读写，所有者也设成当前用户；
//                     客户端连上后核对所有者，防止别的用户抢先建同名管道冒充服务端
//   最多 1 个实例      第二个进程建不出同名管道，只能有一个 App 提供服务
// 一行命令进，一行 JSON 出。App 自己不监听任何网络端口。
//
// 没用 PipeOptions.CurrentUserOnly：它按令牌的「所有者」设 ACL 和做核对，以管理员身份运行时
// 所有者是 Administrators 组，普通权限的 --send 就连不上了（实测 2026-10-26）。

using System.Diagnostics;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace LockCurtain;

internal sealed class ControlServer
{
    internal static readonly SecurityIdentifier CurrentUser = ControlProtocol.CurrentUser;
    public static readonly string PipeName = ControlProtocol.PipeName;

    readonly Func<string, Task<Dictionary<string, object>>> handler;
    readonly SynchronizationContext ui;
    readonly CancellationTokenSource cts = new();

    public ControlServer(Func<string, Task<Dictionary<string, object>>> handler)
    {
        this.handler = handler;
        ui = SynchronizationContext.Current ?? throw new InvalidOperationException("需要在 UI 线程上创建");
    }

    public void Start() => _ = Task.Run(Loop);

    public void Stop() => cts.Cancel();

    async Task Loop()
    {
        Log.Write($"ControlServer listening on \\\\.\\pipe\\{PipeName}");
        while (!cts.IsCancellationRequested)
        {
            NamedPipeServerStream pipe;
            try
            {
                pipe = NamedPipeServerStreamAcl.Create(PipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                                                       PipeOptions.Asynchronous, 0, 0, CurrentUserOnly());
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Log.Write($"ControlServer 建不了管道（另一个实例在提供服务？）: {e.Message}");
                return;
            }
            await using (pipe)
            {
                try
                {
                    await pipe.WaitForConnectionAsync(cts.Token);
                    using var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen: true);
                    var cmd = (await reader.ReadLineAsync(cts.Token))?.Trim() ?? "";
                    var reply = await RunOnUi(cmd);
                    Log.Write($"control: {cmd} -> {JsonSerializer.Serialize(reply)}");
                    await pipe.WriteAsync(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(reply) + "\n"), cts.Token);
                    await pipe.FlushAsync(cts.Token);
                }
                catch (OperationCanceledException) { return; }
                catch (IOException e) { Log.Write($"ControlServer: {e.Message}"); }
            }
        }
    }

    static PipeSecurity CurrentUserOnly()
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(CurrentUser, PipeAccessRights.ReadWrite, AccessControlType.Allow));
        security.SetOwner(CurrentUser);
        return security;
    }

    Task<Dictionary<string, object>> RunOnUi(string cmd)
    {
        var tcs = new TaskCompletionSource<Dictionary<string, object>>(TaskCreationOptions.RunContinuationsAsynchronously);
        ui.Post(async _ =>
        {
            try { tcs.SetResult(await handler(cmd)); }
            catch (Exception e) { tcs.SetResult(new() { ["ok"] = false, ["error"] = e.Message }); }
        }, null);
        return tcs.Task;
    }
}

/// 命令行客户端：LockCurtainApp.exe --send away|preview|hide|status|settings
internal static class ControlClient
{
    public static int Send(string cmd)
    {
        var reply = TrySend(cmd, 300);
        if (reply == null)
        {
            // 没运行时 status / hide 不拉起 App
            if (cmd is "status" or "hide") return Print("{\"ok\":true,\"running\":false}", 0);
            if (cmd is "away" or "preview" or "settings")
            {
                // 装了以最高权限运行的计划任务就通过它拉起，否则直接启动自己。
                // UseShellExecute：不让 GUI 进程继承我们的标准输出，否则调用方读输出会一直等到 App 退出
                if (!ElevatedTask.TryRun())
                    Process.Start(new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = true });
                reply = TrySend(cmd, 10_000);
            }
            if (reply == null)
                return Print("{\"ok\":false,\"running\":false,\"error\":\"LockCurtain is not running\"}", 1);
        }
        bool ok;
        try { ok = JsonDocument.Parse(reply).RootElement.GetProperty("ok").GetBoolean(); }
        catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException) { ok = false; }
        return Print(reply, ok ? 0 : 1);
    }

    public static string? TrySend(string cmd, int timeoutMs)
    {
        // 设置窗口要能到前台：前台权限在我们（用户刚双击 / 刚敲的命令）手上，让给 App
        if (cmd == "settings") Native.AllowSetForegroundWindow(Native.ASFW_ANY);
        return ControlProtocol.TrySend(cmd, timeoutMs);
    }

    /// GUI 程序没有控制台。输出被重定向（脚本、ssh、管道）时直接写；
    /// 在 cmd / PowerShell 里直接敲时挂到父进程的控制台上
    static int Print(string line, int code)
    {
        var handle = Native.GetStdHandle(Native.STD_OUTPUT_HANDLE);
        if (handle == 0 || handle == -1 || Native.GetFileType(handle) == Native.FILE_TYPE_UNKNOWN)
        {
            if (Native.AttachConsole(Native.ATTACH_PARENT_PROCESS))
            {
                using var con = new StreamWriter(new FileStream("CONOUT$", FileMode.Open, FileAccess.Write));
                con.WriteLine(line);
            }
            return code;
        }
        using var stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false));
        stdout.WriteLine(line);
        return code;
    }
}
