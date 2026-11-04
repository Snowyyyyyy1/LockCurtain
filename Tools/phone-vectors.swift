// phone-vectors.swift —— 从 Mac 的实现（Sources/CPace.swift、PairingCrypto.swift、LiftGate.swift、PairingAuthority.swift）
// 算出确定的测试向量，写成 JSON，给 Windows 版的 C# 实现逐字节核对（windows/Tests/PhoneSelfTest）。
//
// 运行（windows/Tests/PhoneVectors/generate.sh 就是这几行）：
//   mkdir -p /tmp/pv && cp Tools/phone-vectors.swift /tmp/pv/main.swift
//   xcrun swiftc -o /tmp/pv/gen /tmp/pv/main.swift Sources/CPace.swift Sources/PairingCrypto.swift \
//       Sources/LiftGate.swift Sources/PairingAuthority.swift
//   /tmp/pv/gen > windows/Tests/PhoneVectors/vectors.json
//
// 所有随机量（标量、sid、nonce、钥匙、phoneID）都是固定值，所以输出是确定的；
// LiftGate / PairingAuthority 的场景由 Swift 实现实际跑一遍，记下它给的结果当期望值。

import CryptoKit
import Foundation

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func unhex(_ s: String) -> Data {
    var out = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}
func fill(_ n: Int, _ seed: UInt8) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: Int(seed) &* 31 &+ $0 &* 7) }) }
func scalar(_ d: Data) -> Curve25519.KeyAgreement.PrivateKey { try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d) }
func keyHex(_ k: SymmetricKey) -> String { k.withUnsafeBytes { hex(Data($0)) } }

var root: [String: Any] = [:]
root["generator"] = "Tools/phone-vectors.swift (Swift CryptoKit reference)"

// MARK: - CPace 草案向量（Swift 重新算一遍）
do {
    let prs = Data("Password".utf8)
    let ci = unhex("0b415f696e69746961746f720b425f726573706f6e646572")
    let sid = unhex("7e4b4791d6a8ef019b936c79fb7f2c57")
    let g = CPace.calculateGenerator(prs: prs, ci: ci, sid: sid)
    let ya = unhex("21b4f4bd9e64ed355c3eb676a28ebedaf6d8f17bdc365995b319097153044080")
    let yb = unhex("848b0779ff415f0af4ea14df9dd1d3c29ac41d836c7808896c4eba19c51ac40a")
    let bigYa = CPace.scalarMult(scalar(ya), g)!
    let bigYb = CPace.scalarMult(scalar(yb), g)!
    let k = CPace.scalarMult(scalar(ya), bigYb)!
    let isk = CPace.isk(sid: sid, k: k, ya: bigYa, ada: Data("ADa".utf8), yb: bigYb, adb: Data("ADb".utf8))
    root["cpaceDraft"] = [
        "prs": hex(prs), "ci": hex(ci), "sid": hex(sid),
        "generatorString": hex(CPace.generatorString(prs: prs, ci: ci, sid: sid)),
        "g": hex(g), "ya": hex(ya), "yb": hex(yb), "Ya": hex(bigYa), "Yb": hex(bigYb), "K": hex(k),
        "ada": hex(Data("ADa".utf8)), "adb": hex(Data("ADb".utf8)), "isk": hex(isk),
    ]
}

// Elligator2：一组固定输入 + 一些伪随机输入
do {
    var inputs = [
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0100000000000000000000000000000000000000000000000000000000000000",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    ].map(unhex)
    var h = Data("LockCurtain elligator seed".utf8)
    for _ in 0..<40 {
        h = Data(SHA512.hash(data: h))
        inputs.append(h.prefix(32))
    }
    root["elligator2"] = inputs.map { ["in": hex($0), "out": hex(CPace.elligator2([UInt8]($0)))] }
}

// 低阶点 / 非法点：scalarMult 的结果（nil = 中止）
do {
    let s = scalar(unhex("af46e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449aff"))
    let us = [
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0100000000000000000000000000000000000000000000000000000000000000",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
        "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
        "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "daffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "dbffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "d9ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "cdeb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b880",
        "4c9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f11d7",
    ]
    root["scalarMult"] = [
        "scalar": "af46e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449aff",
        "cases": us.map { u -> [String: Any] in
            ["u": u, "out": CPace.scalarMult(s, unhex(u)).map(hex) ?? NSNull()]
        },
    ]
}

// MARK: - 配对握手（固定标量）

func handshakeVector(name: String, phoneCode: String, macCode: String, phoneID: UUID, sid: Data, ya: Data, yb: Data) -> [String: Any] {
    let gPhone = PairingCrypto.generator(code: phoneCode, phoneID: phoneID, sid: sid)
    let gMac = PairingCrypto.generator(code: macCode, phoneID: phoneID, sid: sid)
    let bigYa = CPace.scalarMult(scalar(ya), gPhone)!
    let request = PairingCrypto.PairRequest(phoneID: phoneID, sid: sid, ya: bigYa)
    // Mac 这一边（macRespond 的步骤，标量固定）
    let bigYb = CPace.scalarMult(scalar(yb), gMac)!
    let kMac = CPace.scalarMult(scalar(yb), bigYa)!
    let macKeys = PairingCrypto.handshakeKeys(sid: sid, k: kMac, ya: bigYa, yb: bigYb)
    let tb = CPace.tag(macKeys.macKey, y: bigYb, ad: Data())
    let response = PairingCrypto.PairResponse(sid: sid, yb: bigYb, tag: tb)
    // 手机这一边（phoneFinish 的步骤）
    let kPhone = CPace.scalarMult(scalar(ya), bigYb)!
    let phoneKeys = PairingCrypto.handshakeKeys(sid: sid, k: kPhone, ya: bigYa, yb: bigYb)
    let tbOK = CPace.tagValid(tb, key: phoneKeys.macKey, y: bigYb, ad: Data())
    let ta = CPace.tag(phoneKeys.macKey, y: bigYa, ad: Data())
    let confirm = PairingCrypto.PairConfirm(phoneID: phoneID, sid: sid, tag: ta)
    let taOK = CPace.tagValid(ta, key: macKeys.macKey, y: bigYa, ad: Data())
    var v: [String: Any] = [
        "name": name, "phoneCode": phoneCode, "macCode": macCode,
        "phoneID": phoneID.uuidString, "phoneIDBytes": hex(PairingCrypto.bytes(phoneID)),
        "sid": hex(sid), "ya": hex(ya), "yb": hex(yb),
        "channelID": hex(PairingCrypto.channelID(phoneID: phoneID)),
        "generatorString": hex(CPace.generatorString(prs: Data(phoneCode.utf8), ci: PairingCrypto.channelID(phoneID: phoneID), sid: sid)),
        "gPhone": hex(gPhone), "gMac": hex(gMac),
        "Ya": hex(bigYa), "Yb": hex(bigYb), "Kphone": hex(kPhone), "Kmac": hex(kMac),
        "isk": hex(CPace.isk(sid: sid, k: kMac, ya: bigYa, ada: Data(), yb: bigYb, adb: Data())),
        "macMacKey": keyHex(macKeys.macKey), "macSharedKey": keyHex(macKeys.sharedKey),
        "phoneMacKey": keyHex(phoneKeys.macKey), "phoneSharedKey": keyHex(phoneKeys.sharedKey),
        "tb": hex(tb), "ta": hex(ta), "phoneAcceptsTb": tbOK, "macAcceptsTa": taOK,
        "pairRequest": hex(request.encoded()),
        "pairResponse": hex(response.encoded()),
        "pairConfirm": hex(confirm.encoded()),
        "pairAbort": hex(PairingCrypto.pairAbort(phoneID: phoneID, sid: sid)),
    ]
    if tbOK && taOK {
        v["pairAccepted"] = hex(PairingCrypto.pairAccepted(phoneID: phoneID, sid: sid, key: macKeys.sharedKey))
    }
    return v
}

let phoneA = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
let phoneB = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
root["handshakes"] = [
    handshakeVector(name: "right code", phoneCode: "482913", macCode: "482913", phoneID: phoneA,
                    sid: fill(16, 1), ya: fill(32, 2), yb: fill(32, 3)),
    handshakeVector(name: "right code 000000", phoneCode: "000000", macCode: "000000", phoneID: phoneB,
                    sid: fill(16, 4), ya: fill(32, 5), yb: fill(32, 6)),
    handshakeVector(name: "wrong code", phoneCode: "000000", macCode: "482913", phoneID: phoneA,
                    sid: fill(16, 7), ya: fill(32, 8), yb: fill(32, 9)),
]
root["pairReject"] = ["wrongCode": hex(PairingCrypto.pairReject(.wrongCode)), "noCode": hex(PairingCrypto.pairReject(.noCode))]

// MARK: - 握手之后的消息

let key = SymmetricKey(data: fill(32, 42))
let otherKey = SymmetricKey(data: fill(32, 43))
let nonce = fill(16, 50)
var msgs: [String: Any] = ["key": keyHex(key), "otherKey": keyHex(otherKey), "phoneID": phoneA.uuidString, "nonce": hex(nonce)]
msgs["commands"] = [("ping", 1), ("away", 2), ("unpair", 0x0102030405060708), ("避开", 9), ("", 3)].map { c, n -> [String: Any] in
    ["command": c, "counter": String(n), "sealed": hex(PairingCrypto.sealCommand(c, phoneID: phoneA, counter: UInt64(n), key: key)!)]
}
msgs["acks"] = [PairingCrypto.AckStatus.accepted, .unknownOrBadSignature, .replay, .malformed].map { s -> [String: Any] in
    ["status": Int(s.rawValue), "counter": "77", "bytes": hex(PairingCrypto.makeAck(phoneID: phoneA, counter: 77, status: s, key: key))]
}
msgs["states"] = [true, false].map { c -> [String: Any] in
    ["closed": c, "seq": "1800000000123", "bytes": hex(PairingCrypto.makeState(closed: c, seq: 1_800_000_000_123, phoneID: phoneA, key: key))]
}
msgs["revoke"] = hex(PairingCrypto.makeRevoke(phoneID: phoneA, key: key))
msgs["poll"] = hex(PairingCrypto.makePoll(nonce: nonce, phoneID: phoneA, key: key)!)
msgs["presence"] = [PairingCrypto.PresenceStatus.locked, .unlocked, .off].map { s -> [String: Any] in
    ["status": Int(s.rawValue), "counter": "12", "bytes": hex(PairingCrypto.sealPresence(s, nonce: nonce, phoneID: phoneA, counter: 12, key: key)!)]
}
msgs["liftNow"] = ["counter": "13", "bytes": hex(PairingCrypto.sealLiftNow(nonce: nonce, phoneID: phoneA, counter: 13, key: key)!)]
msgs["liftResults"] = [PairingCrypto.LiftStatus.lifted, .tooFar, .refused, .notCovered].map { s -> [String: Any] in
    ["status": Int(s.rawValue), "counter": "13", "bytes": hex(PairingCrypto.makeLiftResult(s, counter: 13, phoneID: phoneA, key: key))]
}
// 协议 v3（单独的键，老的 C# 测试读 "acks" 时只认 0–3）：缺权限的收据带签名、保持唤醒状态、新的命令字符串
msgs["ackMissingPermission"] = [
    "status": 4, "counter": "77", "signed": true,
    "bytes": hex(PairingCrypto.makeAck(phoneID: phoneA, counter: 77, status: .missingPermission, key: key)),
]
msgs["keepAwakeStates"] = [
    (UInt8(0), UInt64(0), "", UInt64(1800000000124)),
    (1, 1_800_003_600, "", 1800000000125),
    (2, 0, "", 1800000000126),
    (3, 1_800_030_600, "", 1800000000127),
    (4, 0, "Xcode", 1800000000128),
    (4, 0, "微信", 1800000000129),
    (4, 0, String(repeating: "应用", count: 40), 1800000000130),   // 240 字节，截到 63（不切断字符）
].map { mode, endsAt, app, seq -> [String: Any] in
    let bytes = PairingCrypto.makeKeepAwakeState(phoneID: phoneA, seq: seq, mode: mode, endsAt: endsAt, appName: app, key: key)
    let opened = PairingCrypto.openKeepAwakeState(bytes, phoneID: phoneA, key: key)!
    return ["mode": Int(mode), "endsAt": String(endsAt), "appNameIn": app, "appName": opened.appName,
            "seq": String(seq), "bytes": hex(bytes)]
}
msgs["commandsV3"] = [("awake:off", 20), ("awake:1h", 21), ("awake:2h", 22), ("awake:5h", 23), ("awake:always", 24), ("name:iPhone", 25)]
    .map { c, n -> [String: Any] in
        ["command": c, "counter": String(n), "sealed": hex(PairingCrypto.sealCommand(c, phoneID: phoneA, counter: UInt64(n), key: key)!)]
    }
root["messages"] = msgs

// 分帧
do {
    let long = Data((0..<200).map { UInt8($0 & 0xFF) })
    root["framing"] = [20, 2, 185, 512].map { size -> [String: Any] in
        ["message": hex(long), "maxChunk": size, "chunks": PairingFraming.chunks(long, maxChunk: size).map(hex)]
    } + [["message": "", "maxChunk": 20, "chunks": PairingFraming.chunks(Data(), maxChunk: 20).map(hex)]]
}

// MARK: - 计数 / 重放：同一串消息喂给 Swift 的 PairingAuthority，记下每一步的结果

do {
    let store = MemoryPairingStore()
    _ = store.save(PairingRecord(key: key, lastCounter: 1), for: phoneA)
    let authority = PairingAuthority(store: store, log: { _ in })
    let stranger = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    func cmd(_ c: String, _ n: UInt64, id: UUID = phoneA, k: SymmetricKey = key) -> Data {
        PairingCrypto.sealCommand(c, phoneID: id, counter: n, key: k)!
    }
    var tampered = [UInt8](cmd("away", 5)); tampered[27] ^= 1
    var bumped = [UInt8](cmd("away", 5)); bumped[25] ^= 0x10
    var flipped = [UInt8](PairingCrypto.sealPresence(.locked, nonce: nonce, phoneID: phoneA, counter: 8, key: key)!)
    flipped[42] = 1
    let steps: [(String, Data)] = [
        ("command", cmd("away", 2)),
        ("command", cmd("away", 2)),                 // 重放
        ("command", cmd("away", 1)),                 // 更小
        ("command", Data(tampered)),
        ("command", Data(bumped)),
        ("command", cmd("away", 9, k: otherKey)),
        ("command", cmd("away", 9, id: stranger)),
        ("command", Data("away".utf8)),
        ("answer", PairingCrypto.sealPresence(.unlocked, nonce: nonce, phoneID: phoneA, counter: 3, key: key)!),
        ("answer", PairingCrypto.sealPresence(.unlocked, nonce: nonce, phoneID: phoneA, counter: 3, key: key)!),
        ("answer", Data(flipped)),
        ("answer", PairingCrypto.sealLiftNow(nonce: nonce, phoneID: phoneA, counter: 3, key: key)!),
        ("command", cmd("away", 4)),
        ("answer", PairingCrypto.sealLiftNow(nonce: nonce, phoneID: phoneA, counter: 4, key: key)!),
        ("answer", PairingCrypto.sealLiftNow(nonce: nonce, phoneID: phoneA, counter: 5, key: key)!),
        ("answer", PairingCrypto.sealLiftNow(nonce: nonce, phoneID: stranger, counter: 50, key: key)!),
        ("answer", cmd("away", 60)),                 // 命令当回答
        ("command", PairingCrypto.sealPresence(.unlocked, nonce: nonce, phoneID: phoneA, counter: 61, key: key)!),
        ("command", cmd("ping", UInt64.max)),
        ("command", cmd("ping", UInt64.max)),
    ]
    var out: [[String: Any]] = []
    for (kind, data) in steps {
        var r: [String: Any] = ["kind": kind, "bytes": hex(data)]
        if kind == "command" {
            switch authority.handleCommand(data) {
            case .accepted(let c, _, let n, _, let ack):
                r["result"] = "accepted"; r["command"] = c; r["counter"] = String(n); r["ack"] = hex(ack)
            case .rejected(let why, _, let ack):
                r["result"] = "\(why)"; r["ack"] = ack.map(hex) ?? NSNull()
            }
        } else {
            switch authority.handleAnswer(data) {
            case .accepted(let a):
                r["result"] = "accepted"; r["counter"] = String(a.counter)
            case .rejected(let why, _):
                r["result"] = "\(why)"
            }
        }
        r["storedCounter"] = String(store.load(phoneA)!.lastCounter)
        out.append(r)
    }
    root["replay"] = ["key": keyHex(key), "phoneID": phoneA.uuidString, "initialCounter": "1", "steps": out]
}

// MARK: - LiftGate 场景（时间是相对 t0 的秒数；期望值是 Swift LiftGate 实际给的）

func describe(_ d: LiftGate.Decision) -> String {
    switch d {
    case .lift: return "lift"
    case .refuse(let r):
        switch r {
        case .notCovered: return "notCovered"
        case .unknownNonce: return "unknownNonce"
        case .staleNonce: return "staleNonce"
        case .toggleOff: return "toggleOff"
        case .phoneLocked: return "phoneLocked"
        case .edgeNotArmed: return "edgeNotArmed"
        case .notNear(let m): return "notNear(\(m))"
        case .noRSSI(let s): return "noRSSI(\(s))"
        }
    }
}

struct Op { let op: String; var t: Double = 0; var v: Int = 0; var n: Int = 0; var status: Int = 0 }
func covered(_ t: Double) -> Op { Op(op: "covered", t: t) }
func uncovered() -> Op { Op(op: "uncovered") }
func rssi(_ v: Int, _ t: Double) -> Op { Op(op: "rssi", t: t, v: v) }
func issue(_ n: Int, _ t: Double) -> Op { Op(op: "issue", t: t, n: n) }
func presence(_ s: Int, _ n: Int, _ t: Double) -> Op { Op(op: "presence", t: t, n: n, status: s) }
func liftNow(_ n: Int, _ t: Double) -> Op { Op(op: "liftNow", t: t, n: n) }
func resetRSSI() -> Op { Op(op: "resetRSSI") }
let L = 0, U = 1, OFF = 2

func near(_ armed: Bool, _ r: [Int] = [-60, -60, -60]) -> [Op] {
    var ops = [covered(0)] + r.enumerated().map { rssi($1, Double($0) * 2) }
    if armed { ops += [issue(1, 4), presence(L, 1, 4.3)] }
    return ops
}

let scenarios: [(String, [Op])] = [
    ("all conditions met", near(true) + [issue(2, 6), presence(U, 2, 6.4)]),
    ("not covered", [rssi(-50, 0), rssi(-50, 1), rssi(-50, 2), issue(2, 2), presence(U, 2, 2.2), liftNow(2, 2.2)]),
    ("phone locked", near(true) + [issue(2, 6), presence(L, 2, 6.2)]),
    ("not near -70", near(true, [-70, -71, -69]) + [issue(2, 6), presence(U, 2, 6.2)]),
    ("median of strong+weak", near(true, [-40, -80, -80]) + [issue(2, 6), presence(U, 2, 6.2)]),
    ("median -62", near(true, [-80, -60, -62]) + [issue(2, 6), presence(U, 2, 6.2)]),
    ("threshold exactly -65", near(true, [-65, -65, -65]) + [issue(2, 6), presence(U, 2, 6.2)]),
    ("threshold -66", near(true, [-66, -66, -66]) + [issue(2, 6), presence(U, 2, 6.2)]),
    ("only 2 rssi", near(true, [-60, -60]) + [issue(2, 6), presence(U, 2, 6.2)]),
    ("rssi too old", near(true) + [issue(2, 14), presence(U, 2, 14.2)]),
    ("rssi 127 ignored", near(true) + [rssi(127, 5), issue(2, 6), presence(U, 2, 6.2)]),
    ("rssi 0 ignored", near(true) + [rssi(0, 5), issue(2, 6), presence(U, 2, 6.2)]),
    ("toggle off", near(true) + [issue(2, 6), presence(OFF, 2, 6.2)]),
    ("off does not arm", near(false) + [issue(1, 4), presence(OFF, 1, 4.1), issue(2, 6), presence(U, 2, 6.2)]),
    ("unknown nonce", near(true) + [issue(2, 6), presence(U, 9, 6.2)]),
    ("nonce single use", near(true) + [issue(2, 6), presence(U, 2, 6.3), presence(U, 2, 6.4)]),
    ("nonce older than 5s", near(true) + [issue(2, 6), presence(U, 2, 11.5)]),
    ("nonce exactly 5s", near(true) + [issue(2, 6), presence(U, 2, 11.0)]),
    ("time goes back", near(true) + [issue(2, 6), presence(U, 2, 5)]),
    ("only 4 open nonces", near(true) + (2...8).map { issue($0, Double($0) * 0.1 + 6) } + [presence(U, 2, 6.9), presence(U, 8, 6.9)]),
    ("edge: never locked", near(false) + (0..<10).flatMap { i -> [Op] in
        [issue(10 + i, 6 + Double(i) * 2), rssi(-55, 6 + Double(i) * 2), presence(U, 10 + i, 6.3 + Double(i) * 2)]
    } + [rssi(-55, 28), issue(40, 30), rssi(-55, 30), presence(L, 40, 30.2), issue(41, 32), rssi(-55, 32), presence(U, 41, 32.2)]),
    ("edge: locked before re-cover does not count", near(true) + [uncovered(), covered(10), rssi(-60, 10), rssi(-60, 11), rssi(-60, 12),
                                                                  issue(5, 12), presence(U, 5, 12.2)]),
    ("edge: poll from before cover", near(false) + [issue(6, 4), covered(5), presence(L, 6, 5.5)]),
    ("lift-now skips edge", near(false) + [issue(2, 6), liftNow(2, 6.5)]),
    ("lift-now too far", near(false, [-75, -72, -78]) + [issue(2, 6), liftNow(2, 6.5)]),
    ("lift-now stale then used", near(false) + [issue(2, 6), liftNow(2, 12), liftNow(2, 6.5)]),
    ("lift-now no rssi", [covered(0), issue(2, 1), liftNow(2, 1.5)]),
    ("lift-now after uncover", near(false) + [issue(2, 6), uncovered(), liftNow(2, 6.5)]),
    ("rssi reset on disconnect", near(true) + [resetRSSI(), rssi(-50, 5), issue(2, 6), presence(U, 2, 6.2)]),
    ("rssi window keeps last 3", near(true) + [rssi(-90, 4.5), rssi(-90, 5), issue(2, 6), presence(U, 2, 6.2),
                                               rssi(-50, 6.5), rssi(-50, 7), issue(3, 7.5), presence(U, 3, 7.6)]),
    ("issue ignored while uncovered", [issue(1, 0), covered(1), rssi(-50, 1), rssi(-50, 2), rssi(-50, 3), liftNow(1, 3.1)]),
]

root["liftGate"] = [
    "nearMedianDBm": LiftGate.nearMedianDBm, "rssiSamples": LiftGate.rssiSamples,
    "rssiMaxAge": LiftGate.rssiMaxAge, "challengeLifetime": LiftGate.challengeLifetime,
    "maxOpenChallenges": LiftGate.maxOpenChallenges,
    "scenarios": scenarios.map { name, ops -> [String: Any] in
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        func n(_ i: Int) -> Data { Data(repeating: UInt8(i), count: 16) }
        var g = LiftGate()
        var steps: [[String: Any]] = []
        for o in ops {
            var s: [String: Any] = ["op": o.op, "t": o.t]
            switch o.op {
            case "covered": g.covered(at: at(o.t))
            case "uncovered": g.uncovered()
            case "rssi": g.recordRSSI(o.v, at: at(o.t)); s["v"] = o.v
            case "resetRSSI": g.resetRSSI()
            case "issue": g.issue(n(o.n), at: at(o.t)); s["nonce"] = o.n
            case "presence":
                let st = PairingCrypto.PresenceStatus(rawValue: UInt8(o.status))!
                let d = g.presence(st, nonce: n(o.n), at: at(o.t))
                s["nonce"] = o.n; s["status"] = o.status; s["expect"] = describe(d)
                if case .refuse(let r) = d { s["resultStatus"] = Int(LiftGate.resultStatus(for: r).rawValue) }
            case "liftNow":
                let d = g.liftNow(nonce: n(o.n), at: at(o.t))
                s["nonce"] = o.n; s["expect"] = describe(d)
                if case .refuse(let r) = d { s["resultStatus"] = Int(LiftGate.resultStatus(for: r).rawValue) }
            default: break
            }
            s["edgeArmed"] = g.edgeArmed
            steps.append(s)
        }
        return ["name": name, "steps": steps]
    },
]

let json = try! JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(json)
FileHandle.standardOutput.write(Data("\n".utf8))
