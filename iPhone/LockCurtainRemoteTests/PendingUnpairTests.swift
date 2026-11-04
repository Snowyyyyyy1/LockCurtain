import CryptoKit
import Foundation
import Testing
@testable import LockCurtain

/// 待撤销（protocol-v3 §5）的记账：挪进来、计数、按哪台中心先试、什么回答才删
struct PendingUnpairTests {
    private let phoneID = UUID()
    private let oldMac = "11111111-1111-1111-1111-111111111111"
    private let otherMac = "22222222-2222-2222-2222-222222222222"

    private func key() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    @Test
    func addKeepsKeyIdentifierAndCounter() {
        var book = PendingUnpairBook()
        let link = PhoneLinkRecord(key: key(), macIdentifier: oldMac, counter: 41)
        let record = book.add(link)
        #expect(book.records == [record])
        #expect(record.key == link.key)
        #expect(record.macIdentifier == oldMac)
        #expect(record.counter == 41)
    }

    @Test
    func reserveCounterIsStrictlyIncreasingPerRecord() {
        var book = PendingUnpairBook()
        let a = book.add(PhoneLinkRecord(key: key(), macIdentifier: oldMac, counter: 7))
        let b = book.add(PhoneLinkRecord(key: key(), macIdentifier: otherMac, counter: 100))
        let first = book.reserveCounter(for: a.id)
        let second = book.reserveCounter(for: a.id)
        let other = book.reserveCounter(for: b.id)
        #expect(first?.counter == 8)
        #expect(second?.counter == 9)
        #expect(other?.counter == 101)
        #expect(book.records.first?.counter == 9)
        #expect(book.reserveCounter(for: UUID()) == nil)
    }

    @Test
    func candidatesPutTheMatchingComputerFirstAndSkipTried() {
        var book = PendingUnpairBook()
        let other = book.add(PhoneLinkRecord(key: key(), macIdentifier: otherMac, counter: 1))
        let old = book.add(PhoneLinkRecord(key: key(), macIdentifier: oldMac, counter: 1))
        #expect(book.candidates(forCentral: oldMac, alreadyTried: []).map(\.id) == [old.id, other.id])
        #expect(book.candidates(forCentral: oldMac, alreadyTried: [old.id]).map(\.id) == [other.id])
        #expect(book.candidates(forCentral: oldMac, alreadyTried: [old.id, other.id]).isEmpty)
    }

    @Test
    func onlyProofOrTheOldComputersAck1Deletes() {
        let record = PendingUnpairRecord(key: key(), macIdentifier: oldMac, counter: 3)
        // 旧钥匙签名的 Ack 0 / Revoke：哪台中心回的都删（签名就是证明）
        #expect(PendingUnpairBook.shouldDelete(.signedAck, record: record, central: otherMac))
        #expect(PendingUnpairBook.shouldDelete(.revoked, record: record, central: otherMac))
        // Ack 1：只有旧电脑那个标识回的才删（别的电脑也会回 Ack 1）
        #expect(PendingUnpairBook.shouldDelete(.unknownPhone, record: record, central: oldMac))
        #expect(!PendingUnpairBook.shouldDelete(.unknownPhone, record: record, central: otherMac))
        // 没回音 / 别的：留着，没有时限
        #expect(!PendingUnpairBook.shouldDelete(.noAnswer, record: record, central: oldMac))
        #expect(!PendingUnpairBook.shouldDelete(.other, record: record, central: oldMac))
    }

    @Test
    func stopsTryingOnACentralOnceItAnsweredForReal() {
        #expect(!PendingUnpairBook.continuesAfter(.signedAck))
        #expect(!PendingUnpairBook.continuesAfter(.revoked))
        #expect(!PendingUnpairBook.continuesAfter(.noAnswer))
        #expect(PendingUnpairBook.continuesAfter(.unknownPhone))
        #expect(PendingUnpairBook.continuesAfter(.other))
    }

    @Test
    func classifyChecksCounterAndThePendingKey() throws {
        let pendingKey = key()
        let currentKey = key()
        let ok = try PairingCrypto.Ack(decoding: PairingCrypto.makeAck(
            phoneID: phoneID, counter: 9, status: .accepted, key: SymmetricKey(data: pendingKey)))
        #expect(PendingUnpairBook.classify(ok, counter: 9, phoneID: phoneID, key: pendingKey) == .signedAck)
        // 别的计数：不是在回这一条
        #expect(PendingUnpairBook.classify(ok, counter: 10, phoneID: phoneID, key: pendingKey) == nil)
        // 现在那把钥匙签的 0（现在那台电脑的回答）不能当旧电脑的证明
        let signedByCurrent = try PairingCrypto.Ack(decoding: PairingCrypto.makeAck(
            phoneID: phoneID, counter: 9, status: .accepted, key: SymmetricKey(data: currentKey)))
        #expect(PendingUnpairBook.classify(signedByCurrent, counter: 9, phoneID: phoneID, key: pendingKey) == .other)
        let unknown = try PairingCrypto.Ack(decoding: PairingCrypto.makeAck(
            phoneID: phoneID, counter: 9, status: .unknownOrBadSignature, key: nil))
        #expect(PendingUnpairBook.classify(unknown, counter: 9, phoneID: phoneID, key: pendingKey) == .unknownPhone)
        let replay = try PairingCrypto.Ack(decoding: PairingCrypto.makeAck(
            phoneID: phoneID, counter: 9, status: .replay, key: nil))
        #expect(PendingUnpairBook.classify(replay, counter: 9, phoneID: phoneID, key: pendingKey) == .other)
    }

    @Test
    func revokeIsMatchedToTheRecordWhoseKeySignedIt() {
        var book = PendingUnpairBook()
        let a = book.add(PhoneLinkRecord(key: key(), macIdentifier: oldMac, counter: 1))
        let b = book.add(PhoneLinkRecord(key: key(), macIdentifier: otherMac, counter: 1))
        let revoke = PairingCrypto.makeRevoke(phoneID: phoneID, key: SymmetricKey(data: b.key))
        #expect(book.recordVerifying(revoke: revoke, phoneID: phoneID)?.id == b.id)
        #expect(book.recordVerifying(revoke: revoke, phoneID: UUID()) == nil)
        let forged = PairingCrypto.makeRevoke(phoneID: phoneID, key: SymmetricKey(data: key()))
        #expect(book.recordVerifying(revoke: forged, phoneID: phoneID) == nil)
        book.remove(b.id)
        #expect(book.records.map(\.id) == [a.id])
    }

    @Test
    func repairingTheSameComputerDropsItsOldRecords() {
        var book = PendingUnpairBook()
        book.add(PhoneLinkRecord(key: key(), macIdentifier: oldMac, counter: 1))
        book.add(PhoneLinkRecord(key: key(), macIdentifier: oldMac, counter: 5))
        let other = book.add(PhoneLinkRecord(key: key(), macIdentifier: otherMac, counter: 1))
        book.removeAll(macIdentifier: oldMac)
        #expect(book.records == [other])
    }

    @Test
    func recordsSurviveACodableRoundTrip() throws {
        var book = PendingUnpairBook()
        book.add(PhoneLinkRecord(key: key(), macIdentifier: oldMac, counter: 12))
        let data = try JSONEncoder().encode(book.records)
        let back = try JSONDecoder().decode([PendingUnpairRecord].self, from: data)
        #expect(back == book.records)
    }
}

/// 保持唤醒那一行的值（copy §16.3）
@MainActor
struct KeepAwakeTextTests {
    @Test
    func remainingTimeRoundsUpToTheMinute() {
        #expect(AppModel.remainingText(80 * 60) == "还剩 1 小时 20 分")
        #expect(AppModel.remainingText(3600) == "还剩 1 小时")
        #expect(AppModel.remainingText(3599) == "还剩 1 小时")
        #expect(AppModel.remainingText(20 * 60 - 30) == "还剩 20 分")
        #expect(AppModel.remainingText(5) == "还剩 1 分")
    }

    @Test
    func valuesForEachMode() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AppModel.keepAwakeText(.off, now: now) == "关")
        #expect(AppModel.keepAwakeText(.always, now: now) == "一直")
        #expect(AppModel.keepAwakeText(.whileApp("Xcode"), now: now) == "Xcode 开着时")
        #expect(AppModel.keepAwakeText(.timed(endsAt: now.addingTimeInterval(4800)), now: now) == "还剩 1 小时 20 分")
        #expect(AppModel.keepAwakeText(.timed(endsAt: now.addingTimeInterval(-1)), now: now) == "关")
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let end = now.addingTimeInterval(7200)
        #expect(AppModel.keepAwakeText(.untilTime(end), now: now) == "到 \(formatter.string(from: end))")
    }

    @Test
    func wireModesMapToStates() {
        #expect(KeepAwakeState(mode: 0, endsAt: 0, appName: "") == .off)
        #expect(KeepAwakeState(mode: 2, endsAt: 0, appName: "") == .always)
        #expect(KeepAwakeState(mode: 4, endsAt: 0, appName: "Xcode") == .whileApp("Xcode"))
        #expect(KeepAwakeState(mode: 1, endsAt: 100, appName: "") == .timed(endsAt: Date(timeIntervalSince1970: 100)))
        #expect(KeepAwakeState(mode: 3, endsAt: 100, appName: "") == .untilTime(Date(timeIntervalSince1970: 100)))
        #expect(KeepAwakeState(mode: 9, endsAt: 0, appName: "") == nil)
        #expect(KeepAwakeChoice.allCases.map(\.command) == ["awake:off", "awake:1h", "awake:2h", "awake:5h", "awake:always"])
    }
}
