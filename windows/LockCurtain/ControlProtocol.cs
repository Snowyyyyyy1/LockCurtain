// ControlProtocol.cs —— 命名管道客户端协议，主程序和 LockCurtainCtl 共用
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;

namespace LockCurtain;

internal static class ControlProtocol
{
    internal static readonly SecurityIdentifier CurrentUser = WindowsIdentity.GetCurrent().User!;
    public static readonly string PipeName = "LockCurtain-" + CurrentUser.Value;

    /// 连管道发一行命令，读回一行 JSON。连不上/超时返回 null。
    /// 核对管道所有者是当前用户，防止别的用户抢建同名管道冒充服务端。
    public static string? TrySend(string cmd, int timeoutMs)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut);
            pipe.Connect(timeoutMs);
            if (pipe.GetAccessControl().GetOwner(typeof(SecurityIdentifier)) != CurrentUser) return null;
            pipe.Write(Encoding.UTF8.GetBytes(cmd + "\n"));
            pipe.Flush();
            using var reader = new StreamReader(pipe, Encoding.UTF8);
            return reader.ReadLine();
        }
        catch (Exception e) when (e is TimeoutException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}
