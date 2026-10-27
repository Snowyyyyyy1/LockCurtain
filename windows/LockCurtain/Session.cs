// Session.cs —— 当前会话是否锁屏
//
// WTSQuerySessionInformation(WTSSessionInfoEx) 的 SessionFlags：
//   WTS_SESSIONSTATE_LOCK = 0，WTS_SESSIONSTATE_UNLOCK = 1，其他值表示查不到。
// WTSINFOEXW 里的联合体含 LARGE_INTEGER，按 8 字节对齐，所以 Level(4) 之后空 4 字节，
// SessionId 在 8，SessionState 在 12，SessionFlags 在 16。

using System.Runtime.InteropServices;

namespace LockCurtain;

internal static class Session
{
    const uint WTS_CURRENT_SESSION = 0xFFFFFFFF;
    const int WTSSessionInfoEx = 25;

    /// 查不到时返回 null，调用方退回用锁屏通知记下的状态
    public static bool? QueryLocked()
    {
        if (!Native.WTSQuerySessionInformationW(0, WTS_CURRENT_SESSION, WTSSessionInfoEx, out var buf, out var bytes))
            return null;
        try
        {
            if (bytes < 20 || Marshal.ReadInt32(buf, 0) != 1) return null;
            return Marshal.ReadInt32(buf, 16) switch
            {
                0 => true,
                1 => false,
                _ => null,
            };
        }
        finally { Native.WTSFreeMemory(buf); }
    }

    /// 锁屏通知记下的状态；App 启动时会话一定是解锁的（否则用户启动不了它）
    public static bool LockedByNotification;

    public static bool IsLocked() => QueryLocked() ?? LockedByNotification;
}
