// ComSecurity.cs —— 进程级 COM 安全设置，给「配对手机」的蓝牙通知（GATT notify）用
//
// 问题：桌面程序（尤其是以管理员 / uiAccess 运行的，LockCurtain 就是）订阅 GATT 特征的通知时，
// 订阅本身返回 Success，但 ValueChanged 一次都不触发。原因是通知由蓝牙服务（以 LocalService 身份跑在别的进程里）
// 通过 COM 回调进本进程，而本进程默认的 COM 访问权限（提权进程尤其严）不让 LocalService 回调进来。
// 公认的解决办法：在用任何 COM / WinRT 之前调用一次 CoInitializeSecurity，
// 认证级别 RPC_C_AUTHN_LEVEL_DEFAULT、模拟级别 RPC_C_IMP_LEVEL_IDENTIFY、EOAC_NONE，
// 并给一个安全描述符，允许 LocalService（LS）、NetworkService（NS）、SYSTEM、管理员、本人和 AppContainer 本机调用进来：
//   O:BAG:BAD:(A;;0x7;;;PS)(A;;0x3;;;SY)(A;;0x7;;;BA)(A;;0x3;;;AC)(A;;0x3;;;LS)(A;;0x3;;;NS)
//   （0x1 = COM_RIGHTS_EXECUTE，0x2 = EXECUTE_LOCAL，0x4 = EXECUTE_REMOTE；PS = 本人）
// 出处（2026-11-03 写这里时没法上网核对，按记忆引用，链接待核对）：
//   * Microsoft Q&A / Stack Overflow「GattCharacteristic.ValueChanged not firing in WPF / desktop app」一类问答里
//     微软员工给的 CoInitializeSecurity + 上面这串 SDDL 的写法；
//   * Windows-universal-samples 的 BluetoothLE 示例 issue 里同样的讨论（桌面 / 提权进程收不到通知）。
// CoInitializeSecurity 整个进程只能调一次，而且要在第一次跨进程 COM 调用之前：所以放在 Main 的最开头。
// [STAThread] 让 CLR 在进 Main 之前已经 CoInitialize 过了，这正是它要求的前提。
// 已经有人调过 / 太晚了（RPC_E_TOO_LATE）就只记一行日志、照常运行：WinForms 和别的 COM 用法不受影响，
// 只是蓝牙通知可能收不到（ble.log 里会看到订阅成功但没有任何消息）。

using System.Runtime.InteropServices;

namespace LockCurtain;

internal static class ComSecurity
{
    const string Sddl = "O:BAG:BAD:(A;;0x7;;;PS)(A;;0x3;;;SY)(A;;0x7;;;BA)(A;;0x3;;;AC)(A;;0x3;;;LS)(A;;0x3;;;NS)";
    const uint RPC_C_AUTHN_LEVEL_DEFAULT = 0;
    const uint RPC_C_IMP_LEVEL_IDENTIFY = 2;
    const uint EOAC_NONE = 0;
    const int RPC_E_TOO_LATE = unchecked((int)0x80010119);
    const uint SDDL_REVISION_1 = 1;

    /// 结果写进 lockcurtain.log；任何失败都不抛
    public static void Initialize()
    {
        nint relative = 0;
        var buffers = new List<nint>();
        try
        {
            if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(Sddl, SDDL_REVISION_1, out relative, out _))
            {
                Log.Write($"CoInitializeSecurity skipped: SDDL conversion failed, error={Marshal.GetLastWin32Error()}");
                return;
            }
            // CoInitializeSecurity 要绝对格式的安全描述符；转出来的是自相对格式，先问各部分要多大
            uint sdSize = 0, daclSize = 0, saclSize = 0, ownerSize = 0, groupSize = 0;
            MakeAbsoluteSD(relative, 0, ref sdSize, 0, ref daclSize, 0, ref saclSize, 0, ref ownerSize, 0, ref groupSize);
            nint Alloc(uint size)
            {
                var p = Marshal.AllocHGlobal((int)Math.Max(size, 1));
                buffers.Add(p);
                return p;
            }
            var sd = Alloc(sdSize);
            var dacl = Alloc(daclSize);
            var sacl = Alloc(saclSize);
            var owner = Alloc(ownerSize);
            var group = Alloc(groupSize);
            if (!MakeAbsoluteSD(relative, sd, ref sdSize, dacl, ref daclSize, sacl, ref saclSize, owner, ref ownerSize, group, ref groupSize))
            {
                Log.Write($"CoInitializeSecurity skipped: MakeAbsoluteSD failed, error={Marshal.GetLastWin32Error()}");
                return;
            }
            var hr = CoInitializeSecurity(sd, -1, 0, 0, RPC_C_AUTHN_LEVEL_DEFAULT, RPC_C_IMP_LEVEL_IDENTIFY, 0, EOAC_NONE, 0);
            if (hr == 0)
            {
                Log.Write("CoInitializeSecurity ok (bluetooth notifications can call back into this process)");
                // 设置成功后 COM 会一直引用这份安全描述符：buffers 不释放
                buffers.Clear();
            }
            else if (hr == RPC_E_TOO_LATE)
                Log.Write("CoInitializeSecurity too late (RPC_E_TOO_LATE): COM security already set; bluetooth notifications may not arrive");
            else
                Log.Write($"CoInitializeSecurity failed hr=0x{hr:X8}; bluetooth notifications may not arrive");
        }
        catch (Exception e)
        {
            Log.Write($"CoInitializeSecurity skipped: {e.GetType().Name}: {e.Message}");
        }
        finally
        {
            foreach (var p in buffers) Marshal.FreeHGlobal(p);
            if (relative != 0) LocalFree(relative);
        }
    }

    [DllImport("ole32.dll")]
    static extern int CoInitializeSecurity(nint pSecDesc, int cAuthSvc, nint asAuthSvc, nint pReserved1,
                                           uint dwAuthnLevel, uint dwImpLevel, nint pAuthList, uint dwCapabilities, nint pReserved3);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string stringSecurityDescriptor, uint revision,
                                                                            out nint securityDescriptor, out uint size);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool MakeAbsoluteSD(nint selfRelative, nint absolute, ref uint absoluteSize, nint dacl, ref uint daclSize,
                                      nint sacl, ref uint saclSize, nint owner, ref uint ownerSize, nint primaryGroup, ref uint primaryGroupSize);

    [DllImport("kernel32.dll")]
    static extern nint LocalFree(nint mem);
}
