// NetworkWire.cs —— 手机走网络（TCP）连电脑的线格式，逐条对照 Mac 的 Sources/PairingCrypto.swift 末尾（NetFraming / NetworkCommand）
// 和 Sources/PairingAuthority.swift（NetworkPolicy）。只有作用在 byte[] / string 上的纯函数，测试里直接跑。
//
//   * 分帧：每条消息前面 2 字节大端长度，一帧一整条 PairingCrypto 消息（1...1024）；长度 0 或超过 1024 就断开
//   * 网络上手机只能 ping / away / awake:off|1h|2h|5h|always / name:<名字>，其余一律拒绝（默认拒绝）
//   * 除 ping 外，网络上的命令字符串是 n1:<32 位十六进制 nonce>:<命令>，nonce 是电脑刚发的签名 Poll 里的，只能用一次

namespace LockCurtain.Phone;

/// 消息是从哪条链路来的。蓝牙的行为从来没变；网络收紧（见 NetworkPolicy）
internal enum Transport { Bluetooth, Network }

/// TCP 上的分帧：2 字节大端长度 + 一整条 PairingCrypto 消息（1...MaxMessage 字节）
internal static class NetFraming
{
    public const int MaxMessage = PairingFraming.MaxMessage;

    /// 加上长度头；空消息或超长返回 null
    public static byte[]? Frame(byte[] message)
    {
        if (message.Length < 1 || message.Length > MaxMessage) return null;
        return [(byte)(message.Length >> 8), (byte)(message.Length & 0xFF), .. message];
    }

    /// 收字节流拼帧：随便切开、随便合并都行。头里的长度是 0 或超过 MaxMessage 就坏了（IsBroken），
    /// 之后什么都不再交出来，调用方应当断开连接
    internal sealed class Reader
    {
        readonly List<byte> buffer = new();
        public bool IsBroken { get; private set; }

        public List<byte[]> Feed(ReadOnlySpan<byte> bytes)
        {
            var o = new List<byte[]>();
            if (IsBroken) return o;
            buffer.AddRange(bytes.ToArray());
            var start = 0;
            while (buffer.Count - start >= 2)
            {
                var length = buffer[start] << 8 | buffer[start + 1];
                if (length < 1 || length > MaxMessage)
                {
                    IsBroken = true;
                    buffer.Clear();
                    return o;
                }
                if (buffer.Count - start < 2 + length) break;
                o.Add(buffer.GetRange(start + 2, length).ToArray());
                start += 2 + length;
            }
            buffer.RemoveRange(0, start);
            return o;
        }
    }
}

/// 走网络时手机能做什么：默认拒绝，只有明确列出来的才放行。
/// 规则在接收这一侧，不靠签名里带什么标记，所以蓝牙上签的撤下 / 解除配对被拿到网络上重放也是拒绝
internal static class NetworkPolicy
{
    /// 命令（已去掉 n1: 标记）网络上是否允许。ping、away、awake:off|1h|2h|5h|always、name:*
    public static bool Allows(string command)
    {
        if (command.StartsWith("name:", StringComparison.Ordinal)) return true;
        return command.ToLowerInvariant() is "ping" or "away" or "awake:off" or "awake:1h" or "awake:2h" or "awake:5h" or "awake:always";
    }
}

/// 走网络的命令字符串：除 ping 外是 n1:<32 位十六进制 nonce>:<命令>（nonce 在签名里，单次有效）
internal static class NetworkCommand
{
    /// 传输标记
    public const string NoncePrefix = "n1:";

    /// 网络命令字符串 → (nonce?, 命令)；有 n1: 前缀但格式不对返回 null
    public static (byte[]? Nonce, string Command)? Unwrap(string command)
    {
        if (!command.StartsWith(NoncePrefix, StringComparison.Ordinal)) return (null, command);
        var rest = command[NoncePrefix.Length..];
        const int hexLength = PairingCrypto.NonceLength * 2;
        if (rest.Length < hexLength + 1 || rest[hexLength] != ':') return null;
        if (FromHex(rest[..hexLength]) is not { } nonce) return null;
        return (nonce, rest[(hexLength + 1)..]);
    }

    /// 手机：把命令包上 nonce（ping 不用）
    public static string Wrap(string command, byte[] nonce) => NoncePrefix + Bytes.Hex(nonce) + ":" + command;

    /// 大小写十六进制都认；奇数长度或有别的字符返回 null
    public static byte[]? FromHex(string hex)
    {
        if (hex.Length % 2 != 0) return null;
        var o = new byte[hex.Length / 2];
        for (var i = 0; i < o.Length; i++)
        {
            var hi = Nibble(hex[2 * i]);
            var lo = Nibble(hex[2 * i + 1]);
            if (hi < 0 || lo < 0) return null;
            o[i] = (byte)(hi << 4 | lo);
        }
        return o;
    }

    static int Nibble(char c) => c switch
    {
        >= '0' and <= '9' => c - '0',
        >= 'a' and <= 'f' => c - 'a' + 10,
        >= 'A' and <= 'F' => c - 'A' + 10,
        _ => -1,
    };
}
