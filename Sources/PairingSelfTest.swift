// PairingSelfTest.swift —— 配对加密层的自测（进程内跑，两端都是纯函数，不碰蓝牙、不碰钥匙串）
//
// 一台 Mac 没法在空中同时当手机和 Mac，所以握手、验签都在内存里两边各走一遍：
//   CPace 测试向量（草案附录 B.1 + 独立 Python 参考实现算的 Elligator2）；
//   握手两边算出同一把钥匙；冒充的手机 / 冒充的 Mac 用错码都过不了、什么都不存；
//   一轮握手只能试一个码、录下来的数据没法离线验别的码；错 5 次码作废；签名命令收下；
//   同一个计数重放被拒；改过的命令被拒；不认识的手机被拒；明文命令被拒；
//   确认收据 / 幕布状态 / 撤销通知的签名；分帧切块再拼回来；
//   手机撤下幕布：条件都满足才撤、少一条都不撤、边沿规则、「现在撤下」、过期 / 重放 / 错 nonce、开关关着；
//   重连退避（ReconnectPolicy）：翻倍封顶 5 分钟、配过对时早断只退避不停手、没配过时第 5 次硬停、限时不理、每台手机留 2 个标识。
//
// 两个入口：
//   * Tests/PairingCryptoSelfTest.swift（verify.sh 里跑，和本文件 + PairingCrypto + PairingAuthority + LiftGate + ReconnectPolicy 一起编）
//   * 正在运行的 App：LockCurtain --send pairselftest，结果写到 /tmp/lockcurtain-pairtest.txt（不退出 App）

import CryptoKit
import Foundation

enum PairingSelfTest {
    static let outPath = "/tmp/lockcurtain-pairtest.txt"

    /// 返回每一项的记录和是否全通
    static func run() -> (lines: [String], passed: Bool) {
        var lines: [String] = []
        var failures = 0
        func expect(_ ok: Bool, _ name: String) {
            lines.append("\(ok ? "PASS" : "FAIL")  \(name)")
            if !ok { failures += 1 }
        }
        var authorityLog: [String] = []
        let log: (String) -> Void = { authorityLog.append($0) }

        let code = "482913"
        let phoneID = UUID()

        // 0. CPace / Elligator2 测试向量
        CPaceVectors.run(expect)

        // 1. 完整握手：两边同一把钥匙，第一条签名命令确认配对
        let store = MemoryPairingStore()
        let mac = PairingAuthority(store: store, log: log)
        mac.openWindow(code: code)
        let honest = handshake(mac, code: code, phoneID: phoneID)
        expect(honest.responded, "握手：Mac 回了 Yb 和确认标签 Tb")
        expect(honest.phoneKey != nil, "握手：手机核对 Mac 的 Tb 通过，Mac 核对手机的 Ta 通过，PairAccepted 验过")
        ImpostorTests.honest(expect, code: code)
        expect(mac.code.isEmpty, "握手：码用过一次就作废")
        expect(!mac.isPaired, "握手：没收到签名命令前 Mac 不算配上")

        guard let key = honest.phoneKey else {
            lines.append("结论：握手没成，后面的测不了")
            return (lines, false)
        }
        var macKeyMatches = false
        let ping = PairingCrypto.sealCommand("ping", phoneID: phoneID, counter: 1, key: key)!
        if case .accepted(let cmd, _, let counter, let confirmed, let ackData) = mac.handleCommand(ping) {
            let ack = try? PairingCrypto.Ack(decoding: ackData)
            macKeyMatches = cmd == "ping" && counter == 1 && confirmed
                && ack.map { PairingCrypto.verifyAck($0, key: key) } == true
        }
        expect(macKeyMatches, "握手：Mac 验过手机签的第一条命令，手机验过 Mac 的签名收据")
        expect(store.load(phoneID)?.key == key && store.load(phoneID)?.lastCounter == 1, "握手：钥匙和计数写进存储")
        expect(mac.isPaired, "握手：确认后 Mac 算配上")

        // 1b. 握手消息的版本是 2；老的 v1 请求不认
        var v1 = [UInt8](PairingCrypto.phoneStart(code: code, phoneID: phoneID)!.request.encoded())
        expect(v1[0] == 2, "线格式：握手消息版本是 2")
        v1[0] = 1
        expect(PairingCrypto.kind(of: Data(v1)) == nil, "线格式：版本 1 的配对请求不认")
        expect(PairingCrypto.kind(of: ping) == .command && [UInt8](ping)[0] == 1, "线格式：命令还是版本 1，格式不变")

        // 2. 冒充的手机（错码）：Mac 拒绝，什么都不存
        ImpostorTests.phone(expect, log: log, code: code)
        // 3. 冒充的 Mac（错码）：手机不接受，什么都不存
        ImpostorTests.mac(expect, code: code)
        // 4. 录下来的一轮没法离线验码
        ImpostorTests.offline(expect, log: log, code: code)
        // 5. sid 用过不再收；一轮作废后不能再用
        ImpostorTests.sessionReuse(expect, log: log, code: code)

        // 6. 错码被拒（老实的手机输错码：Tb 不对 → 放弃这一轮）
        let wrong = PairingAuthority(store: MemoryPairingStore(), log: log)
        wrong.openWindow(code: code)
        let typo = handshake(wrong, code: "000000", phoneID: UUID())
        expect(typo.phoneResult == .wrongCode && typo.abortLeft == 4, "错码：手机说码不对，Mac 记一次，还剩 4 次")

        // 7. 错 5 次码作废：之后真码也不行，换码也换不出来
        for _ in 0..<4 { _ = handshake(wrong, code: "000000", phoneID: UUID()) }
        expect(wrong.isLocked && wrong.code.isEmpty, "错 5 次：码作废")
        let late = PairingCrypto.phoneStart(code: code, phoneID: UUID())!.request
        if case .noCode = wrong.handlePair(late.encoded()) {
            expect(true, "错 5 次：之后用真码也被拒")
        } else {
            expect(false, "错 5 次：之后用真码也被拒")
        }
        expect(!wrong.refresh(code: "123456"), "错 5 次：「换一个码」换不出新码")
        wrong.openWindow(code: "654321")
        expect(!wrong.isLocked && wrong.attemptsLeft == 5, "错 5 次：重开窗口才有新码")

        // 7b. 半路不来（回了 Tb 就没下文）也算一次；第 5 轮没下文，下一次请求就锁
        let ghost = PairingAuthority(store: MemoryPairingStore(), log: log)
        ghost.openWindow(code: code)
        for _ in 0..<5 {
            _ = ghost.handlePair(PairingCrypto.phoneStart(code: "000000", phoneID: UUID())!.request.encoded())
        }
        expect(ghost.attemptsLeft == 0, "放着不确认：每一轮都扣一次")
        if case .noCode = ghost.handlePair(PairingCrypto.phoneStart(code: code, phoneID: UUID())!.request.encoded()) {
            expect(ghost.isLocked && ghost.code.isEmpty, "放着不确认：5 轮之后真码也被拒，码作废")
        } else {
            expect(false, "放着不确认：5 轮之后真码也被拒，码作废")
        }

        // 8. 签名命令收下
        let away = PairingCrypto.sealCommand("away", phoneID: phoneID, counter: 2, key: key)!
        if case .accepted(let cmd, _, let counter, let confirmed, _) = mac.handleCommand(away) {
            expect(cmd == "away" && counter == 2 && !confirmed && store.load(phoneID)?.lastCounter == 2,
                   "签名命令：收下，计数存成 2")
        } else {
            expect(false, "签名命令：收下，计数存成 2")
        }

        // 9. 重放（同一个计数）被拒
        expect(rejected(mac.handleCommand(away), .replay), "重放：同一条命令再来一次被拒")
        let older = PairingCrypto.sealCommand("away", phoneID: phoneID, counter: 1, key: key)!
        expect(rejected(mac.handleCommand(older), .replay), "重放：更小的计数被拒")

        // 10. 改过的命令被拒
        var tampered = [UInt8](PairingCrypto.sealCommand("away", phoneID: phoneID, counter: 3, key: key)!)
        tampered[27] ^= 0x01   // 命令文字第一个字节
        expect(rejected(mac.handleCommand(Data(tampered)), .badSignature), "篡改：改了命令文字被拒")
        var bumped = [UInt8](PairingCrypto.sealCommand("away", phoneID: phoneID, counter: 3, key: key)!)
        bumped[25] ^= 0x10      // 计数
        expect(rejected(mac.handleCommand(Data(bumped)), .badSignature), "篡改：改了计数被拒")
        let otherKey = SymmetricKey(size: .bits256)
        let forged = PairingCrypto.sealCommand("away", phoneID: phoneID, counter: 9, key: otherKey)!
        expect(rejected(mac.handleCommand(forged), .badSignature), "篡改：别的钥匙签的被拒")
        expect(store.load(phoneID)?.lastCounter == 2, "篡改：被拒的命令不动计数")

        // 11. 不认识的手机被拒
        let stranger = PairingCrypto.sealCommand("away", phoneID: UUID(), counter: 1, key: key)!
        expect(rejected(mac.handleCommand(stranger), .unknownPhone), "陌生手机：被拒")

        // 12. 明文命令（老格式）被拒
        expect(rejected(mac.handleCommand(Data("away".utf8)), .malformed), "明文命令：被拒")

        // 13. 收据 / 状态 / 撤销
        let unsignedOK = PairingCrypto.Ack(phoneID: phoneID, counter: 5, status: .accepted, mac: nil)
        expect(!PairingCrypto.verifyAck(unsignedOK, key: key), "收据：不带签名的「收下」不算数")
        // 13b. v3：缺权限的收据（status 4）带签名，手机能验过，但不算「收下」
        let perm = PairingCrypto.makeAck(phoneID: phoneID, counter: 6, status: .missingPermission, key: key)
        let permAck = try? PairingCrypto.Ack(decoding: perm)
        expect(perm.count == 59 && permAck?.status == .missingPermission && permAck?.mac != nil
               && permAck.map { PairingCrypto.verifyAck($0, key: key) } == true,
               "收据 v3：status 4（缺权限）带签名、能验过")
        expect(permAck.map { PairingCrypto.verifyAck($0, key: otherKey) } == false
               && !PairingCrypto.verifyAck(PairingCrypto.Ack(phoneID: phoneID, counter: 6, status: .missingPermission, mac: nil), key: key),
               "收据 v3：status 4 别的钥匙 / 不带签名验不过")
        expect(PairingCrypto.makeAck(phoneID: phoneID, counter: 6, status: .replay, key: key).count == 27,
               "收据 v3：1–3 照旧不签")

        // 13c. v3：保持唤醒状态（0x0F）
        let kaID = phoneID
        let ka = PairingCrypto.makeKeepAwakeState(phoneID: kaID, seq: 42, mode: PairingCrypto.KeepAwakeMode.whileApp.rawValue,
                                                  endsAt: 0, appName: "Xcode", key: key)
        let kaOpened = PairingCrypto.openKeepAwakeState(ka, phoneID: kaID, key: key)
        expect(PairingCrypto.kind(of: ka) == .keepAwakeState && kaOpened?.seq == 42 && kaOpened?.mode == 4
               && kaOpened?.endsAt == 0 && kaOpened?.appName == "Xcode",
               "保持唤醒状态：签了能打开，字段一样")
        let kaTimed = PairingCrypto.makeKeepAwakeState(phoneID: kaID, seq: 43, mode: 1, endsAt: 1_800_000_000, appName: "", key: key)
        expect(PairingCrypto.openKeepAwakeState(kaTimed, phoneID: kaID, key: key).map { $0.endsAt == 1_800_000_000 && $0.mode == 1 } == true,
               "保持唤醒状态：定时带结束时间")
        expect(PairingCrypto.openKeepAwakeState(ka, phoneID: UUID(), key: key) == nil
               && PairingCrypto.openKeepAwakeState(ka, phoneID: kaID, key: otherKey) == nil,
               "保持唤醒状态：别的手机 / 别的钥匙验不过")
        var kaBad = [UInt8](ka); kaBad[26] = 2
        expect(PairingCrypto.openKeepAwakeState(Data(kaBad), phoneID: kaID, key: key) == nil, "保持唤醒状态：改了 mode 验不过")
        let longName = String(repeating: "应用", count: 40)   // 240 字节
        let kaLong = PairingCrypto.makeKeepAwakeState(phoneID: kaID, seq: 44, mode: 4, endsAt: 0, appName: longName, key: key)
        let longOpened = PairingCrypto.openKeepAwakeState(kaLong, phoneID: kaID, key: key)
        expect(longOpened.map { Data($0.appName.utf8).count <= 64 && longName.hasPrefix($0.appName) && !$0.appName.isEmpty } == true,
               "保持唤醒状态：app 名截到 64 字节以内、不切断字符")
        expect(PairingCrypto.openState(ka, phoneID: kaID, key: key) == nil, "保持唤醒状态：不会被当成幕布状态")

        let state = mac.stateMessage(closed: true, for: phoneID)!
        expect(PairingCrypto.openState(state, phoneID: phoneID, key: key)?.closed == true, "状态：签名的「盖上」能验过")
        expect(PairingCrypto.openState(state, phoneID: UUID(), key: key) == nil, "状态：发给别的手机的不认")
        let notices = mac.revokeAll()
        expect(notices[phoneID].map { PairingCrypto.verifyRevoke($0, phoneID: phoneID, key: key) } == true,
               "撤销：通知带签名，手机能验过")
        expect(!mac.isPaired && store.load(phoneID) == nil, "撤销：Mac 的钥匙删掉了")
        let afterRevoke = PairingCrypto.sealCommand("away", phoneID: phoneID, counter: 10, key: key)!
        expect(rejected(mac.handleCommand(afterRevoke), .unknownPhone), "撤销：之后这台手机的命令被拒")

        // 14. 手机发「unpair」后 Mac 删钥匙（由 PhonePairing 调 revoke，这里直接走一遍）
        let m2 = PairingAuthority(store: MemoryPairingStore(), log: log)
        m2.openWindow(code: code)
        if let k2 = handshake(m2, code: code, phoneID: phoneID).phoneKey {
            _ = m2.handleCommand(PairingCrypto.sealCommand("ping", phoneID: phoneID, counter: 1, key: k2)!)
            let unpair = m2.handleCommand(PairingCrypto.sealCommand("unpair", phoneID: phoneID, counter: 2, key: k2)!)
            if case .accepted(let cmd, let id, _, _, _) = unpair, cmd == "unpair" { _ = m2.revoke(id) }
            expect(!m2.isPaired, "手机解除配对：Mac 收到签名的 unpair 后删钥匙")
        } else {
            expect(false, "手机解除配对：Mac 收到签名的 unpair 后删钥匙")
        }

        // 15. 分帧
        let long = Data((0..<200).map { UInt8($0 & 0xFF) })
        var assembler = PairingFraming.Assembler()
        var rebuilt: Data?
        for chunk in PairingFraming.chunks(long, maxChunk: 20) {
            expect(chunk.count <= 20, "分帧：每块不超过 20 字节") 
            rebuilt = assembler.feed(chunk) ?? rebuilt
        }
        expect(rebuilt == long, "分帧：切成 20 字节一块再拼回来一样")
        var a2 = PairingFraming.Assembler()
        let parts = PairingFraming.chunks(long, maxChunk: 20)
        _ = a2.feed(parts[0])
        expect(a2.feed(parts[2]) == nil, "分帧：漏块整条丢掉")

        // 16. 手机撤下幕布：判断（LiftGate）+ 签名 / 计数 / nonce（PairingAuthority）
        LiftTests.gate(expect)
        LiftTests.wire(expect, log: log, code: code)

        // 17. 重连退避
        ReconnectTests.run(expect)

        // 日志里不许出现码
        expect(!authorityLog.contains { $0.contains(code) }, "日志：不含配对码")

        lines = lines.filter { !$0.hasPrefix("PASS  分帧：每块不超过") } // 每块一行太吵，只留失败的
        lines.append(failures == 0 ? "结论：全通" : "结论：\(failures) 项没通")
        return (lines, failures == 0)
    }

    /// 一轮握手的记录（手机这边按 BLECurtainLink.pair 的步骤走）
    struct Run {
        var responded = false
        var phoneResult: PhoneResult?
        var phoneKey: SymmetricKey?
        var abortLeft: Int?
    }

    enum PhoneResult: Equatable { case accepted, wrongCode, refused }

    /// 手机用 code 和 Mac 走一遍完整握手
    static func handshake(_ mac: PairingAuthority, code: String, phoneID: UUID) -> Run {
        var run = Run()
        guard let (request, session) = PairingCrypto.phoneStart(code: code, phoneID: phoneID),
              case .responded(let reply) = mac.handlePair(request.encoded()),
              let response = try? PairingCrypto.PairResponse(decoding: reply) else {
            run.phoneResult = .refused
            return run
        }
        run.responded = true
        switch PairingCrypto.phoneFinish(response, session: session) {
        case .wrongCode, .invalid:
            run.phoneResult = .wrongCode
            if case .aborted(let left) = mac.handlePair(PairingCrypto.pairAbort(phoneID: phoneID, sid: session.sid)) {
                run.abortLeft = left
            }
        case .confirm(let confirm, let key):
            if case .accepted(let accepted, let id) = mac.handlePair(confirm.encoded()), id == phoneID,
               PairingCrypto.verifyPairAccepted(accepted, phoneID: phoneID, sid: session.sid, key: key) {
                run.phoneResult = .accepted
                run.phoneKey = key
            } else {
                run.phoneResult = .refused
            }
        }
        return run
    }

    private static func rejected(_ outcome: PairingAuthority.CommandOutcome, _ reason: PairingAuthority.RejectReason) -> Bool {
        if case .rejected(let r, _, _) = outcome { return r == reason }
        return false
    }

    /// App 里的入口：写结果文件
    static func runAndWrite() {
        let (lines, _) = run()
        try? lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - CPace 测试向量

/// 草案 draft-irtf-cfrg-cpace（-21）附录 A、B.1 的向量，外加用草案附录 A.5 的 Python 参考实现独立算的 Elligator2 向量
enum CPaceVectors {
    static func hex(_ s: String) -> Data {
        var out = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    static func run(_ expect: (Bool, String) -> Void) {
        // A.1 prepend_len / lv_cat，A.3.5 transcript_ir
        expect(CPace.prependLen(Data()) == hex("00")
               && CPace.prependLen(Data("1234".utf8)) == hex("0431323334")
               && CPace.prependLen(Data(0..<127)) == hex("7f") + Data(0..<127)
               && CPace.prependLen(Data(0..<128)) == hex("8001") + Data(0..<128),
               "向量：prepend_len（LEB128）")
        expect(CPace.lvCat(Data("1234".utf8), Data("5".utf8), Data(), Data("678".utf8)) == hex("043132333401350003363738"),
               "向量：lv_cat")
        let tir = CPace.lvCat(Data("123".utf8), Data("PartyA".utf8)) + CPace.lvCat(Data("234".utf8), Data("PartyB".utf8))
        expect(tir == hex("03313233065061727479410332333406506172747942"), "向量：transcript_ir")

        // B.1.1 calculate_generator
        let prs = Data("Password".utf8)
        let ci = hex("0b415f696e69746961746f720b425f726573706f6e646572")
        let sid = hex("7e4b4791d6a8ef019b936c79fb7f2c57")
        let genStr = CPace.generatorString(prs: prs, ci: ci, sid: sid)
        expect(genStr == hex("0843506163653235350850617373776f72646d" + String(repeating: "00", count: 109)
                             + "180b415f696e69746961746f720b425f726573706f6e646572107e4b4791d6a8ef019b936c79fb7f2c57"),
               "向量：generator_string（ZPAD 109）")
        let genHash = Data(SHA512.hash(data: genStr)).prefix(32)
        expect(genHash == hex("03998087bdb1a2617bbe25ef5a7c18cd4f84f902328701790958755ee4aed1d3"), "向量：generator string 的哈希")
        expect(Data(Field25519(bytes: [UInt8](genHash)).bytes)
               == hex("03998087bdb1a2617bbe25ef5a7c18cd4f84f902328701790958755ee4aed153"), "向量：decodeUCoordinate（去最高位）")
        let g = CPace.calculateGenerator(prs: prs, ci: ci, sid: sid)
        expect(g == hex("d04bf6d41f6a289632a2e929fa29bebd51092512a7829fdde7d314b62f05a73f"), "向量：生成元 g（Elligator2）")

        // B.1.2–B.1.5 两边的消息、K、ISK
        let ya = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation:
            hex("21b4f4bd9e64ed355c3eb676a28ebedaf6d8f17bdc365995b3190971" + "53044080"))
        let yb = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation:
            hex("848b0779ff415f0af4ea14df9dd1d3c29ac41d836c7808896c4eba19" + "c51ac40a"))
        let bigYa = CPace.scalarMult(ya, g)
        let bigYb = CPace.scalarMult(yb, g)
        expect(bigYa == hex("1d13c89278cdadd826f6d8d7f887701430f8380ddc17611cdd6dc989ce0c9f32"), "向量：Ya")
        expect(bigYb == hex("248cccf6d5cdc3646f0ad593f9e6cef4e69d4945f8372e623512ecea32185623"), "向量：Yb")
        let kA = bigYb.flatMap { CPace.scalarMult(ya, $0) }
        let kB = bigYa.flatMap { CPace.scalarMult(yb, $0) }
        let k = hex("5b067effbdc0b2a0e1d907b21ebb25cfedb96a852179a847c37e43ee71322c6b")
        expect(kA == k && kB == k, "向量：K（两边一样）")
        if let bigYa, let bigYb {
            let isk = CPace.isk(sid: sid, k: k, ya: bigYa, ada: Data("ADa".utf8), yb: bigYb, adb: Data("ADb".utf8))
            expect(isk == hex("6e19b875f7a561d6b3ca3dbb9ef42ac55de3e717881018204b8922b4d5e53bb2"
                              + "aa82c300bea7b65d2b671da71922ddf6472301b79bc270adfa8bf413285f2263"), "向量：ISK（发起方-应答方）")
        } else {
            expect(false, "向量：ISK（发起方-应答方）")
        }

        // B.1.10 低阶点：u0…u5、u7 必须中止，其余给出指定结果
        let s = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation:
            hex("af46e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449aff"))
        let lowOrder: [(String, String?)] = [
            ("0000000000000000000000000000000000000000000000000000000000000000", nil),
            ("0100000000000000000000000000000000000000000000000000000000000000", nil),
            ("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", nil),
            ("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800", nil),
            ("5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157", nil),
            ("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", nil),
            ("daffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "d8e2c776bbacd510d09fd9278b7edcd25fc5ae9adfba3b6e040e8d3b71b21806"),
            ("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", nil),
            ("dbffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "c85c655ebe8be44ba9c0ffde69f2fe10194458d137f09bbff725ce58803cdb38"),
            ("d9ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "db64dafa9b8fdd136914e61461935fe92aa372cb056314e1231bc4ec12417456"),
            ("cdeb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b880", "e062dcd5376d58297be2618c7498f55baa07d7e03184e8aada20bca28888bf7a"),
            ("4c9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f11d7", "993c6ad11c4c29da9a56f7691fd0ff8d732e49de6250b6c2e80003ff4629a175"),
        ]
        let lowOK = lowOrder.allSatisfy { u, q in CPace.scalarMult(s, hex(u)) == q.map(hex) }
        expect(lowOK, "向量：低阶点 u0…ub（u0–u5、u7 中止，u6、u8–ub 结果对）")

        // Elligator2：独立的 Python 参考实现（草案附录 A.5 的公式，大整数）算出来的
        let ell: [(String, String)] = [
            ("0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000"),
            ("0100000000000000000000000000000000000000000000000000000000000000", "9cdb525555555555555555555555555555555555555555555555555555555555"),
            ("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "9cdb525555555555555555555555555555555555555555555555555555555555"),
            ("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "0000000000000000000000000000000000000000000000000000000000000000"),
            ("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1e5942dd97c756040d27755f1e5b11349cd47d796c45d07052f7e5b11541c349"),
            ("86ef3110c37b8ca53ef79f8fa4c2ee6872938823efbd9251b19c500f8a22b309", "12fffb4a9b077a46e4a46670f344f0b998761f589f40ecb6a7d91c5ec6ab8065"),
            ("4f711d2a3130d48e241a88e9b5261d444e0bf4bb561680da1648101946bd760b", "abd8547b367a8c0f64fde89e2bb310c8b2513a2b25b6a1b51bf592d7deb5484e"),
            ("6c0ddf2c181e6b4ff3ae44fdf1a92108c5c653d8ef75af813430ae2799c57f98", "4d5ed5d65b4d8f84eb415af5ec16381febfc21cf279a64577d96235bac46471a"),
            ("791116d9d2d15324f20c498eba6607d243d2f87361271774147a0daf6f7dba53", "1fa54dec65d0f6889b02a0270b9698b7a4d1cd29dc0e13bb5b6572ee8f0cba2c"),
            ("724865375e1202945f9012f381c16e43b024d3a21802a268a6c6308ebef98c88", "ab04f20aa9dc1b2ef95cecefb766790c02d7f837c031cd8f1e1371ca00918f15"),
            ("c261fefbbb38cda71c9c4ca992a4f484ab1544b3a38e5c584be88b6e0ba08949", "68e05c04604beb4ed4a8fdf850afe6f2fac095c5261bccb841882567cf62b53d"),
        ]
        let ellOK = ell.allSatisfy { input, output in CPace.elligator2([UInt8](hex(input))) == hex(output) }
        expect(ellOK, "向量：Elligator2 映射 11 组（含 0、p−1、p、全 1 这些边界）")

        // 域运算自检：a·a⁻¹ = 1，(p−1)² = 1
        let a = Field25519(bytes: [UInt8](hex("86ef3110c37b8ca53ef79f8fa4c2ee6872938823efbd9251b19c500f8a22b309")))
        let minusOne = Field25519.zero - Field25519.one
        expect(Field25519.equal(a * a.inverse, .one) && Field25519.equal(minusOne * minusOne, .one), "域运算：求逆、−1 的平方")
    }
}

// MARK: - 冒充 / 离线攻击

enum ImpostorTests {
    /// 攻击者只用自己手里的东西（自己的标量 + 收到的消息）能算出的「钥匙」
    static func attackerKeys(secret: Curve25519.KeyAgreement.PrivateKey, sid: Data, ya: Data, yb: Data)
        -> PairingCrypto.HandshakeKeys? {
        guard let k = CPace.scalarMult(secret, yb) else { return nil }
        return PairingCrypto.handshakeKeys(sid: sid, k: k, ya: ya, yb: yb)
    }

    /// (4) 老实的一轮：两边钥匙一样
    static func honest(_ expect: (Bool, String) -> Void, code: String) {
        let phoneID = UUID()
        guard let (request, phone) = PairingCrypto.phoneStart(code: code, phoneID: phoneID),
              let (response, mac) = PairingCrypto.macRespond(request, code: code),
              case .confirm(let confirm, let phoneKey) = PairingCrypto.phoneFinish(response, session: phone) else {
            expect(false, "老实握手：两边算出同一把钥匙，双向确认都过")
            return
        }
        expect(PairingCrypto.macCheckConfirm(confirm, session: mac) && phoneKey == mac.sharedKey,
               "老实握手：两边算出同一把钥匙，双向确认都过")
    }

    /// (1) 冒充的手机，码猜错：Mac 拒绝，什么都不存
    static func phone(_ expect: (Bool, String) -> Void, log: @escaping (String) -> Void, code: String) {
        let store = MemoryPairingStore()
        let mac = PairingAuthority(store: store, log: log)
        mac.openWindow(code: code)
        let phoneID = UUID()
        let (request, session) = PairingCrypto.phoneStart(code: "000000", phoneID: phoneID)!
        guard case .responded(let reply) = mac.handlePair(request.encoded()),
              let response = try? PairingCrypto.PairResponse(decoding: reply),
              let keys = attackerKeys(secret: session.secret, sid: session.sid, ya: session.ya, yb: response.yb) else {
            expect(false, "冒充手机：Mac 拒绝它的确认，什么都不存")
            return
        }
        // 不管 Tb 对不对，照样把自己算的 Ta 发过去
        let ta = CPace.tag(keys.macKey, y: session.ya, ad: Data())
        let confirm = PairingCrypto.PairConfirm(phoneID: phoneID, sid: session.sid, tag: ta)
        var ok = false
        if case .rejected(let r, let left) = mac.handlePair(confirm.encoded()) {
            ok = PairingCrypto.decodePairReject(r) == .wrongCode && left == 4
        }
        // 它自以为的钥匙签的命令：Mac 不认识这台手机
        let forged = PairingCrypto.sealCommand("ping", phoneID: phoneID, counter: 1, key: keys.sharedKey)!
        var unknown = false
        if case .rejected(.unknownPhone, _, _) = mac.handleCommand(forged) { unknown = true }
        expect(ok && unknown && store.allPhoneIDs().isEmpty && !mac.isPaired && !mac.code.isEmpty,
               "冒充手机：Mac 拒绝它的确认（记一次错），什么都不存，签的命令也不认")

        // 随便编一个 Ta 也不行
        let (r2, s2) = PairingCrypto.phoneStart(code: "999999", phoneID: phoneID)!
        _ = mac.handlePair(r2.encoded())
        let junk = PairingCrypto.PairConfirm(phoneID: phoneID, sid: s2.sid, tag: Data(count: 64))
        if case .rejected(_, let left) = mac.handlePair(junk.encoded()) {
            expect(left == 3 && store.allPhoneIDs().isEmpty, "冒充手机：编造的 Ta 被拒，又记一次错")
        } else {
            expect(false, "冒充手机：编造的 Ta 被拒，又记一次错")
        }
    }

    /// (2) 冒充的 Mac，码猜错：手机不接受，什么都不存
    static func mac(_ expect: (Bool, String) -> Void, code: String) {
        let phoneID = UUID()
        let (request, session) = PairingCrypto.phoneStart(code: code, phoneID: phoneID)!
        let (fake, fakeSession) = PairingCrypto.macRespond(request, code: "111111")!
        var refused = false
        if case .wrongCode = PairingCrypto.phoneFinish(fake, session: session) { refused = true }
        expect(refused, "冒充 Mac：手机验它的 Tb 不过，不发 Ta、不存钥匙")
        // 就算它跳过 Tb 直接发 PairAccepted（用它自己那把钥匙签），手机也不认
        let forgedAccept = PairingCrypto.pairAccepted(phoneID: phoneID, sid: session.sid, key: fakeSession.sharedKey)
        let otherKey = SymmetricKey(size: .bits256)
        expect(!PairingCrypto.verifyPairAccepted(forgedAccept, phoneID: phoneID, sid: session.sid, key: otherKey),
               "冒充 Mac：伪造的 PairAccepted 验不过")
        // 拿另一轮真 Mac 的应答来回放：sid 不对，手机直接拒
        let (otherRequest, _) = PairingCrypto.phoneStart(code: code, phoneID: phoneID)!
        let (replayed, _) = PairingCrypto.macRespond(otherRequest, code: code)!
        var invalid = false
        if case .invalid = PairingCrypto.phoneFinish(replayed, session: session) { invalid = true }
        expect(invalid, "冒充 Mac：回放别的一轮的应答，手机拒绝")
        // 低阶点当 Yb：中止
        var lowOrder = fake
        lowOrder.yb = Data(count: 32)
        var aborted = false
        if case .invalid = PairingCrypto.phoneFinish(lowOrder, session: session) { aborted = true }
        expect(aborted, "冒充 Mac：Yb 是低阶点，手机中止")
    }

    /// (3) 录下来的一轮：攻击者只验了自己猜的那一个码，没有能离线验别的码的东西
    static func offline(_ expect: (Bool, String) -> Void, log: @escaping (String) -> Void, code: String) {
        let guess = "000000"
        let phoneID = UUID()
        let mac = PairingAuthority(store: MemoryPairingStore(), log: log)
        mac.openWindow(code: code)
        let (request, session) = PairingCrypto.phoneStart(code: guess, phoneID: phoneID)!
        guard case .responded(let reply) = mac.handlePair(request.encoded()),
              let response = try? PairingCrypto.PairResponse(decoding: reply) else {
            expect(false, "离线：攻击者拿到 Mac 的应答")
            return
        }

        // a. 它猜的码：确认不过
        var guessFails = false
        if case .wrongCode = PairingCrypto.phoneFinish(response, session: session) { guessFails = true }
        expect(guessFails, "离线：攻击者猜的码，Tb 验不过（这一轮只告诉它「这个码不对」）")

        // b. 不同的码给出毫无关系的生成元；同一个标量在不同生成元上的结果也毫无关系
        let candidates = [code, guess] + (1...30).map { String(format: "%06d", $0 * 33_331 % 1_000_000) }
        let generators = candidates.map { PairingCrypto.generator(code: $0, phoneID: phoneID, sid: session.sid) }
        let probe = CPace.sampleScalar()
        let products = generators.compactMap { CPace.scalarMult(probe, $0) }
        expect(Set(generators).count == candidates.count && Set(products).count == candidates.count,
               "离线：\(candidates.count) 个不同的码 → 互不相同的生成元和 y·g")

        // c. 它手里能算的钥匙只有 K = ya·Yb，和「真码是哪个」无关：对每个候选码，拿录下的 Tb 去核对，结果都一样（都不过）
        guard let mine = attackerKeys(secret: session.secret, sid: session.sid, ya: session.ya, yb: response.yb) else {
            expect(false, "离线：攻击者的视角里没有能验别的码的值")
            return
        }
        let tbChecks = candidates.map { _ in
            CPace.tagValid(response.tag, key: mine.macKey, y: response.yb, ad: Data())
        }
        // 再试「用候选码重算 Ya、把录下的 Yb 当共享点」这类不需要 Mac 标量的办法：真码也验不出来
        let naive = candidates.indices.map { i -> Bool in
            guard let yaC = CPace.scalarMult(session.secret, generators[i]) else { return false }
            let tries = [response.yb, generators[i], yaC].map { kGuess in
                PairingCrypto.handshakeKeys(sid: session.sid, k: kGuess, ya: session.ya, yb: response.yb)
            } + [PairingCrypto.handshakeKeys(sid: session.sid, k: CPace.scalarMult(session.secret, response.yb) ?? Data(),
                                            ya: yaC, yb: response.yb)]
            return tries.contains { CPace.tagValid(response.tag, key: $0.macKey, y: response.yb, ad: Data()) }
        }
        expect(!tbChecks.contains(true) && !naive.contains(true),
               "离线：录下的 Tb 对 \(candidates.count) 个候选码（含真码）一个都对不上 —— 没有离线核对的办法")

        // d. 换一台码不同的 Mac，同样的猜测：攻击者能做的核对结果完全一样（视角和真码无关）
        let mac2 = PairingAuthority(store: MemoryPairingStore(), log: log)
        mac2.openWindow(code: "271828")
        let (request2, session2) = PairingCrypto.phoneStart(code: guess, phoneID: phoneID)!
        var same = false
        if case .responded(let reply2) = mac2.handlePair(request2.encoded()),
           let response2 = try? PairingCrypto.PairResponse(decoding: reply2),
           let mine2 = attackerKeys(secret: session2.secret, sid: session2.sid, ya: session2.ya, yb: response2.yb) {
            let checks2 = candidates.map { _ in CPace.tagValid(response2.tag, key: mine2.macKey, y: response2.yb, ad: Data()) }
            same = checks2 == tbChecks
        }
        expect(same, "离线：真码是 \(String(repeating: "•", count: 6)) 还是别的，攻击者的核对结果都一样")

        // e. 这一轮用掉了：再交一个 Ta（换个猜测）不给任何新信息，也不再扣次数；想再猜就得开新的一轮（再扣一次）
        let ta = CPace.tag(mine.macKey, y: session.ya, ad: Data())
        let first = mac.handlePair(PairingCrypto.PairConfirm(phoneID: phoneID, sid: session.sid, tag: ta).encoded())
        let leftAfterFirst = mac.attemptsLeft
        let secondGuess = PairingCrypto.PairConfirm(phoneID: phoneID, sid: session.sid, tag: Data(count: 64))
        let second = mac.handlePair(secondGuess.encoded())
        expect(first == second && mac.attemptsLeft == leftAfterFirst,
               "离线：同一轮的第二次确认只得到同样的拒绝，没有第二次猜的机会")
        let (request3, _) = PairingCrypto.phoneStart(code: guess, phoneID: phoneID)!
        var fresh = false
        if case .responded(let reply3) = mac.handlePair(request3.encoded()),
           let response3 = try? PairingCrypto.PairResponse(decoding: reply3) {
            fresh = response3.yb != response.yb && mac.attemptsLeft == leftAfterFirst - 1
        }
        expect(fresh, "离线：再猜要开新的一轮（Mac 换新的 Yb，再扣一次）")

        // 对照：v1 的 tag = HMAC(SHA256(码), pub‖id) 能离线把码试出来
        let v1Key = { (c: String) in SymmetricKey(data: Data(SHA256.hash(data: Data(c.utf8)))) }
        let pub = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let v1Tag = PairingCrypto.hmac(pub + PairingCrypto.bytes(phoneID), key: v1Key(code))
        let found = candidates.filter { PairingCrypto.hmacValid(v1Tag, for: pub + PairingCrypto.bytes(phoneID), key: v1Key($0)) }
        expect(found == [code], "对照：v1 录下一个 tag 就能离线试出码（v2 不行）")
    }

    /// sid 用过不再收；作废的一轮不能再用
    static func sessionReuse(_ expect: (Bool, String) -> Void, log: @escaping (String) -> Void, code: String) {
        let mac = PairingAuthority(store: MemoryPairingStore(), log: log)
        mac.openWindow(code: code)
        let phoneID = UUID()
        let (request, session) = PairingCrypto.phoneStart(code: code, phoneID: phoneID)!
        guard case .responded(let reply) = mac.handlePair(request.encoded()),
              let response = try? PairingCrypto.PairResponse(decoding: reply),
              case .confirm(let confirm, _) = PairingCrypto.phoneFinish(response, session: session) else {
            expect(false, "会话：同一个 sid 不收第二次")
            return
        }
        // 同一个 sid 再来一次（比如重放请求）：不收，不扣次数，也不打扰进行中的那一轮
        let left = mac.attemptsLeft
        var refused = false
        if case .malformed = mac.handlePair(request.encoded()) { refused = true }
        expect(refused && mac.attemptsLeft == left, "会话：同一个 sid 不收第二次，不扣次数")
        var accepted = false
        if case .accepted = mac.handlePair(confirm.encoded()) { accepted = true }
        expect(accepted, "会话：重放的请求不打扰进行中的那一轮")
        // 用过的一轮：同一个 Ta 再交一次不收
        if case .rejected = mac.handlePair(confirm.encoded()) {
            expect(true, "会话：用过的一轮，同一个 Ta 再交不收")
        } else {
            expect(false, "会话：用过的一轮，同一个 Ta 再交不收")
        }
        mac.openWindow(code: code)
        // 换码：进行中的一轮作废
        let (r2, s2) = PairingCrypto.phoneStart(code: code, phoneID: phoneID)!
        if case .responded(let reply2) = mac.handlePair(r2.encoded()),
           let resp2 = try? PairingCrypto.PairResponse(decoding: reply2),
           case .confirm(let c2, _) = PairingCrypto.phoneFinish(resp2, session: s2) {
            _ = mac.refresh(code: "135790")
            if case .rejected = mac.handlePair(c2.encoded()) {
                expect(true, "会话：换码后，进行中的那一轮作废")
            } else {
                expect(false, "会话：换码后，进行中的那一轮作废")
            }
        } else {
            expect(false, "会话：换码后，进行中的那一轮作废")
        }
    }
}

// MARK: - 手机撤下幕布

enum LiftTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    static func nonce(_ n: UInt8) -> Data { Data(repeating: n, count: PairingCrypto.nonceLength) }

    /// 盖上（t=0），近（三次 -60），可选先报一次锁着
    static func coveredNear(armed: Bool, rssi: [Int] = [-60, -60, -60]) -> LiftGate {
        var g = LiftGate()
        g.covered(at: at(0))
        for (i, v) in rssi.enumerated() { g.recordRSSI(v, at: at(Double(i) * 2)) }
        if armed {
            g.issue(nonce(1), at: at(4))
            _ = g.presence(.locked, nonce: nonce(1), at: at(4.3))
        }
        return g
    }

    static func gate(_ expect: (Bool, String) -> Void) {
        // 全满足：盖上之后先锁着、再解锁着、近、新鲜、开关开着 → 撤
        var g = coveredNear(armed: true)
        expect(g.edgeArmed, "撤下：盖上之后报锁着，边沿就绪")
        g.issue(nonce(2), at: at(6))
        expect(g.presence(.unlocked, nonce: nonce(2), at: at(6.4)) == .lift, "撤下：条件全满足 → 撤")

        // 少一条都不撤
        var notCovered = LiftGate()
        notCovered.recordRSSI(-50, at: at(0)); notCovered.recordRSSI(-50, at: at(1)); notCovered.recordRSSI(-50, at: at(2))
        notCovered.issue(nonce(2), at: at(2))
        expect(notCovered.presence(.unlocked, nonce: nonce(2), at: at(2.2)) == .refuse(.notCovered)
               && notCovered.liftNow(nonce: nonce(2), at: at(2.2)) == .refuse(.notCovered),
               "撤下：幕布没盖着 → 不撤（「现在撤下」也不撤）")

        g = coveredNear(armed: true)
        g.issue(nonce(2), at: at(6))
        expect(g.presence(.locked, nonce: nonce(2), at: at(6.2)) == .refuse(.phoneLocked), "撤下：手机锁着 → 不撤")

        g = coveredNear(armed: true, rssi: [-70, -71, -69])
        g.issue(nonce(2), at: at(6))
        expect(g.presence(.unlocked, nonce: nonce(2), at: at(6.2)) == .refuse(.notNear(median: -70)), "撤下：不够近（中位数 -70）→ 不撤")

        g = coveredNear(armed: true, rssi: [-40, -80, -80])
        g.issue(nonce(2), at: at(6))
        expect(g.presence(.unlocked, nonce: nonce(2), at: at(6.2)) == .refuse(.notNear(median: -80)),
               "撤下：一次很强、两次很弱，看中位数 → 不撤")
        g = coveredNear(armed: true, rssi: [-80, -60, -62])
        g.issue(nonce(2), at: at(6))
        expect(g.presence(.unlocked, nonce: nonce(2), at: at(6.2)) == .lift, "撤下：一次弱、两次够近，中位数 -62 → 撤")
        g = coveredNear(armed: true, rssi: [-65, -65, -65])
        g.issue(nonce(2), at: at(6))
        expect(g.presence(.unlocked, nonce: nonce(2), at: at(6.2)) == .lift, "撤下：中位数正好在门槛上 → 撤")

        g = coveredNear(armed: true, rssi: [-60, -60])
        g.issue(nonce(2), at: at(6))
        expect(g.presence(.unlocked, nonce: nonce(2), at: at(6.2)) == .refuse(.noRSSI(samples: 2)), "撤下：RSSI 不够 3 次 → 不撤")
        g = coveredNear(armed: true)
        g.issue(nonce(2), at: at(14))
        expect(g.presence(.unlocked, nonce: nonce(2), at: at(14.2)) == .refuse(.noRSSI(samples: 0)), "撤下：RSSI 太旧 → 不撤")
        g = coveredNear(armed: true)
        g.recordRSSI(127, at: at(5))
        g.issue(nonce(2), at: at(6))
        expect(g.presence(.unlocked, nonce: nonce(2), at: at(6.2)) == .lift, "撤下：读不到的 RSSI（127）不算数")

        g = coveredNear(armed: true)
        g.issue(nonce(2), at: at(6))
        expect(g.presence(.off, nonce: nonce(2), at: at(6.2)) == .refuse(.toggleOff), "撤下：手机「走近撤下」关着 → 不撤")
        var off = coveredNear(armed: false)
        off.issue(nonce(1), at: at(4)); _ = off.presence(.off, nonce: nonce(1), at: at(4.1))
        off.issue(nonce(2), at: at(6))
        expect(!off.edgeArmed && off.presence(.unlocked, nonce: nonce(2), at: at(6.2)) == .refuse(.edgeNotArmed),
               "撤下：关着的回答不算「锁着」，不给边沿就绪")

        // 新鲜：错 nonce、用过的 nonce、过期的 nonce
        g = coveredNear(armed: true)
        g.issue(nonce(2), at: at(6))
        expect(g.presence(.unlocked, nonce: nonce(9), at: at(6.2)) == .refuse(.unknownNonce), "撤下：不是 Mac 发的 nonce → 不撤")
        expect(g.presence(.unlocked, nonce: nonce(2), at: at(6.3)) == .lift
               && g.presence(.unlocked, nonce: nonce(2), at: at(6.4)) == .refuse(.unknownNonce),
               "撤下：同一个 nonce 只能用一次（重放的回答不撤）")
        g = coveredNear(armed: true)
        g.issue(nonce(2), at: at(6))
        expect(g.presence(.unlocked, nonce: nonce(2), at: at(11.5)) == .refuse(.staleNonce), "撤下：超过 5 秒的回答 → 不撤")
        g = coveredNear(armed: true)
        g.issue(nonce(2), at: at(6))
        expect(g.presence(.unlocked, nonce: nonce(2), at: at(5)) == .refuse(.staleNonce), "撤下：时间倒流的回答 → 不撤")
        g = coveredNear(armed: true)
        for i in 2...8 { g.issue(nonce(UInt8(i)), at: at(Double(i) * 0.1 + 6)) }
        expect(g.presence(.unlocked, nonce: nonce(2), at: at(6.9)) == .refuse(.unknownNonce)
               && g.presence(.unlocked, nonce: nonce(8), at: at(6.9)) == .lift,
               "撤下：只记最近 \(LiftGate.maxOpenChallenges) 个没回答的 nonce")

        // 边沿规则
        g = coveredNear(armed: false)
        var lifted = false
        for i in 0..<10 {
            g.issue(nonce(UInt8(10 + i)), at: at(6 + Double(i) * 2))
            g.recordRSSI(-55, at: at(6 + Double(i) * 2))
            if g.presence(.unlocked, nonce: nonce(UInt8(10 + i)), at: at(6.3 + Double(i) * 2)) == .lift { lifted = true }
        }
        expect(!lifted, "边沿：按了盖上、手机一直没锁、人没动（10 次解锁着的回答）→ 一直不撤")
        g.recordRSSI(-55, at: at(28))
        g.issue(nonce(40), at: at(30)); g.recordRSSI(-55, at: at(30))
        _ = g.presence(.locked, nonce: nonce(40), at: at(30.2))
        g.issue(nonce(41), at: at(32)); g.recordRSSI(-55, at: at(32))
        expect(g.presence(.unlocked, nonce: nonce(41), at: at(32.2)) == .lift, "边沿：之后锁一下再解锁 → 撤")

        var before = coveredNear(armed: true)          // 第一次盖上时见过锁着
        before.uncovered()
        before.covered(at: at(10))                     // 又盖上：之前的锁着不算
        before.recordRSSI(-60, at: at(10)); before.recordRSSI(-60, at: at(11)); before.recordRSSI(-60, at: at(12))
        before.issue(nonce(5), at: at(12))
        expect(!before.edgeArmed && before.presence(.unlocked, nonce: nonce(5), at: at(12.2)) == .refuse(.edgeNotArmed),
               "边沿：盖上之前见过的锁着不算")
        var early = coveredNear(armed: false)
        early.issue(nonce(6), at: at(4))
        early.covered(at: at(5))                       // 重新盖上：之前发的 nonce 作废
        expect(early.presence(.locked, nonce: nonce(6), at: at(5.5)) == .refuse(.unknownNonce) && !early.edgeArmed,
               "边沿：盖上之前发的问询，盖上之后才回的「锁着」也不算")

        // 「现在撤下」：不看边沿，照样要近、要新鲜
        g = coveredNear(armed: false)
        g.issue(nonce(2), at: at(6))
        expect(g.liftNow(nonce: nonce(2), at: at(6.5)) == .lift, "现在撤下：没见过锁着也撤（不看边沿）")
        // 「现在撤下」不看「走近撤下」开关：手机刚报过「关着」，现在撤下照样撤
        g = coveredNear(armed: false)
        g.issue(nonce(7), at: at(5))
        let offReport = g.presence(.off, nonce: nonce(7), at: at(5.2))
        g.issue(nonce(2), at: at(6))
        expect(offReport == .refuse(.toggleOff) && g.liftNow(nonce: nonce(2), at: at(6.5)) == .lift,
               "现在撤下：「走近撤下」关着也撤（不看开关）")
        g = coveredNear(armed: false, rssi: [-75, -72, -78])
        g.issue(nonce(2), at: at(6))
        expect(g.liftNow(nonce: nonce(2), at: at(6.5)) == .refuse(.notNear(median: -75)), "现在撤下：太远 → 不撤")
        g = coveredNear(armed: false)
        g.issue(nonce(2), at: at(6))
        expect(g.liftNow(nonce: nonce(2), at: at(12)) == .refuse(.staleNonce)
               && g.liftNow(nonce: nonce(2), at: at(6.5)) == .refuse(.unknownNonce),
               "现在撤下：过期的、用过的 nonce → 不撤")

        // 没撤时回手机的原因
        expect(LiftGate.resultStatus(for: .notCovered) == .notCovered, "撤下结果：幕布本来就没盖着 → notCovered")
        expect(LiftGate.resultStatus(for: .notNear(median: -80)) == .tooFar
               && LiftGate.resultStatus(for: .noRSSI(samples: 1)) == .tooFar, "撤下结果：不够近 → tooFar")
        expect([LiftGate.Refusal.unknownNonce, .staleNonce, .toggleOff, .phoneLocked, .edgeNotArmed]
                .allSatisfy { LiftGate.resultStatus(for: $0) == .refused }, "撤下结果：nonce 过期 / 用过 / 别的 → refused")
        var down = coveredNear(armed: false)
        down.issue(nonce(2), at: at(6))
        down.uncovered()                               // 幕布已经被键盘撤掉了
        let late = down.liftNow(nonce: nonce(2), at: at(6.5))
        expect(late == .refuse(.notCovered) && {
            if case .refuse(let why) = late { return LiftGate.resultStatus(for: why) == .notCovered }
            return false
        }(), "撤下结果：幕布已经撤了再按「现在撤下」→ 回 notCovered")
    }

    /// 签名、计数、和命令的兼容
    static func wire(_ expect: (Bool, String) -> Void, log: @escaping (String) -> Void, code: String) {
        let store = MemoryPairingStore()
        let mac = PairingAuthority(store: store, log: log)
        mac.openWindow(code: code)
        let phoneID = UUID()
        guard let key = PairingSelfTest.handshake(mac, code: code, phoneID: phoneID).phoneKey,
              case .accepted = mac.handleCommand(PairingCrypto.sealCommand("ping", phoneID: phoneID, counter: 1, key: key)!) else {
            expect(false, "撤下线格式：先配上一台手机")
            return
        }
        // 问询：手机只认它的 Mac 签的
        let n = PairingCrypto.makeNonce()
        let poll = mac.pollMessage(nonce: n, for: phoneID)!
        expect(PairingCrypto.kind(of: poll) == .poll && PairingCrypto.openPoll(poll, phoneID: phoneID, key: key) == n,
               "撤下线格式：问询带签名，手机验过拿到 nonce")
        expect(PairingCrypto.openPoll(poll, phoneID: phoneID, key: SymmetricKey(size: .bits256)) == nil
               && PairingCrypto.openPoll(poll, phoneID: UUID(), key: key) == nil,
               "撤下线格式：别的钥匙 / 别的手机验不过问询")
        expect(PairingCrypto.makeNonce() != PairingCrypto.makeNonce(), "撤下线格式：nonce 每次都不一样")

        // 回答：签名 + 计数（和命令共用）
        let p2 = PairingCrypto.sealPresence(.unlocked, nonce: n, phoneID: phoneID, counter: 2, key: key)!
        var ok = false
        if case .accepted(let a) = mac.handleAnswer(p2) {
            ok = a.kind == .presence(.unlocked) && a.nonce == n && a.counter == 2 && store.load(phoneID)?.lastCounter == 2
        }
        expect(ok, "撤下线格式：签名的「解锁着」收下，计数存成 2")
        expect(answerRejected(mac.handleAnswer(p2), .replay), "撤下线格式：同一条回答再来一次被拒（计数）")
        var flipped = [UInt8](PairingCrypto.sealPresence(.locked, nonce: n, phoneID: phoneID, counter: 3, key: key)!)
        flipped[42] = PairingCrypto.PresenceStatus.unlocked.rawValue       // 把「锁着」改成「解锁着」
        expect(answerRejected(mac.handleAnswer(Data(flipped)), .badSignature), "撤下线格式：改了锁屏状态被拒")
        var swapped = [UInt8](PairingCrypto.sealPresence(.unlocked, nonce: n, phoneID: phoneID, counter: 3, key: key)!)
        swapped[30] ^= 0x01                                                  // 换 nonce
        expect(answerRejected(mac.handleAnswer(Data(swapped)), .badSignature), "撤下线格式：改了 nonce 被拒")
        let forged = PairingCrypto.sealPresence(.unlocked, nonce: n, phoneID: phoneID, counter: 9, key: SymmetricKey(size: .bits256))!
        expect(answerRejected(mac.handleAnswer(forged), .badSignature), "撤下线格式：别的钥匙签的回答被拒")
        let stranger = PairingCrypto.sealLiftNow(nonce: n, phoneID: UUID(), counter: 1, key: key)!
        expect(answerRejected(mac.handleAnswer(stranger), .unknownPhone), "撤下线格式：陌生手机的「现在撤下」被拒")
        let liftOld = PairingCrypto.sealLiftNow(nonce: n, phoneID: phoneID, counter: 2, key: key)!
        expect(answerRejected(mac.handleAnswer(liftOld), .replay), "撤下线格式：「现在撤下」用旧计数被拒")
        expect(store.load(phoneID)?.lastCounter == 2, "撤下线格式：被拒的回答不动计数")
        let cmd3 = PairingCrypto.sealCommand("away", phoneID: phoneID, counter: 3, key: key)!
        _ = mac.handleCommand(cmd3)
        let lift4 = PairingCrypto.sealLiftNow(nonce: n, phoneID: phoneID, counter: 4, key: key)!
        var liftOK = false
        if case .accepted(let a) = mac.handleAnswer(lift4) { liftOK = a.kind == .liftNow && a.counter == 4 }
        expect(liftOK, "撤下线格式：命令和回答共用一个递增计数")
        let presence3 = PairingCrypto.sealPresence(.unlocked, nonce: n, phoneID: phoneID, counter: 3, key: key)!
        expect(answerRejected(mac.handleAnswer(presence3), .replay), "撤下线格式：比命令计数小的回答被拒")

        // 兼容：回答不会被当成命令（老 Mac 的 kind 不认识 0x0C / 0x0D 就丢掉）
        expect(PairingCrypto.kind(of: p2) == .presence && PairingCrypto.kind(of: lift4) == .liftNow
               && [UInt8](p2)[0] == 1 && (try? PairingCrypto.CommandEnvelope(decoding: p2)) == nil,
               "撤下线格式：新消息版本 1、新类型，不会被当成命令")
        expect((try? PairingCrypto.PhoneAnswer(decoding: cmd3)) == nil, "撤下线格式：命令也不会被当成回答")

        // Mac 的结果：签名的
        let result = mac.liftResultMessage(.tooFar, counter: 4, for: phoneID)!
        let opened = PairingCrypto.openLiftResult(result, phoneID: phoneID, key: key)
        expect(opened?.counter == 4 && opened?.status == .tooFar, "撤下线格式：「太远」结果带签名，手机验过")
        let gone = mac.liftResultMessage(.notCovered, counter: 4, for: phoneID)!
        expect(PairingCrypto.openLiftResult(gone, phoneID: phoneID, key: key)?.status == .notCovered
               && [UInt8](gone)[26] == 3 && [UInt8](result)[26] == 1,
               "撤下线格式：「本来就没盖着」是单独的结果（3），带签名")
        var badResult = [UInt8](result)
        badResult[26] = PairingCrypto.LiftStatus.lifted.rawValue
        expect(PairingCrypto.openLiftResult(Data(badResult), phoneID: phoneID, key: key) == nil, "撤下线格式：改过的结果验不过")

        // 端到端：验签 + 判断，重放的整条消息过不了
        var g = LiftGate()
        let now = Date()
        g.covered(at: now)
        for i in 0..<3 { g.recordRSSI(-58, at: now.addingTimeInterval(Double(i))) }
        let n1 = PairingCrypto.makeNonce(), n2 = PairingCrypto.makeNonce()
        g.issue(n1, at: now.addingTimeInterval(2))
        let locked = PairingCrypto.sealPresence(.locked, nonce: n1, phoneID: phoneID, counter: 5, key: key)!
        var d1: LiftGate.Decision?
        if case .accepted(let a) = mac.handleAnswer(locked), case .presence(let st) = a.kind {
            d1 = g.presence(st, nonce: a.nonce, at: now.addingTimeInterval(2.2))
        }
        g.issue(n2, at: now.addingTimeInterval(4))
        let unlocked = PairingCrypto.sealPresence(.unlocked, nonce: n2, phoneID: phoneID, counter: 6, key: key)!
        var d2: LiftGate.Decision?
        if case .accepted(let a) = mac.handleAnswer(unlocked), case .presence(let st) = a.kind {
            d2 = g.presence(st, nonce: a.nonce, at: now.addingTimeInterval(4.2))
        }
        expect(d1 == .refuse(.phoneLocked) && d2 == .lift, "撤下端到端：签名的锁着 → 签名的解锁着 → 撤")
        // 拿新计数重签一条旧 nonce 的回答（钥匙泄露之外做不到，这里只验 nonce 这一层）
        let resent = PairingCrypto.sealPresence(.unlocked, nonce: n2, phoneID: phoneID, counter: 7, key: key)!
        var d3: LiftGate.Decision?
        if case .accepted(let a) = mac.handleAnswer(resent), case .presence(let st) = a.kind {
            d3 = g.presence(st, nonce: a.nonce, at: now.addingTimeInterval(4.5))
        }
        expect(d3 == .refuse(.unknownNonce), "撤下端到端：用过的 nonce 再来（计数对）也不撤")

        // 重放验收：抓一条有效的回答，原样喂两次（验签 + 计数 + 判断全走一遍）
        func feed(_ bytes: Data, _ gate: inout LiftGate, at time: Date) -> (accepted: Bool, decision: LiftGate.Decision?) {
            guard case .accepted(let a) = mac.handleAnswer(bytes) else { return (false, nil) }
            switch a.kind {
            case .presence(let st): return (true, gate.presence(st, nonce: a.nonce, at: time))
            case .liftNow: return (true, gate.liftNow(nonce: a.nonce, at: time))
            }
        }
        for kind in ["Presence", "LiftNow"] {
            var rg = LiftGate()
            let t = Date()
            rg.covered(at: t)
            for i in 0..<3 { rg.recordRSSI(-58, at: t.addingTimeInterval(Double(i))) }
            let c = store.load(phoneID)!.lastCounter
            let na = PairingCrypto.makeNonce(), nb = PairingCrypto.makeNonce()
            rg.issue(na, at: t.addingTimeInterval(2))
            if kind == "Presence" {
                _ = feed(PairingCrypto.sealPresence(.locked, nonce: na, phoneID: phoneID, counter: c + 1, key: key)!, &rg,
                         at: t.addingTimeInterval(2.1))
            }
            rg.issue(nb, at: t.addingTimeInterval(3))
            let captured = kind == "Presence"
                ? PairingCrypto.sealPresence(.unlocked, nonce: nb, phoneID: phoneID, counter: c + 2, key: key)!
                : PairingCrypto.sealLiftNow(nonce: nb, phoneID: phoneID, counter: c + 2, key: key)!
            let first = feed(captured, &rg, at: t.addingTimeInterval(3.2))
            let second = feed(captured, &rg, at: t.addingTimeInterval(3.4))
            let replayReason: Bool = {
                if case .rejected(.replay, _) = mac.handleAnswer(captured) { return true }
                return false
            }()
            let nonceAgain = kind == "Presence"
                ? rg.presence(.unlocked, nonce: nb, at: t.addingTimeInterval(3.5))
                : rg.liftNow(nonce: nb, at: t.addingTimeInterval(3.5))
            expect(first.accepted && first.decision == .lift && !second.accepted && replayReason
                   && nonceAgain == .refuse(.unknownNonce) && store.load(phoneID)?.lastCounter == c + 2,
                   "重放验收（\(kind)）：抓到的有效回答第一次撤下，原样再喂被拒（计数旧），同一个 nonce 也不再认")
        }

        // 撤销之后什么都不认
        _ = mac.revokeAll()
        let after = PairingCrypto.sealPresence(.unlocked, nonce: n, phoneID: phoneID, counter: 20, key: key)!
        expect(answerRejected(mac.handleAnswer(after), .unknownPhone) && mac.pollMessage(nonce: n, for: phoneID) == nil,
               "撤销配对：之后不发问询，回答也不认")
    }

    private static func answerRejected(_ outcome: PairingAuthority.AnswerOutcome, _ reason: PairingAuthority.RejectReason) -> Bool {
        if case .rejected(let r, _) = outcome { return r == reason }
        return false
    }
}

// MARK: - 重连退避

enum ReconnectTests {
    static func run(_ expect: (Bool, String) -> Void) {
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // 翻倍、封顶 5 分钟
        let delays = (0..<8).map { ReconnectBackoff.delay(step: $0, base: 30, cap: reconnectBackoffCap) }
        expect(delays == [30, 60, 120, 240, 300, 300, 300, 300], "重连：30 s 起翻倍，封顶 5 分钟")
        expect(ReconnectBackoff.delay(step: 1000, base: 30, cap: 300) == 300, "重连：退避次数很大也不溢出")
        var b = ReconnectBackoff(base: 2, cap: 30)
        expect(b.fail(at: t0) == 2 && b.fail(at: t0) == 4 && b.holding(at: t0.addingTimeInterval(3))
               && !b.holding(at: t0.addingTimeInterval(4)), "重连：退避到点就放开")
        b.reset()
        expect(!b.holding(at: t0) && b.fail(at: t0) == 2, "重连：清零后从头算")

        // 配过对：早断永远不停手，只退避（30 s → … → 5 min）
        var paired = EarlyDropPolicy()
        var outcomes: [EarlyDropPolicy.Outcome] = []
        for i in 0..<12 { outcomes.append(paired.noteDrop(paired: true, at: t0.addingTimeInterval(Double(i)))) }
        expect(outcomes.prefix(4).allSatisfy { $0 == .keepGoing }, "早断（配过对）：前 4 次照常重连")
        expect(Array(outcomes[4...8]) == [.backoff(30), .backoff(60), .backoff(120), .backoff(240), .backoff(300)],
               "早断（配过对）：第 5 次起退避 30/60/120/240/300 秒")
        expect(!outcomes.contains(.stop), "早断（配过对）：从不硬停")
        expect(outcomes.last == .backoff(300), "早断（配过对）：退避封顶 5 分钟")
        expect(paired.holding(at: t0.addingTimeInterval(12)) && !paired.holding(at: t0.addingTimeInterval(11 + 300)),
               "早断（配过对）：退避到点自己放开")
        paired.reset()
        expect(paired.drops == 0 && !paired.holding(at: t0), "早断：订阅成功 / 唤醒 / 扫到手机后清零")

        // 没配过（配对窗口模式）：第 5 次硬停
        var unpaired = EarlyDropPolicy()
        let u = (0..<5).map { _ in unpaired.noteDrop(paired: false, at: t0) }
        expect(Array(u.prefix(4)) == Array(repeating: .keepGoing, count: 4) && u[4] == .stop, "早断（没配过）：第 5 次硬停")

        // 限时不理：30 s 起翻倍，封顶 5 分钟，到点放出来；认出身份清零
        var ignored = TimedIgnoreList<UUID>()
        let id = UUID()
        let first = ignored.ignore(id, at: t0)
        expect(first == 30 && ignored.contains(id, at: t0.addingTimeInterval(29)) && !ignored.contains(id, at: t0.addingTimeInterval(30)),
               "不理：第一次 30 秒，到点放出来")
        expect(ignored.expire(at: t0.addingTimeInterval(31)) == [id] && ignored.isEmpty, "不理：健康检查把到点的清掉")
        var seq: [TimeInterval?] = []
        for _ in 0..<6 { seq.append(ignored.ignore(id, at: t0)) }
        expect(seq == [60, 120, 240, 300, 300, 300], "不理：再犯就翻倍，封顶 5 分钟，永远是限时的")
        ignored.forgive(id)
        expect(!ignored.contains(id, at: t0) && ignored.ignore(id, at: t0) == 30, "不理：认出身份后从头算")
        let stranger = UUID()
        expect(ignored.ignore(stranger, at: t0, permanent: true) == nil
               && ignored.contains(stranger, at: t0.addingTimeInterval(86_400)), "不理：没配过、不认得的才本次运行不再理")

        // 记得的标识：每台手机只留最近 2 个；老格式读得懂；撤销时删掉
        let phoneA = UUID(), phoneB = UUID()
        let i1 = UUID(), i2 = UUID(), i3 = UUID(), i4 = UUID(), legacy = UUID()
        var known = KnownPeripherals.parse([legacy.uuidString])
        expect(known == [.init(identifier: legacy, phoneID: nil)], "记得的标识：老版本只记标识的也读得懂")
        known = KnownPeripherals.remember(known, identifier: i1, phoneID: phoneA)
        known = KnownPeripherals.remember(known, identifier: i2, phoneID: phoneA)
        known = KnownPeripherals.remember(known, identifier: i4, phoneID: phoneB)
        known = KnownPeripherals.remember(known, identifier: i3, phoneID: phoneA)
        expect(known.filter { $0.phoneID == phoneA }.map(\.identifier) == [i2, i3], "记得的标识：同一台手机只留最近 2 个")
        expect(KnownPeripherals.phoneID(of: i4, in: known) == phoneB, "记得的标识：别的手机的不受影响")
        known = KnownPeripherals.remember(known, identifier: i2, phoneID: phoneA)
        expect(known.filter { $0.phoneID == phoneA }.map(\.identifier) == [i3, i2], "记得的标识：再认出来挪到最新")
        expect(KnownPeripherals.parse(KnownPeripherals.encode(known)) == known, "记得的标识：存了再读一样")
        expect(KnownPeripherals.forget(known, phoneID: phoneA).allSatisfy { $0.phoneID != phoneA }, "记得的标识：撤销的手机删掉")

        // 扫到就连：退避中同一个标识每 30 秒最多连一次；不在退避里照常马上连
        var limiter = DiscoveryConnectLimiter<UUID>()
        let p = UUID(), q = UUID()
        expect((0..<20).allSatisfy { limiter.allow(p, holding: false, at: t0.addingTimeInterval(Double($0) * 0.1)) },
               "扫到就连：不在退避里，每次扫到都马上连")
        expect(limiter.allow(p, holding: true, at: t0), "扫到就连：退避开始后第一次扫到马上连")
        // 每 0.1 秒报一次广播、连了就早断：60 秒里只连得上 2 次
        var connects = 1
        for k in 1..<600 where limiter.allow(p, holding: true, at: t0.addingTimeInterval(Double(k) * 0.1)) { connects += 1 }
        expect(connects == 2, "扫到就连：退避中 60 秒里同一个标识最多连 2 次（不打转），实际 \(connects)")
        expect(limiter.allow(q, holding: true, at: t0.addingTimeInterval(1)), "扫到就连：别的标识不受影响")
        expect(!limiter.allow(p, holding: true, at: t0.addingTimeInterval(59)) && limiter.remaining(p, at: t0.addingTimeInterval(59)) > 0,
               "扫到就连：新的退避开始也不放开（不然每次早断都能马上再连）")
        limiter.succeeded(p)
        expect(limiter.allow(p, holding: true, at: t0.addingTimeInterval(59.5)), "扫到就连：订阅 / 认出身份以后清掉")

        // 挂起的连接：60 秒还没连上就重挂；扫到它在广播却还在连 10 秒以上也重挂
        expect(!PendingConnectPolicy.isStale(pendingSince: t0, discovered: false, at: t0.addingTimeInterval(59)),
               "挂起的连接：不到 60 秒不动")
        expect(PendingConnectPolicy.isStale(pendingSince: t0, discovered: false, at: t0.addingTimeInterval(61)),
               "挂起的连接：超过 60 秒取消重挂")
        expect(!PendingConnectPolicy.isStale(pendingSince: t0, discovered: true, at: t0.addingTimeInterval(9))
               && PendingConnectPolicy.isStale(pendingSince: t0, discovered: true, at: t0.addingTimeInterval(11)),
               "挂起的连接：扫到在广播、卡在连超过 10 秒就重挂")

        // 日志去重：没变的每分钟最多一行，变了马上写
        var throttle = LogThrottle()
        var written = 0
        for k in 0..<60 where throttle.shouldLog("rssi", value: "-60", at: t0.addingTimeInterval(Double(k) * 2), every: 60) { written += 1 }
        expect(written == 2, "日志：每 2 秒一样的 RSSI，2 分钟只写 2 行，实际 \(written)")
        expect(throttle.shouldLog("rssi", value: "-61", at: t0.addingTimeInterval(121), every: 60), "日志：值变了马上写")
        expect(throttle.changed("health", value: "a") && !throttle.changed("health", value: "a") && throttle.changed("health", value: "b"),
               "日志：健康检查只在状态变了时写")
        expect(!LogRotation.needsRotation(size: 2 * 1024 * 1024 - 1) && LogRotation.needsRotation(size: 2 * 1024 * 1024),
               "日志：满 2 MB 轮转")
    }
}
