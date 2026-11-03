// PairingCrypto.cs —— 配对握手和命令签名，逐条对照 Mac 的 Sources/PairingCrypto.swift（线格式见那个文件的文件头）
//
// 只有作用在 byte[] 上的纯函数，不知道底下是 BLE 还是别的。和 Swift 逐字节一致（Tests/PhoneVectors 核对）。
//   * phoneID 在线上是 16 字节，UUID 的标准（大端）字节序：Guid 一律用 ToByteArray(bigEndian: true) / new Guid(b, bigEndian: true)。
//   * 计数 / seq 是 8 字节大端。
//   * 钥匙是 32 字节原始字节（Swift 的 SymmetricKey）。
// 线格式里没有「只有一台电脑」的假设：每条消息只带 phoneID，电脑这边按 phoneID 各管各的钥匙和计数。

using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace LockCurtain.Phone;

internal enum Kind : byte
{
    PairRequest = 0x01,
    PairResponse = 0x02,
    Command = 0x03,
    Revoke = 0x04,
    State = 0x05,
    Ack = 0x06,
    PairReject = 0x07,
    PairConfirm = 0x08,
    PairAccepted = 0x09,
    PairAbort = 0x0A,
    Poll = 0x0B,
    Presence = 0x0C,
    LiftNow = 0x0D,
    LiftResult = 0x0E,
}

internal enum AckStatus : byte { Accepted = 0, UnknownOrBadSignature = 1, Replay = 2, Malformed = 3 }
internal enum PresenceStatus : byte { Locked = 0, Unlocked = 1, Off = 2 }
internal enum LiftStatus : byte { Lifted = 0, TooFar = 1, Refused = 2, NotCovered = 3 }
internal enum PairRejectReason : byte { WrongCode = 1, NoCode = 2 }

internal sealed class WireException(string message) : Exception(message);

internal sealed record PairRequest(Guid PhoneID, byte[] Sid, byte[] Ya)
{
    public const int Length = 2 + 16 + 16 + 32;
    public byte[] Encoded() => Bytes.Concat(PairingCrypto.Header(Kind.PairRequest), PairingCrypto.IdBytes(PhoneID), Sid, Ya);

    public static PairRequest Decode(byte[] b)
    {
        PairingCrypto.Check(b, Kind.PairRequest);
        if (b.Length != Length) throw new WireException("wrongLength");
        return new(PairingCrypto.Id(b, 2), b[18..34], b[34..66]);
    }
}

internal sealed record PairResponse(byte[] Sid, byte[] Yb, byte[] Tag)
{
    public const int Length = 2 + 16 + 32 + 64;
    public byte[] Encoded() => Bytes.Concat(PairingCrypto.Header(Kind.PairResponse), Sid, Yb, Tag);

    public static PairResponse Decode(byte[] b)
    {
        PairingCrypto.Check(b, Kind.PairResponse);
        if (b.Length != Length) throw new WireException("wrongLength");
        return new(b[2..18], b[18..50], b[50..114]);
    }
}

internal sealed record PairConfirm(Guid PhoneID, byte[] Sid, byte[] Tag)
{
    public const int Length = 2 + 16 + 16 + 64;
    public byte[] Encoded() => Bytes.Concat(PairingCrypto.Header(Kind.PairConfirm), PairingCrypto.IdBytes(PhoneID), Sid, Tag);

    public static PairConfirm Decode(byte[] b)
    {
        PairingCrypto.Check(b, Kind.PairConfirm);
        if (b.Length != Length) throw new WireException("wrongLength");
        return new(PairingCrypto.Id(b, 2), b[18..34], b[34..98]);
    }
}

internal sealed record CommandEnvelope(Guid PhoneID, ulong Counter, string Command, byte[] Mac)
{
    public static byte[] SignedPart(Guid phoneID, ulong counter, string command)
    {
        var text = Encoding.UTF8.GetBytes(command);
        return Bytes.Concat(PairingCrypto.Header(Kind.Command), PairingCrypto.IdBytes(phoneID), PairingCrypto.BigEndian(counter),
                            [(byte)text.Length], text);
    }

    public byte[] SignedPartBytes => SignedPart(PhoneID, Counter, Command);

    public static CommandEnvelope Decode(byte[] b)
    {
        PairingCrypto.Check(b, Kind.Command);
        if (b.Length < 2 + 16 + 8 + 1 + 32) throw new WireException("wrongLength");
        var len = b[26];
        if (b.Length != 27 + len + 32) throw new WireException("wrongLength");
        string text;
        try { text = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(b, 27, len); }
        catch (DecoderFallbackException) { throw new WireException("badText"); }
        return new(PairingCrypto.Id(b, 2), PairingCrypto.UInt64(b, 18), text, b[(27 + len)..]);
    }
}

internal sealed record Ack(Guid PhoneID, ulong Counter, AckStatus Status, byte[]? Mac)
{
    public static byte[] SignedPart(Guid phoneID, ulong counter, AckStatus status) =>
        Bytes.Concat(PairingCrypto.Header(Kind.Ack), PairingCrypto.IdBytes(phoneID), PairingCrypto.BigEndian(counter), [(byte)status]);

    public static Ack Decode(byte[] b)
    {
        PairingCrypto.Check(b, Kind.Ack);
        if (b.Length != 27 && b.Length != 27 + 32) throw new WireException("wrongLength");
        if (b[26] > 3) throw new WireException("wrongLength");
        return new(PairingCrypto.Id(b, 2), PairingCrypto.UInt64(b, 18), (AckStatus)b[26], b.Length == 59 ? b[27..] : null);
    }
}

/// 手机 → 电脑的签名回答（Presence 或 LiftNow）。签名验过之前里面的东西都不可信
internal sealed record PhoneAnswer(bool IsLiftNow, PresenceStatus Status, Guid PhoneID, ulong Counter, byte[] Nonce, byte[] Mac)
{
    public static byte[] SignedPart(bool liftNow, PresenceStatus status, Guid phoneID, ulong counter, byte[] nonce) =>
        liftNow
            ? Bytes.Concat(PairingCrypto.Header(Kind.LiftNow), PairingCrypto.IdBytes(phoneID), PairingCrypto.BigEndian(counter), nonce)
            : Bytes.Concat(PairingCrypto.Header(Kind.Presence), PairingCrypto.IdBytes(phoneID), PairingCrypto.BigEndian(counter), nonce,
                           [(byte)status]);

    public byte[] SignedPartBytes => SignedPart(IsLiftNow, Status, PhoneID, Counter, Nonce);

    public static PhoneAnswer Decode(byte[] b)
    {
        if (b.Length < 2) throw new WireException("wrongLength");
        if (b[0] != PairingCrypto.Version) throw new WireException("wrongVersion");
        const int head = 2 + 16 + 8 + 16;
        bool liftNow;
        var status = PresenceStatus.Locked;
        byte[] mac;
        switch ((Kind)b[1])
        {
            case Kind.Presence:
                if (b.Length != head + 1 + 32) throw new WireException("wrongLength");
                if (b[head] > 2) throw new WireException("wrongLength");
                liftNow = false;
                status = (PresenceStatus)b[head];
                mac = b[(head + 1)..];
                break;
            case Kind.LiftNow:
                if (b.Length != head + 32) throw new WireException("wrongLength");
                liftNow = true;
                mac = b[head..];
                break;
            default:
                throw new WireException("wrongKind");
        }
        return new(liftNow, status, PairingCrypto.Id(b, 2), PairingCrypto.UInt64(b, 18), b[26..42], mac);
    }
}

/// 握手的结果：确认标签用的 mac_key 和最终的共享钥匙
internal sealed record HandshakeKeys(byte[] MacKey, byte[] SharedKey);

/// 手机这一轮的状态（测试里扮演手机用）
internal sealed record PhoneSession(Guid PhoneID, byte[] Sid, byte[] Secret, byte[] Ya);

/// 电脑这一轮的状态：等手机的 Ta
internal sealed record MacSession(Guid PhoneID, byte[] Sid, byte[] Ya, byte[] MacKey, byte[] SharedKey);

internal enum PhoneStepKind { Confirm, WrongCode, Invalid }
internal sealed record PhoneStep(PhoneStepKind Kind, PairConfirm? Confirm = null, byte[]? SharedKey = null);

internal static class PairingCrypto
{
    /// 握手之后的消息的版本
    public const byte Version = 1;
    /// 握手消息的版本（v2 = CPace）
    public const byte PairingVersion = 2;
    public static readonly byte[] HkdfInfo = "LockCurtain pairing v2"u8.ToArray();
    public const int SidLength = 16;
    public const int NonceLength = 16;
    public const int MaxCommandBytes = 200;

    public static bool IsHandshake(Kind k) =>
        k is Kind.PairRequest or Kind.PairResponse or Kind.PairReject or Kind.PairConfirm or Kind.PairAccepted or Kind.PairAbort;

    public static byte WireVersion(Kind k) => IsHandshake(k) ? PairingVersion : Version;

    /// 消息头：版本 + 类型；不认识或版本不对返回 null
    public static Kind? KindOf(byte[] b)
    {
        if (b.Length < 2 || !Enum.IsDefined(typeof(Kind), b[1])) return null;
        var k = (Kind)b[1];
        return b[0] == WireVersion(k) ? k : null;
    }

    // MARK: - 小工具

    public static byte[] IdBytes(Guid id) => id.ToByteArray(bigEndian: true);
    public static Guid Id(byte[] b, int offset) => new(b.AsSpan(offset, 16), bigEndian: true);
    /// 和 Swift 的 uuidString 一样：大写
    public static string IdString(Guid id) => id.ToString("D").ToUpperInvariant();

    public static byte[] BigEndian(ulong v)
    {
        var o = new byte[8];
        BinaryPrimitives.WriteUInt64BigEndian(o, v);
        return o;
    }

    public static ulong UInt64(byte[] b, int offset) => BinaryPrimitives.ReadUInt64BigEndian(b.AsSpan(offset, 8));

    public static byte[] Header(Kind k) => [WireVersion(k), (byte)k];

    internal static void Check(byte[] b, Kind k)
    {
        if (b.Length < 2) throw new WireException("wrongLength");
        if (b[0] != WireVersion(k)) throw new WireException("wrongVersion");
        if (b[1] != (byte)k) throw new WireException("wrongKind");
    }

    static bool Is(byte[] b, Kind k) => b.Length >= 2 && b[0] == WireVersion(k) && b[1] == (byte)k;

    public static byte[] Hmac(byte[] message, byte[] key) => HMACSHA256.HashData(key, message);

    /// 常数时间比较
    public static bool HmacValid(byte[] mac, byte[] message, byte[] key) =>
        mac.Length == 32 && CryptographicOperations.FixedTimeEquals(mac, Hmac(message, key));

    static bool Eq(byte[] a, byte[] b) => a.AsSpan().SequenceEqual(b);

    // MARK: - 握手

    public static byte[] PairAbort(Guid phoneID, byte[] sid) => Bytes.Concat(Header(Kind.PairAbort), IdBytes(phoneID), sid);

    public static (Guid PhoneID, byte[] Sid)? DecodePairAbort(byte[] b) =>
        Is(b, Kind.PairAbort) && b.Length == 2 + 16 + 16 ? (Id(b, 2), b[18..34]) : null;

    public static byte[] PairAccepted(Guid phoneID, byte[] sid, byte[] key)
    {
        var signed = Bytes.Concat(Header(Kind.PairAccepted), IdBytes(phoneID), sid);
        return Bytes.Concat(signed, Hmac(signed, key));
    }

    public static bool VerifyPairAccepted(byte[] b, Guid phoneID, byte[] sid, byte[] key) =>
        Is(b, Kind.PairAccepted) && b.Length == 2 + 16 + 16 + 32 && Id(b, 2) == phoneID && Eq(b[18..34], sid)
        && HmacValid(b[34..], b[..34], key);

    public static byte[] PairReject(PairRejectReason reason) => [.. Header(Kind.PairReject), (byte)reason];

    public static PairRejectReason? DecodePairReject(byte[] b) =>
        Is(b, Kind.PairReject) && b.Length == 3 && b[2] is 1 or 2 ? (PairRejectReason)b[2] : null;

    /// CPace 的通道标识：手机永远是发起方，电脑永远是应答方（字面上还是 "responder:mac"，和 Mac 同一个协议）
    public static byte[] ChannelID(Guid phoneID) =>
        CPace.LvCat(HkdfInfo, Bytes.Concat("initiator:phone"u8.ToArray(), IdBytes(phoneID)), "responder:mac"u8.ToArray());

    public static byte[] Generator(string code, Guid phoneID, byte[] sid) =>
        CPace.CalculateGenerator(Encoding.UTF8.GetBytes(code), ChannelID(phoneID), sid);

    /// ADa、ADb 都是空：身份已经在 CI 里
    public static readonly byte[] AssociatedData = [];

    public static HandshakeKeys DeriveHandshakeKeys(byte[] sid, byte[] k, byte[] ya, byte[] yb)
    {
        var isk = CPace.Isk(sid, k, ya, AssociatedData, yb, AssociatedData);
        var shared = HKDF.DeriveKey(HashAlgorithmName.SHA256, isk, 32, salt: sid, info: HkdfInfo);
        return new(CPace.MacKey(sid, isk), shared);
    }

    /// 手机：sid 和标量可以指定（测试），否则随机。生成元退化时返回 null
    public static (PairRequest Request, PhoneSession Session)? PhoneStart(string code, Guid phoneID, byte[]? sid = null, byte[]? secret = null)
    {
        sid ??= RandomNumberGenerator.GetBytes(SidLength);
        secret ??= CPace.SampleScalar();
        var ya = CPace.ScalarMult(secret, Generator(code, phoneID, sid));
        if (ya == null) return null;
        return (new PairRequest(phoneID, sid, ya), new PhoneSession(phoneID, sid, secret, ya));
    }

    /// 手机：收到电脑的 Yb 和 Tb
    public static PhoneStep PhoneFinish(PairResponse response, PhoneSession session)
    {
        if (!Eq(response.Sid, session.Sid)) return new(PhoneStepKind.Invalid);
        var k = CPace.ScalarMult(session.Secret, response.Yb);
        if (k == null) return new(PhoneStepKind.Invalid);
        var keys = DeriveHandshakeKeys(session.Sid, k, session.Ya, response.Yb);
        if (!CPace.TagValid(response.Tag, keys.MacKey, response.Yb, AssociatedData)) return new(PhoneStepKind.WrongCode);
        var ta = CPace.Tag(keys.MacKey, session.Ya, AssociatedData);
        return new(PhoneStepKind.Confirm, new PairConfirm(session.PhoneID, session.Sid, ta), keys.SharedKey);
    }

    /// 电脑：用自己的码算 g、Yb、K，回 Yb 和 Tb。Ya 不合法返回 null。secret 只给测试指定
    public static (PairResponse Response, MacSession Session)? MacRespond(PairRequest request, string code, byte[]? secret = null)
    {
        secret ??= CPace.SampleScalar();
        var g = Generator(code, request.PhoneID, request.Sid);
        var yb = CPace.ScalarMult(secret, g);
        var k = CPace.ScalarMult(secret, request.Ya);
        if (yb == null || k == null) return null;
        var keys = DeriveHandshakeKeys(request.Sid, k, request.Ya, yb);
        var tb = CPace.Tag(keys.MacKey, yb, AssociatedData);
        return (new PairResponse(request.Sid, yb, tb),
                new MacSession(request.PhoneID, request.Sid, request.Ya, keys.MacKey, keys.SharedKey));
    }

    /// 电脑：核对手机的 Ta（常数时间）
    public static bool MacCheckConfirm(PairConfirm confirm, MacSession session) =>
        confirm.PhoneID == session.PhoneID && Eq(confirm.Sid, session.Sid)
        && CPace.TagValid(confirm.Tag, session.MacKey, session.Ya, AssociatedData);

    // MARK: - 命令

    public static byte[]? SealCommand(string command, Guid phoneID, ulong counter, byte[] key)
    {
        if (Encoding.UTF8.GetByteCount(command) > MaxCommandBytes) return null;
        var signed = CommandEnvelope.SignedPart(phoneID, counter, command);
        return Bytes.Concat(signed, Hmac(signed, key));
    }

    public static bool VerifyCommand(CommandEnvelope e, byte[] key) => HmacValid(e.Mac, e.SignedPartBytes, key);

    public static byte[] MakeAck(Guid phoneID, ulong counter, AckStatus status, byte[]? key)
    {
        var signed = Ack.SignedPart(phoneID, counter, status);
        return status != AckStatus.Accepted || key == null ? signed : Bytes.Concat(signed, Hmac(signed, key));
    }

    public static bool VerifyAck(Ack ack, byte[] key) =>
        ack.Status == AckStatus.Accepted && ack.Mac != null && HmacValid(ack.Mac, Ack.SignedPart(ack.PhoneID, ack.Counter, ack.Status), key);

    // MARK: - 幕布状态 / 撤销

    public static byte[] MakeState(bool closed, ulong seq, Guid phoneID, byte[] key)
    {
        var signed = Bytes.Concat(Header(Kind.State), IdBytes(phoneID), BigEndian(seq), [(byte)(closed ? 1 : 0)]);
        return Bytes.Concat(signed, Hmac(signed, key));
    }

    public static (ulong Seq, bool Closed)? OpenState(byte[] b, Guid phoneID, byte[] key) =>
        Is(b, Kind.State) && b.Length == 2 + 16 + 8 + 1 + 32 && Id(b, 2) == phoneID && HmacValid(b[27..], b[..27], key)
            ? (UInt64(b, 18), b[26] == 1) : null;

    public static byte[] MakeRevoke(Guid phoneID, byte[] key)
    {
        var signed = Bytes.Concat(Header(Kind.Revoke), IdBytes(phoneID));
        return Bytes.Concat(signed, Hmac(signed, key));
    }

    public static bool VerifyRevoke(byte[] b, Guid phoneID, byte[] key) =>
        Is(b, Kind.Revoke) && b.Length == 2 + 16 + 32 && Id(b, 2) == phoneID && HmacValid(b[18..], b[..18], key);

    // MARK: - 手机撤下幕布

    public static byte[] MakeNonce() => RandomNumberGenerator.GetBytes(NonceLength);

    public static byte[]? MakePoll(byte[] nonce, Guid phoneID, byte[] key)
    {
        if (nonce.Length != NonceLength) return null;
        var signed = Bytes.Concat(Header(Kind.Poll), IdBytes(phoneID), nonce);
        return Bytes.Concat(signed, Hmac(signed, key));
    }

    public static byte[]? OpenPoll(byte[] b, Guid phoneID, byte[] key) =>
        Is(b, Kind.Poll) && b.Length == 2 + 16 + 16 + 32 && Id(b, 2) == phoneID && HmacValid(b[34..], b[..34], key)
            ? b[18..34] : null;

    public static byte[]? SealPresence(PresenceStatus status, byte[] nonce, Guid phoneID, ulong counter, byte[] key)
    {
        if (nonce.Length != NonceLength) return null;
        var signed = PhoneAnswer.SignedPart(false, status, phoneID, counter, nonce);
        return Bytes.Concat(signed, Hmac(signed, key));
    }

    public static byte[]? SealLiftNow(byte[] nonce, Guid phoneID, ulong counter, byte[] key)
    {
        if (nonce.Length != NonceLength) return null;
        var signed = PhoneAnswer.SignedPart(true, PresenceStatus.Locked, phoneID, counter, nonce);
        return Bytes.Concat(signed, Hmac(signed, key));
    }

    public static bool VerifyAnswer(PhoneAnswer a, byte[] key) => HmacValid(a.Mac, a.SignedPartBytes, key);

    public static byte[] MakeLiftResult(LiftStatus status, ulong counter, Guid phoneID, byte[] key)
    {
        var signed = Bytes.Concat(Header(Kind.LiftResult), IdBytes(phoneID), BigEndian(counter), [(byte)status]);
        return Bytes.Concat(signed, Hmac(signed, key));
    }

    public static (ulong Counter, LiftStatus Status)? OpenLiftResult(byte[] b, Guid phoneID, byte[] key) =>
        Is(b, Kind.LiftResult) && b.Length == 2 + 16 + 8 + 1 + 32 && Id(b, 2) == phoneID && b[26] <= 3
        && HmacValid(b[27..], b[..27], key)
            ? (UInt64(b, 18), (LiftStatus)b[26]) : null;
}

/// 分帧：任何一条消息按传输层的单包上限切块，每块前面 1 字节头：bit7 = 最后一块，低 7 位 = 块序号（模 128）
internal static class PairingFraming
{
    public const int MaxMessage = 1024;

    public static List<byte[]> Chunks(byte[] message, int maxChunk)
    {
        var room = Math.Max(1, maxChunk - 1);
        var o = new List<byte[]>();
        var index = 0;
        var start = 0;
        do
        {
            var end = Math.Min(message.Length, start + room);
            var last = end == message.Length;
            o.Add([(byte)((index & 0x7F) | (last ? 0x80 : 0)), .. message[start..end]]);
            index++;
            start = end;
        } while (start < message.Length);
        return o;
    }

    /// 收块拼消息：顺序错了就整条丢掉重来
    internal sealed class Assembler
    {
        readonly List<byte> buffer = new();
        byte expected;

        public void Reset()
        {
            buffer.Clear();
            expected = 0;
        }

        /// 拼完一条就返回它
        public byte[]? Feed(byte[] chunk)
        {
            if (chunk.Length == 0) return null;
            var head = chunk[0];
            var index = (byte)(head & 0x7F);
            if (index == 0) Reset();
            if (index != expected) { Reset(); return null; }
            buffer.AddRange(chunk.AsSpan(1).ToArray());
            if (buffer.Count > MaxMessage) { Reset(); return null; }
            expected = (byte)((expected + 1) & 0x7F);
            if ((head & 0x80) == 0) return null;
            var message = buffer.ToArray();
            Reset();
            return message;
        }
    }
}
