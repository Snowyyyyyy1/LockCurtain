// KeepAwakeWire.cs —— protocol v3 里和保持唤醒、手机名有关的纯逻辑（对照 handoff protocol-v3.md §1 / §3）
//
//   * 手机发来的命令字符串：awake:off / awake:1h / awake:2h / awake:5h / awake:always；name:<utf8>
//   * 电脑发回的 KeepAwakeState 的 mode / endsAt / appName 怎么填
// 不认识的 awake:xxx 当没收到（老 / 新版本混用时不出错）。

namespace LockCurtain.Phone;

/// KeepAwakeState 的 mode 字节
internal enum KeepAwakeWireMode : byte
{
    Off = 0,
    /// 定了时长（手机显示「还剩 1 小时 20 分」）
    Timed = 1,
    Always = 2,
    /// 到电脑上定的某个时刻（手机显示「到 18:30」）
    UntilClock = 3,
    /// 某个程序开着时（appName）
    WhileApp = 4,
}

/// 要发给手机的保持唤醒现状
internal readonly record struct KeepAwakeWireState(KeepAwakeWireMode Mode, ulong EndsAt, string AppName)
{
    public static readonly KeepAwakeWireState Off = new(KeepAwakeWireMode.Off, 0, "");

    /// endUtc 只对 Timed / UntilClock 有用，app 只对 WhileApp 有用；用不上的填 0 / 空
    public static KeepAwakeWireState Make(KeepAwakeWireMode mode, DateTime? endUtc = null, string? app = null) => mode switch
    {
        KeepAwakeWireMode.Timed or KeepAwakeWireMode.UntilClock =>
            new(mode, endUtc is { } e ? (ulong)Math.Max(0, new DateTimeOffset(DateTime.SpecifyKind(e, DateTimeKind.Utc)).ToUnixTimeSeconds()) : 0, ""),
        KeepAwakeWireMode.WhileApp => new(mode, 0, app ?? ""),
        _ => new(mode, 0, ""),
    };

    public byte[] Seal(Guid phoneID, ulong seq, byte[] key) =>
        PairingCrypto.MakeKeepAwakeState(phoneID, seq, (byte)Mode, EndsAt, AppName, key);
}

internal enum AwakeRequestKind { Off, Always, For }

/// 手机的 awake:* 命令
internal readonly record struct AwakeRequest(AwakeRequestKind Kind, TimeSpan Duration = default)
{
    public const string Prefix = "awake:";

    /// 不是 awake:* 或不认识的时长返回 null
    public static AwakeRequest? Parse(string command) => command switch
    {
        "awake:off" => new AwakeRequest(AwakeRequestKind.Off),
        "awake:always" => new AwakeRequest(AwakeRequestKind.Always),
        "awake:1h" => new AwakeRequest(AwakeRequestKind.For, TimeSpan.FromHours(1)),
        "awake:2h" => new AwakeRequest(AwakeRequestKind.For, TimeSpan.FromHours(2)),
        "awake:5h" => new AwakeRequest(AwakeRequestKind.For, TimeSpan.FromHours(5)),
        _ => null,
    };
}

/// 手机名（name:<utf8>）
internal static class PhoneName
{
    public const string Prefix = "name:";
    public const int MaxBytes = 60;
    /// 老记录 / 手机没发名字时显示的
    public const string Default = "iPhone";

    /// 去掉控制字符、首尾空白，截到 60 字节（不切开一个字）；空的返回 null
    public static string? Clean(string raw)
    {
        var text = new string(raw.Where(c => !char.IsControl(c)).ToArray()).Trim();
        if (text.Length == 0) return null;
        var bytes = PairingCrypto.Utf8Prefix(text, MaxBytes);
        var cut = System.Text.Encoding.UTF8.GetString(bytes).Trim();
        return cut.Length == 0 ? null : cut;
    }
}
