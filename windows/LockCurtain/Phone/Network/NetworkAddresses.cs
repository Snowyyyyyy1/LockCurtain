// NetworkAddresses.cs —— 本机的网络地址：手机里填的 ip:port，和地址行行首的标签。对照 Mac 的 Sources/PhoneNetwork.swift 上半（NetworkAddresses）
//
// 和 Mac 一样：IPv4 + 全局 / ULA 的 IPv6，不要回环、169.254、fe80；同一个地址只列一次；
// 排序：Wi-Fi → 以太网 → Tailscale → 其他，同类里 IPv4 在前，再按网卡名、地址。
// 文案：Camo copy v15.13 §18.6 二（四种标签：Wi-Fi / Tailscale / 以太网 / 其他）。
//
// 和 Mac 不一样的只有「认网卡」这一步（Mac 靠 NWPathMonitor 报的类型 + utun 前缀，Windows 靠 NetworkInterfaceType + 网卡名 / 描述）：
//   * Wi-Fi = Wireless80211；以太网 = 各种 Ethernet；
//   * 隧道（VPN / Tailscale 的 Wintun / WireGuard / TAP …）里 IP 落在 Tailscale 的段（100.64.0.0/10，fd7a:115c:a1e0::/48）才算 Tailscale，
//     别的隧道是「其他」（Mac 对 utun 一样）；
//   * Hyper-V / WSL / VMware / VirtualBox 这类虚拟网卡在 Windows 上也报成 Ethernet，这里算「其他」（Mac 上同类的桥接口 NWPathMonitor 报 other）。

using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace LockCurtain.Phone;

/// 顺序就是列表里的先后（和 Mac 的 rawValue 一样）
internal enum NetworkKind { Wifi = 0, Ethernet = 1, Tailscale = 2, Other = 3 }

/// 网卡大类：Mac 的 NWInterface.InterfaceType + utun 在 Windows 上的对应
internal enum AdapterKind { Wifi, Ethernet, Tunnel, Other }

/// 给手机抄的地址：一个网卡上的一个 IP
internal sealed record NetworkAddressEntry(NetworkKind Kind, string Interface, string Host, bool IsIPv6)
{
    /// 文案：Camo copy v15.13 §18.6 二
    public string Label => Kind switch
    {
        NetworkKind.Wifi => "Wi-Fi",
        NetworkKind.Ethernet => "以太网",
        NetworkKind.Tailscale => "Tailscale",
        _ => "其他",
    };

    /// 手机里填的样子：ip:port，IPv6 用 [::]:port
    public string Text(int port) => IsIPv6 ? $"[{Host}]:{port}" : $"{Host}:{port}";
}

internal static class NetworkAddresses
{
    /// 枚举本机地址：IPv4 + 全局 / ULA 的 IPv6，不要回环、169.254、fe80
    public static List<NetworkAddressEntry> Current()
    {
        var found = new List<NetworkAddressEntry>();
        NetworkInterface[] all;
        try { all = NetworkInterface.GetAllNetworkInterfaces(); }
        catch (NetworkInformationException) { return found; }
        foreach (var ni in all)
        {
            try
            {
                if (ni.OperationalStatus != OperationalStatus.Up || ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                var name = ni.Name;
                var description = ni.Description;
                if (IsNoise(name, description)) continue;
                var kind = AdapterOf(ni.NetworkInterfaceType, name, description);
                foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                {
                    var a = ua.Address;
                    if (a.AddressFamily is not (AddressFamily.InterNetwork or AddressFamily.InterNetworkV6)) continue;
                    // IPv6 还在做重复地址检测 / 已弃用的不列
                    if (OperatingSystem.IsWindows() && a.AddressFamily == AddressFamily.InterNetworkV6 && ua.DuplicateAddressDetectionState != DuplicateAddressDetectionState.Preferred) continue;
                    if (Classify(a.ToString(), name, a.AddressFamily == AddressFamily.InterNetworkV6, kind) is { } entry && !found.Contains(entry))
                        found.Add(entry);
                }
            }
            catch (Exception e) when (e is NetworkInformationException or PlatformNotSupportedException or InvalidOperationException) { }
        }
        return Sort(found);
    }

    /// 列表里的先后：类别 → IPv4 在前 → 网卡名 → 地址（和 Mac 一样）
    public static List<NetworkAddressEntry> Sort(IEnumerable<NetworkAddressEntry> entries) =>
        entries.OrderBy(e => (int)e.Kind).ThenBy(e => e.IsIPv6 ? 1 : 0)
               .ThenBy(e => e.Interface, StringComparer.Ordinal).ThenBy(e => e.Host, StringComparer.Ordinal).ToList();

    /// 一个地址要不要列、算哪一类（纯函数，自测用）
    public static NetworkAddressEntry? Classify(string rawHost, string iface, bool isIPv6, AdapterKind adapter)
    {
        var host = rawHost.Split('%', 2)[0];
        var lower = host.ToLowerInvariant();
        if (isIPv6)
        {
            // 只要全局（2000::/3）和 ULA（fc00::/7）；fe80（链路本地）、::1、:: 都不要
            var firstGroup = lower.Split(':', 2)[0];
            if (!ushort.TryParse(firstGroup.Length == 0 ? "0" : firstGroup, System.Globalization.NumberStyles.AllowHexSpecifier, null, out var word)) return null;
            var isGlobal = (word & 0xE000) == 0x2000;
            var isUla = (word & 0xFE00) == 0xFC00;
            if (!isGlobal && !isUla) return null;
        }
        else
        {
            var parts = host.Split('.').Select(p => int.TryParse(p, out var n) ? n : -1).ToArray();
            if (parts.Length != 4 || parts.Any(n => n < 0 || n > 255)) return null;
            if (parts[0] == 127 || parts[0] == 0 || (parts[0] == 169 && parts[1] == 254)) return null;
        }
        NetworkKind kind;
        if (adapter == AdapterKind.Tunnel && IsTailscale(lower, isIPv6)) kind = NetworkKind.Tailscale;
        else if (adapter == AdapterKind.Tunnel) kind = NetworkKind.Other;
        else kind = adapter switch
        {
            AdapterKind.Wifi => NetworkKind.Wifi,
            AdapterKind.Ethernet => NetworkKind.Ethernet,
            _ => NetworkKind.Other,
        };
        return new NetworkAddressEntry(kind, iface, host, isIPv6);
    }

    /// Tailscale：IPv4 在 100.64.0.0/10（CGNAT），IPv6 在 fd7a:115c:a1e0::/48
    public static bool IsTailscale(string host, bool isIPv6)
    {
        if (isIPv6) return host.StartsWith("fd7a:115c:a1e0:", StringComparison.Ordinal);
        var p = host.Split('.').Select(s => int.TryParse(s, out var n) ? n : -1).ToArray();
        return p.Length == 4 && p[0] == 100 && p[1] is >= 64 and <= 127;
    }

    /// NetworkInterfaceType + 网卡名 / 描述 → 大类（纯函数，自测用）
    public static AdapterKind AdapterOf(NetworkInterfaceType type, string name, string description)
    {
        var text = (name + " " + description).ToLowerInvariant();
        string[] tunnels = ["tailscale", "wintun", "wireguard", "openvpn", "tap-windows", "zerotier", "anyconnect", "vpn"];
        if (type is NetworkInterfaceType.Tunnel or NetworkInterfaceType.Ppp || tunnels.Any(text.Contains)) return AdapterKind.Tunnel;
        string[] virtuals = ["vethernet", "hyper-v", "vmware", "virtualbox", "vmnet", "wsl", "docker", "virtual"];
        if (virtuals.Any(text.Contains)) return AdapterKind.Other;
        return type switch
        {
            NetworkInterfaceType.Wireless80211 => AdapterKind.Wifi,
            NetworkInterfaceType.Ethernet or NetworkInterfaceType.GigabitEthernet or NetworkInterfaceType.FastEthernetT
                or NetworkInterfaceType.FastEthernetFx or NetworkInterfaceType.Ethernet3Megabit => AdapterKind.Ethernet,
            _ => AdapterKind.Other,
        };
    }

    /// 不是给手机连的网卡：Teredo / ISATAP / 6to4 这类过渡隧道
    static bool IsNoise(string name, string description)
    {
        var text = (name + " " + description).ToLowerInvariant();
        return text.Contains("teredo") || text.Contains("isatap") || text.Contains("6to4");
    }
}
