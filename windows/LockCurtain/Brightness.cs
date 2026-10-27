// Brightness.cs —— 离开模式「亮度调到最低」
//
// 走 WMI 的 WmiMonitorBrightness / WmiMonitorBrightnessMethods（root\wmi），只有笔记本内置屏这类
// 由系统管亮度的屏支持；外接显示器的亮度走 DDC/CI，WMI 里没有，跳过（和 Mac 版一样只调内置屏）。
// 台式机和虚拟机上查询直接报「不支持」，什么也不做。
// 撤遮罩时恢复原亮度；进程被强制结束时来不及恢复，需要手动调回。

using System.Management;
using System.Runtime.InteropServices;

namespace LockCurtain;

internal static class Brightness
{
    const string Scope = @"root\wmi";

    /// 支持的屏都调到 0，返回每块屏原来的亮度（InstanceName → 0..100）
    public static Dictionary<string, byte> Dim()
    {
        var saved = new Dictionary<string, byte>();
        try
        {
            using (var current = new ManagementObjectSearcher(Scope, "SELECT InstanceName, CurrentBrightness FROM WmiMonitorBrightness"))
            using (var monitors = current.Get())
                foreach (ManagementObject m in monitors)
                    using (m)
                        saved[(string)m["InstanceName"]] = (byte)m["CurrentBrightness"];
            Set(saved.Keys.ToDictionary(k => k, _ => (byte)0));
            Log.Write($"Brightness: {string.Join(", ", saved.Select(p => $"{p.Key} {p.Value}"))} -> 0");
        }
        catch (Exception e) when (e is ManagementException or COMException)
        {
            Log.Write($"Brightness: 调不了亮度，跳过（{e.Message.Trim()}）");
        }
        return saved;
    }

    public static void Restore(Dictionary<string, byte> saved)
    {
        if (saved.Count == 0) return;
        try
        {
            Set(saved);
            Log.Write($"Brightness: 恢复 {string.Join(", ", saved.Select(p => $"{p.Key} {p.Value}"))}");
        }
        catch (Exception e) when (e is ManagementException or COMException)
        {
            Log.Write($"Brightness: 恢复失败 {e.Message.Trim()}");
        }
    }

    static void Set(Dictionary<string, byte> levels)
    {
        using var methods = new ManagementObjectSearcher(Scope, "SELECT * FROM WmiMonitorBrightnessMethods");
        using var monitors = methods.Get();
        foreach (ManagementObject m in monitors)
            using (m)
                if (levels.TryGetValue((string)m["InstanceName"], out var level))
                    m.InvokeMethod("WmiSetBrightness", new object[] { 0u, level });    // Timeout 0：立即
    }
}
