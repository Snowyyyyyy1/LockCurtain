// PairingSelfTest.swift —— 配对加密层的自测（进程内跑，两端都是纯函数，不碰蓝牙、不碰钥匙串）
//
// 一台 Mac 没法在空中同时当手机和 Mac，所以握手、验签都在内存里两边各走一遍：
//   握手两边算出同一把钥匙；错码被拒；错 5 次码作废；签名命令收下；
//   同一个计数重放被拒；改过的命令被拒；不认识的手机被拒；明文命令被拒；
//   确认收据 / 幕布状态 / 撤销通知的签名；分帧切块再拼回来。
//
// 两个入口：
//   * Tests/PairingCryptoSelfTest.swift（verify.sh 里跑，和本文件 + PairingCrypto + PairingAuthority 一起编）
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

        // 1. 完整握手：两边同一把钥匙，第一条签名命令确认配对
        let store = MemoryPairingStore()
        let mac = PairingAuthority(store: store, log: log)
        mac.openWindow(code: code)
        let (request, secret) = PairingCrypto.makePairRequest(code: code, phoneID: phoneID)
        var phoneKey: SymmetricKey?
        var macKeyMatches = false
        if case .accepted(let reply, let id) = mac.handlePair(request.encoded()), id == phoneID,
           let response = try? PairingCrypto.PairResponse(decoding: reply) {
            phoneKey = PairingCrypto.phoneFinish(response, request: request, secret: secret, code: code)
        }
        expect(phoneKey != nil, "握手：手机核对 Mac 的 tag2 通过")
        expect(mac.code.isEmpty, "握手：码用过一次就作废")
        expect(!mac.isPaired, "握手：没收到签名命令前 Mac 不算配上")

        guard let key = phoneKey else {
            lines.append("结论：握手没成，后面的测不了")
            return (lines, false)
        }
        let ping = PairingCrypto.sealCommand("ping", phoneID: phoneID, counter: 1, key: key)!
        if case .accepted(let cmd, _, let counter, let confirmed, let ackData) = mac.handleCommand(ping) {
            let ack = try? PairingCrypto.Ack(decoding: ackData)
            macKeyMatches = cmd == "ping" && counter == 1 && confirmed
                && ack.map { PairingCrypto.verifyAck($0, key: key) } == true
        }
        expect(macKeyMatches, "握手：两边算出同一把钥匙（Mac 验过手机签的第一条命令，手机验过 Mac 的签名收据）")
        expect(store.load(phoneID)?.key == key && store.load(phoneID)?.lastCounter == 1, "握手：钥匙和计数写进存储")
        expect(mac.isPaired, "握手：确认后 Mac 算配上")

        // 2. 错码被拒
        let wrong = PairingAuthority(store: MemoryPairingStore(), log: log)
        wrong.openWindow(code: code)
        let bad = PairingCrypto.makePairRequest(code: "000000", phoneID: UUID()).request
        if case .rejected(let reply, let left) = wrong.handlePair(bad.encoded()) {
            expect(PairingCrypto.decodePairReject(reply) == .wrongCode && left == 4, "错码：被拒，还剩 4 次")
        } else {
            expect(false, "错码：被拒，还剩 4 次")
        }

        // 3. 错 5 次码作废：之后真码也不行，换码也换不出来
        for _ in 0..<4 { _ = wrong.handlePair(bad.encoded()) }
        expect(wrong.isLocked && wrong.code.isEmpty, "错 5 次：码作废")
        let late = PairingCrypto.makePairRequest(code: code, phoneID: UUID()).request
        if case .noCode = wrong.handlePair(late.encoded()) {
            expect(true, "错 5 次：之后用真码也被拒")
        } else {
            expect(false, "错 5 次：之后用真码也被拒")
        }
        expect(!wrong.refresh(code: "123456"), "错 5 次：「换一个码」换不出新码")
        wrong.openWindow(code: "654321")
        expect(!wrong.isLocked && wrong.attemptsLeft == 5, "错 5 次：重开窗口才有新码")

        // 4. 签名命令收下
        let away = PairingCrypto.sealCommand("away", phoneID: phoneID, counter: 2, key: key)!
        if case .accepted(let cmd, _, let counter, let confirmed, _) = mac.handleCommand(away) {
            expect(cmd == "away" && counter == 2 && !confirmed && store.load(phoneID)?.lastCounter == 2,
                   "签名命令：收下，计数存成 2")
        } else {
            expect(false, "签名命令：收下，计数存成 2")
        }

        // 5. 重放（同一个计数）被拒
        expect(rejected(mac.handleCommand(away), .replay), "重放：同一条命令再来一次被拒")
        let older = PairingCrypto.sealCommand("away", phoneID: phoneID, counter: 1, key: key)!
        expect(rejected(mac.handleCommand(older), .replay), "重放：更小的计数被拒")

        // 6. 改过的命令被拒
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

        // 7. 不认识的手机被拒
        let stranger = PairingCrypto.sealCommand("away", phoneID: UUID(), counter: 1, key: key)!
        expect(rejected(mac.handleCommand(stranger), .unknownPhone), "陌生手机：被拒")

        // 8. 明文命令（老格式）被拒
        expect(rejected(mac.handleCommand(Data("away".utf8)), .malformed), "明文命令：被拒")

        // 9. 收据 / 状态 / 撤销
        let unsignedOK = PairingCrypto.Ack(phoneID: phoneID, counter: 5, status: .accepted, mac: nil)
        expect(!PairingCrypto.verifyAck(unsignedOK, key: key), "收据：不带签名的「收下」不算数")
        let state = mac.stateMessage(closed: true, for: phoneID)!
        expect(PairingCrypto.openState(state, phoneID: phoneID, key: key)?.closed == true, "状态：签名的「盖上」能验过")
        expect(PairingCrypto.openState(state, phoneID: UUID(), key: key) == nil, "状态：发给别的手机的不认")
        let notices = mac.revokeAll()
        expect(notices[phoneID].map { PairingCrypto.verifyRevoke($0, phoneID: phoneID, key: key) } == true,
               "撤销：通知带签名，手机能验过")
        expect(!mac.isPaired && store.load(phoneID) == nil, "撤销：Mac 的钥匙删掉了")
        let afterRevoke = PairingCrypto.sealCommand("away", phoneID: phoneID, counter: 10, key: key)!
        expect(rejected(mac.handleCommand(afterRevoke), .unknownPhone), "撤销：之后这台手机的命令被拒")

        // 10. 手机发「unpair」后 Mac 删钥匙（由 PhonePairing 调 revoke，这里直接走一遍）
        let m2 = PairingAuthority(store: MemoryPairingStore(), log: log)
        m2.openWindow(code: code)
        let (r2, s2) = PairingCrypto.makePairRequest(code: code, phoneID: phoneID)
        if case .accepted(let reply, _) = m2.handlePair(r2.encoded()),
           let resp = try? PairingCrypto.PairResponse(decoding: reply),
           let k2 = PairingCrypto.phoneFinish(resp, request: r2, secret: s2, code: code) {
            _ = m2.handleCommand(PairingCrypto.sealCommand("ping", phoneID: phoneID, counter: 1, key: k2)!)
            let unpair = m2.handleCommand(PairingCrypto.sealCommand("unpair", phoneID: phoneID, counter: 2, key: k2)!)
            if case .accepted(let cmd, let id, _, _, _) = unpair, cmd == "unpair" { _ = m2.revoke(id) }
            expect(!m2.isPaired, "手机解除配对：Mac 收到签名的 unpair 后删钥匙")
        } else {
            expect(false, "手机解除配对：Mac 收到签名的 unpair 后删钥匙")
        }

        // 11. 分帧
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

        // 日志里不许出现码
        expect(!authorityLog.contains { $0.contains(code) }, "日志：不含配对码")

        lines = lines.filter { !$0.hasPrefix("PASS  分帧：每块不超过") } // 每块一行太吵，只留失败的
        lines.append(failures == 0 ? "结论：全通" : "结论：\(failures) 项没通")
        return (lines, failures == 0)
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
