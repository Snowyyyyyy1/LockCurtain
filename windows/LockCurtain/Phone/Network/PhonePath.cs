// PhonePath.cs —— 手机现在走哪条链路连着（对照 Mac 的 PhonePairing.swift 里的 PhonePath）。纯函数，PhoneSelfTest 里直接测。
//
// 两条都连着时算蓝牙。「已连上」后面带链路：已连上 · 蓝牙 / 已连上 · 网络（文案：Camo copy v15.8 §18.6，Mac 同款）。

namespace LockCurtain.Phone;

internal enum PhonePath { Bluetooth, Network }

internal static class PhonePathRules
{
    public static PhonePath? Resolve(bool bluetooth, bool network) =>
        bluetooth ? PhonePath.Bluetooth : network ? PhonePath.Network : null;

    /// 几台手机各自的链路合成一个：都一样就是它；不一样（或没有）就是 null，界面上只写「已连上」
    public static PhonePath? Common(IEnumerable<PhonePath> paths)
    {
        var list = paths.ToList();
        return list.Count > 0 && list.All(p => p == list[0]) ? list[0] : null;
    }

    public static string ConnectedText(PhonePath? path) => path switch
    {
        PhonePath.Bluetooth => "已连上 · 蓝牙",
        PhonePath.Network => "已连上 · 网络",
        _ => "已连上",
    };
}

/// 「手机」页 › 网络 的字。来源：Camo copy v15.13 §18.2、§18.6 三 / 四 / 五；和 Mac 的 SettingsWindow.swift（networkSection）一字不差
internal static class NetworkText
{
    public const string Switch = "让手机走网络连这台电脑";
    public const string Copy = "拷贝";
    public const string Copied = "已拷贝";
    public const string Failed = "没能打开。这个端口被别的程序占了，或者系统没放行。关掉占着它的程序，再打开一次。";
    public const string NoAddress = "这台电脑现在没有可用的网络地址。连上网络以后再打开一次。";
    public const string Allowed = "打开以后，手机能盖上幕布、开关保持唤醒。撤下只能靠蓝牙，走网络时撤不了。";
    public const string Tailscale = "手机和电脑不在同一个网络也能连，前提是两边都装了 Tailscale 这类工具。不动路由器，也不会自己开端口。";
    /// 「远程控制」页脚（§18.6 五）：前半句留着，后面换成这一段
    public const string RemoteFooter = "一行命令进，一行 JSON 出；成功时退出码 0。默认不监听任何网络端口，只接受本机当前用户的连接。"
        + "打开走网络以后，会在这台电脑的一个端口上等手机来连；进来的命令要带你手机里那把钥匙，签名不对一律不执行。"
        + "把 away 换成 hide、status、preview、settings，就是另外四个命令。照这行抄，别自己改。";
}
