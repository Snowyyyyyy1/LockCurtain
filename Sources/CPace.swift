// CPace.swift —— CPace（draft-irtf-cfrg-cpace，X25519 + SHA-512）的底层部件，Mac 和 iPhone 共用
//
// 只放和协议规范一一对应的纯函数：
//   * Field25519：模 2^255−19 的有限域运算（16 个 16 位分量，TweetNaCl 的写法），
//     只做 Elligator2 要用的加、减、乘、按公开指数求幂、常数时间选择、规范编码。
//     所有分支只看公开的东西（循环下标、固定指数），和码相关的值走固定步骤，选择用掩码。
//   * elligator2：RFC 9380 的 map_to_curve_elligator2（Z = 2），只要 u 坐标。
//   * calculateGenerator：generator_string → SHA-512 取前 32 字节 → decodeUCoordinate → elligator2。
//   * scalarMult：用 CryptoKit 的 X25519 算 y·g，结果是全零（单位元 / 低阶点）就当失败。
//   * isk / macKey / tag：草案 §7.2 的 ISK（发起方-应答方的 transcript_ir）和 §10.4 的确认标签。
//
// 测试向量（草案附录 B.1）在 PairingSelfTest 里核对。

import CryptoKit
import Foundation

// MARK: - 有限域 GF(2^255 − 19)

struct Field25519 {
    /// 16 个分量，第 i 个表示 2^(16i) 的系数；运算中间允许暂时超出 16 位，编码时才规范化
    var limbs: [Int64]

    init() { limbs = [Int64](repeating: 0, count: 16) }

    init(_ small: Int64) {
        self.init()
        limbs[0] = small
    }

    /// RFC 7748 decodeUCoordinate：32 字节小端，忽略最高位（不要求 < p）
    init(bytes: [UInt8]) {
        precondition(bytes.count == 32)
        self.init()
        for i in 0..<16 {
            limbs[i] = Int64(bytes[2 * i]) | (Int64(bytes[2 * i + 1]) << 8)
        }
        limbs[15] &= 0x7FFF
    }

    private init(limbs: [Int64]) { self.limbs = limbs }

    static let zero = Field25519(0)
    static let one = Field25519(1)
    /// 曲线参数 A = 486662
    static let curveA = Field25519(bytes: [0x06, 0x6D, 0x07] + [UInt8](repeating: 0, count: 29))

    private static func carry(_ o: inout [Int64]) {
        for i in 0..<16 {
            o[i] &+= 1 &<< 16
            let c = o[i] >> 16
            if i < 15 {
                o[i + 1] &+= c &- 1
            } else {
                o[0] &+= 38 &* (c &- 1)   // 2^256 ≡ 38 (mod p)
            }
            o[i] &-= c &<< 16
        }
    }

    /// b = 1 时交换 p、q，b = 0 时不动；不分支
    private static func conditionalSwap(_ p: inout [Int64], _ q: inout [Int64], _ b: Int64) {
        let mask = ~(b &- 1)
        for i in 0..<16 {
            let t = mask & (p[i] ^ q[i])
            p[i] ^= t
            q[i] ^= t
        }
    }

    /// flag = true 选 b，否则选 a（掩码选择，不分支）
    static func select(_ a: Field25519, _ b: Field25519, _ flag: Bool) -> Field25519 {
        var x = a.limbs
        var y = b.limbs
        conditionalSwap(&x, &y, flag ? 1 : 0)
        return Field25519(limbs: x)
    }

    static func + (a: Field25519, b: Field25519) -> Field25519 {
        var o = a.limbs
        for i in 0..<16 { o[i] &+= b.limbs[i] }
        return Field25519(limbs: o)
    }

    static func - (a: Field25519, b: Field25519) -> Field25519 {
        var o = a.limbs
        for i in 0..<16 { o[i] &-= b.limbs[i] }
        return Field25519(limbs: o)
    }

    static func * (a: Field25519, b: Field25519) -> Field25519 {
        var t = [Int64](repeating: 0, count: 31)
        for i in 0..<16 {
            let ai = a.limbs[i]
            for j in 0..<16 { t[i + j] &+= ai &* b.limbs[j] }
        }
        for i in 0..<15 { t[i] &+= 38 &* t[i + 16] }
        var o = Array(t[0..<16])
        carry(&o)
        carry(&o)
        return Field25519(limbs: o)
    }

    /// x^e，e 是公开的常数（小端字节），按位平方-乘；只在公开指数位上分支
    func power(_ exponent: [UInt8]) -> Field25519 {
        var c = Field25519.one
        for bit in stride(from: exponent.count * 8 - 1, through: 0, by: -1) {
            c = c * c
            if (exponent[bit / 8] >> (bit % 8)) & 1 == 1 { c = c * self }
        }
        return c
    }

    /// p − 2 = 2^255 − 21：费马求逆（0 的「逆」是 0，和 RFC 9380 的 inv0 一致）
    static let pMinus2: [UInt8] = [0xEB] + [UInt8](repeating: 0xFF, count: 30) + [0x7F]
    /// (p − 1) / 2 = 2^254 − 10：勒让德符号
    static let halfPMinus1: [UInt8] = [0xF6] + [UInt8](repeating: 0xFF, count: 30) + [0x3F]

    var inverse: Field25519 { power(Self.pMinus2) }

    /// 规范编码：完全约化到 [0, p)，32 字节小端
    var bytes: [UInt8] {
        var t = limbs
        Self.carry(&t)
        Self.carry(&t)
        Self.carry(&t)
        var m = [Int64](repeating: 0, count: 16)
        for _ in 0..<2 {
            m[0] = t[0] &- 0xFFED
            for i in 1..<15 {
                m[i] = t[i] &- 0xFFFF &- ((m[i - 1] >> 16) & 1)
                m[i - 1] &= 0xFFFF
            }
            m[15] = t[15] &- 0x7FFF &- ((m[14] >> 16) & 1)
            let borrow = (m[15] >> 16) & 1
            m[14] &= 0xFFFF
            Self.conditionalSwap(&t, &m, 1 &- borrow)
        }
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<16 {
            out[2 * i] = UInt8(truncatingIfNeeded: t[i])
            out[2 * i + 1] = UInt8(truncatingIfNeeded: t[i] >> 8)
        }
        return out
    }

    /// 常数时间比较（比规范编码）
    static func equal(_ a: Field25519, _ b: Field25519) -> Bool {
        var diff: UInt8 = 0
        for (x, y) in zip(a.bytes, b.bytes) { diff |= x ^ y }
        return diff == 0
    }
}

// MARK: - CPace

enum CPace {
    /// G_X25519.DSI
    static let dsi = Data("CPace255".utf8)
    /// SHA-512 的输入块大小 H.s_in_bytes
    static let hashBlockBytes = 128

    // MARK: 串工具（草案附录 A.1）

    /// LEB128 长度前缀
    static func prependLen(_ data: Data) -> Data {
        var length = data.count
        var out = Data()
        repeat {
            let low = UInt8(length & 0x7F)
            length >>= 7
            out.append(length == 0 ? low : low | 0x80)
        } while length != 0
        return out + data
    }

    static func lvCat(_ parts: Data...) -> Data { lvCat(parts) }

    static func lvCat(_ parts: [Data]) -> Data {
        parts.reduce(Data()) { $0 + prependLen($1) }
    }

    /// 草案附录 A.2
    static func generatorString(prs: Data, ci: Data, sid: Data) -> Data {
        let zpad = max(0, hashBlockBytes - 1 - prependLen(prs).count - prependLen(dsi).count)
        return lvCat(dsi, prs, Data(count: zpad), ci, sid)
    }

    // MARK: Elligator2

    /// RFC 9380 map_to_curve_elligator2，Curve25519（A = 486662，B = 1，Z = 2），只返回 u 坐标。
    /// 输入是 32 字节，按 decodeUCoordinate 读（去掉最高位）；输出是规范的 32 字节小端 u。
    static func elligator2(_ input: [UInt8]) -> Data {
        let r = Field25519(bytes: input)
        let a = Field25519.curveA
        let denominator = Field25519.one + Field25519(2) * (r * r)   // 1 + Z·r²，Z = 2 不是平方数，永远不为 0
        let v = (Field25519.zero - a) * denominator.inverse           // v = −A / (1 + Z·r²)
        let gv = v * (v * v + a * v + Field25519.one)                 // v³ + A·v² + v
        let legendre = gv.power(Field25519.halfPMinus1)
        let isSquare = Field25519.equal(legendre, .one)
        // 是平方数：u = v；否则 u = −v − A
        let other = Field25519.zero - v - a
        let u = Field25519.select(other, v, isSquare)
        return Data(u.bytes)
    }

    /// 草案 §8.2：g = elligator2(decodeUCoordinate(SHA-512(generator_string)[0..<32]))
    static func calculateGenerator(prs: Data, ci: Data, sid: Data) -> Data {
        let hash = [UInt8](SHA512.hash(data: generatorString(prs: prs, ci: ci, sid: sid)))
        return elligator2(Array(hash[0..<32]))
    }

    // MARK: 群运算

    /// 随机标量（G.sample_scalar）：CryptoKit 生成 32 个随机字节，X25519 自己做 clamp
    static func sampleScalar() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    /// G.scalar_mult_vfy(y, g) = X25519(y, g)；结果是单位元（全零，含低阶点 / 非法输入）返回 nil
    static func scalarMult(_ scalar: Curve25519.KeyAgreement.PrivateKey, _ point: Data) -> Data? {
        guard point.count == 32,
              let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: point),
              let shared = try? scalar.sharedSecretFromKeyAgreement(with: pub) else { return nil }
        let out = shared.withUnsafeBytes { Data($0) }
        let zero = out.reduce(UInt8(0)) { $0 | $1 }
        return out.count == 32 && zero != 0 ? out : nil
    }

    // MARK: ISK 和确认

    /// 草案 §7.2，发起方-应答方：ISK = SHA-512(lv_cat(DSI‖"_ISK", sid, K) ‖ lv_cat(Ya, ADa) ‖ lv_cat(Yb, ADb))
    static func isk(sid: Data, k: Data, ya: Data, ada: Data, yb: Data, adb: Data) -> Data {
        let input = lvCat(dsi + Data("_ISK".utf8), sid, k) + lvCat(ya, ada) + lvCat(yb, adb)
        return Data(SHA512.hash(data: input))
    }

    /// 草案 §10.4：mac_key = SHA-512("CPaceMac" ‖ sid ‖ ISK)
    static func macKey(sid: Data, isk: Data) -> SymmetricKey {
        SymmetricKey(data: Data(SHA512.hash(data: Data("CPaceMac".utf8) + sid + isk)))
    }

    /// 草案 §10.4：每方对自己发过的消息算标签 T = HMAC-SHA-512(mac_key, lv_cat(Y, AD))
    static func tag(_ key: SymmetricKey, y: Data, ad: Data) -> Data {
        Data(HMAC<SHA512>.authenticationCode(for: lvCat(y, ad), using: key))
    }

    /// 常数时间核对对方的标签
    static func tagValid(_ tag: Data, key: SymmetricKey, y: Data, ad: Data) -> Bool {
        tag.count == 64 && HMAC<SHA512>.isValidAuthenticationCode(tag, authenticating: lvCat(y, ad), using: key)
    }
}
