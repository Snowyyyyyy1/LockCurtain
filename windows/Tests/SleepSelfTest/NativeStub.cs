// SleepBlockers.cs 只在读 powercfg 时用到 Native（取 OEM 代码页），测解析用不到，给个桩
namespace LockCurtain;

internal static class Native
{
    public static uint GetOEMCP() => 936;
}
