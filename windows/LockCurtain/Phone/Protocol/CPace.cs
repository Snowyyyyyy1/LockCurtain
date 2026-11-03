// CPace.cs —— CPace（draft-irtf-cfrg-cpace，X25519 + SHA-512）的底层部件，逐行对照 Mac 的 Sources/CPace.swift
//
// 这个文件夹（Phone/Protocol）只放和平台无关的纯函数 / 纯逻辑：主程序和 Tests/PhoneSelfTest（plain net10.0，Mac 上能跑）共用。
//   * Field25519：模 2^255−19 的有限域（16 个 16 位分量，TweetNaCl 的写法），只做 Elligator2 要用的运算。
//     分支只看公开的东西（循环下标、固定指数），选择用掩码。
//   * Elligator2：RFC 9380 的 map_to_curve_elligator2（Z = 2），只要 u 坐标。
//   * ScalarMult：X25519 用 BouncyCastle 的 Rfc7748.X25519（经过审计的实现），结果全零（低阶点）当失败。
//   * Isk / MacKey / Tag：草案 §7.2 的 ISK 和 §10.4 的确认标签。
// 和 Swift 逐字节一致由 Tests/PhoneVectors/vectors.json（Swift 算的）核对。

using System.Security.Cryptography;
using BcX25519 = Org.BouncyCastle.Math.EC.Rfc7748.X25519;

namespace LockCurtain.Phone;

internal readonly struct Field25519
{
    /// 16 个分量，第 i 个表示 2^(16i) 的系数；中间结果允许暂时超出 16 位，编码时才规范化
    readonly long[] limbs;

    Field25519(long[] limbs) => this.limbs = limbs;

    public static Field25519 Small(long v)
    {
        var o = new long[16];
        o[0] = v;
        return new Field25519(o);
    }

    /// RFC 7748 decodeUCoordinate：32 字节小端，忽略最高位（不要求 < p）
    public static Field25519 FromBytes(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length != 32) throw new ArgumentException("需要 32 字节", nameof(bytes));
        var o = new long[16];
        for (var i = 0; i < 16; i++) o[i] = bytes[2 * i] | ((long)bytes[2 * i + 1] << 8);
        o[15] &= 0x7FFF;
        return new Field25519(o);
    }

    public static readonly Field25519 Zero = Small(0);
    public static readonly Field25519 One = Small(1);
    /// 曲线参数 A = 486662
    public static readonly Field25519 CurveA = FromBytes([0x06, 0x6D, 0x07, .. new byte[29]]);

    static void Carry(long[] o)
    {
        unchecked
        {
            for (var i = 0; i < 16; i++)
            {
                o[i] += 1L << 16;
                var c = o[i] >> 16;
                if (i < 15) o[i + 1] += c - 1;
                else o[0] += 38 * (c - 1);   // 2^256 ≡ 38 (mod p)
                o[i] -= c << 16;
            }
        }
    }

    /// b = 1 时交换 p、q，b = 0 时不动；不分支
    static void ConditionalSwap(long[] p, long[] q, long b)
    {
        unchecked
        {
            var mask = ~(b - 1);
            for (var i = 0; i < 16; i++)
            {
                var t = mask & (p[i] ^ q[i]);
                p[i] ^= t;
                q[i] ^= t;
            }
        }
    }

    /// flag = true 选 b，否则选 a（掩码选择，不分支）
    public static Field25519 Select(Field25519 a, Field25519 b, bool flag)
    {
        var x = (long[])a.limbs.Clone();
        var y = (long[])b.limbs.Clone();
        ConditionalSwap(x, y, flag ? 1 : 0);
        return new Field25519(x);
    }

    public static Field25519 operator +(Field25519 a, Field25519 b)
    {
        var o = (long[])a.limbs.Clone();
        unchecked { for (var i = 0; i < 16; i++) o[i] += b.limbs[i]; }
        return new Field25519(o);
    }

    public static Field25519 operator -(Field25519 a, Field25519 b)
    {
        var o = (long[])a.limbs.Clone();
        unchecked { for (var i = 0; i < 16; i++) o[i] -= b.limbs[i]; }
        return new Field25519(o);
    }

    public static Field25519 operator *(Field25519 a, Field25519 b)
    {
        var t = new long[31];
        unchecked
        {
            for (var i = 0; i < 16; i++)
            {
                var ai = a.limbs[i];
                for (var j = 0; j < 16; j++) t[i + j] += ai * b.limbs[j];
            }
            for (var i = 0; i < 15; i++) t[i] += 38 * t[i + 16];
        }
        var o = t[..16];
        Carry(o);
        Carry(o);
        return new Field25519(o);
    }

    /// x^e，e 是公开的常数（小端字节），按位平方-乘；只在公开指数位上分支
    public Field25519 Power(byte[] exponent)
    {
        var c = One;
        for (var bit = exponent.Length * 8 - 1; bit >= 0; bit--)
        {
            c = c * c;
            if (((exponent[bit / 8] >> (bit % 8)) & 1) == 1) c = c * this;
        }
        return c;
    }

    /// p − 2 = 2^255 − 21：费马求逆（0 的「逆」是 0，和 RFC 9380 的 inv0 一致）
    public static readonly byte[] PMinus2 = [0xEB, .. Enumerable.Repeat((byte)0xFF, 30), 0x7F];
    /// (p − 1) / 2 = 2^254 − 10：勒让德符号
    public static readonly byte[] HalfPMinus1 = [0xF6, .. Enumerable.Repeat((byte)0xFF, 30), 0x3F];

    public Field25519 Inverse => Power(PMinus2);

    /// 规范编码：完全约化到 [0, p)，32 字节小端
    public byte[] ToBytes()
    {
        var t = (long[])limbs.Clone();
        Carry(t);
        Carry(t);
        Carry(t);
        var m = new long[16];
        unchecked
        {
            for (var round = 0; round < 2; round++)
            {
                m[0] = t[0] - 0xFFED;
                for (var i = 1; i < 15; i++)
                {
                    m[i] = t[i] - 0xFFFF - ((m[i - 1] >> 16) & 1);
                    m[i - 1] &= 0xFFFF;
                }
                m[15] = t[15] - 0x7FFF - ((m[14] >> 16) & 1);
                var borrow = (m[15] >> 16) & 1;
                m[14] &= 0xFFFF;
                ConditionalSwap(t, m, 1 - borrow);
            }
            var o = new byte[32];
            for (var i = 0; i < 16; i++)
            {
                o[2 * i] = (byte)t[i];
                o[2 * i + 1] = (byte)(t[i] >> 8);
            }
            return o;
        }
    }

    /// 常数时间比较（比规范编码）
    public static bool Equal(Field25519 a, Field25519 b) =>
        CryptographicOperations.FixedTimeEquals(a.ToBytes(), b.ToBytes());
}

internal static class CPace
{
    /// G_X25519.DSI
    public static readonly byte[] Dsi = "CPace255"u8.ToArray();
    /// SHA-512 的输入块大小 H.s_in_bytes
    public const int HashBlockBytes = 128;

    // MARK: 串工具（草案附录 A.1）

    /// LEB128 长度前缀
    public static byte[] PrependLen(ReadOnlySpan<byte> data)
    {
        var length = data.Length;
        var o = new List<byte>(data.Length + 3);
        do
        {
            var low = (byte)(length & 0x7F);
            length >>= 7;
            o.Add(length == 0 ? low : (byte)(low | 0x80));
        } while (length != 0);
        o.AddRange(data.ToArray());
        return o.ToArray();
    }

    public static byte[] LvCat(params byte[][] parts) => Bytes.Concat(parts.Select(p => PrependLen(p)).ToArray());

    /// 草案附录 A.2
    public static byte[] GeneratorString(byte[] prs, byte[] ci, byte[] sid)
    {
        var zpad = Math.Max(0, HashBlockBytes - 1 - PrependLen(prs).Length - PrependLen(Dsi).Length);
        return LvCat(Dsi, prs, new byte[zpad], ci, sid);
    }

    // MARK: Elligator2

    /// RFC 9380 map_to_curve_elligator2，Curve25519（A = 486662，B = 1，Z = 2），只返回 u 坐标
    public static byte[] Elligator2(ReadOnlySpan<byte> input)
    {
        var r = Field25519.FromBytes(input);
        var a = Field25519.CurveA;
        var denominator = Field25519.One + Field25519.Small(2) * (r * r);   // 1 + Z·r²，永远不为 0
        var v = (Field25519.Zero - a) * denominator.Inverse;                 // v = −A / (1 + Z·r²)
        var gv = v * (v * v + a * v + Field25519.One);                       // v³ + A·v² + v
        var legendre = gv.Power(Field25519.HalfPMinus1);
        var isSquare = Field25519.Equal(legendre, Field25519.One);
        var other = Field25519.Zero - v - a;                                 // 不是平方数：u = −v − A
        return Field25519.Select(other, v, isSquare).ToBytes();
    }

    /// 草案 §8.2：g = elligator2(decodeUCoordinate(SHA-512(generator_string)[0..<32]))
    public static byte[] CalculateGenerator(byte[] prs, byte[] ci, byte[] sid) =>
        Elligator2(SHA512.HashData(GeneratorString(prs, ci, sid)).AsSpan(0, 32));

    // MARK: 群运算

    /// 随机标量（32 个随机字节，X25519 自己做 clamp）
    public static byte[] SampleScalar() => RandomNumberGenerator.GetBytes(32);

    /// G.scalar_mult_vfy(y, g) = X25519(y, g)；结果是全零（低阶点 / 非法输入）返回 null
    public static byte[]? ScalarMult(byte[] scalar, byte[] point)
    {
        if (scalar.Length != 32 || point.Length != 32) return null;
        var o = new byte[32];
        BcX25519.ScalarMult(scalar, 0, point, 0, o, 0);
        var acc = 0;
        foreach (var b in o) acc |= b;
        return acc != 0 ? o : null;
    }

    // MARK: ISK 和确认

    /// 草案 §7.2，发起方-应答方：ISK = SHA-512(lv_cat(DSI‖"_ISK", sid, K) ‖ lv_cat(Ya, ADa) ‖ lv_cat(Yb, ADb))
    public static byte[] Isk(byte[] sid, byte[] k, byte[] ya, byte[] ada, byte[] yb, byte[] adb) =>
        SHA512.HashData(Bytes.Concat(LvCat(Bytes.Concat(Dsi, "_ISK"u8.ToArray()), sid, k), LvCat(ya, ada), LvCat(yb, adb)));

    /// 草案 §10.4：mac_key = SHA-512("CPaceMac" ‖ sid ‖ ISK)
    public static byte[] MacKey(byte[] sid, byte[] isk) => SHA512.HashData(Bytes.Concat("CPaceMac"u8.ToArray(), sid, isk));

    /// 草案 §10.4：T = HMAC-SHA-512(mac_key, lv_cat(Y, AD))
    public static byte[] Tag(byte[] macKey, byte[] y, byte[] ad) => HMACSHA512.HashData(macKey, LvCat(y, ad));

    /// 常数时间核对对方的标签
    public static bool TagValid(byte[] tag, byte[] macKey, byte[] y, byte[] ad) =>
        tag.Length == 64 && CryptographicOperations.FixedTimeEquals(tag, Tag(macKey, y, ad));
}

internal static class Bytes
{
    public static byte[] Concat(params byte[][] parts)
    {
        var o = new byte[parts.Sum(p => p.Length)];
        var at = 0;
        foreach (var p in parts)
        {
            p.CopyTo(o, at);
            at += p.Length;
        }
        return o;
    }

    public static string Hex(ReadOnlySpan<byte> b) => Convert.ToHexString(b).ToLowerInvariant();
}
