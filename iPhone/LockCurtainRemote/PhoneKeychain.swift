// PhoneKeychain.swift —— 手机端的配对钥匙和身份
//
// 钥匙串（kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly，不进备份、不跟到别的设备）：
//   * account "phoneID"：这台手机的身份 UUID（第一次用时生成）
//   * account "link"   ：共享钥匙 + 这台 Mac 的标识 + 发送计数（每次发命令前先把新计数写进来）
//
// 卸载 App 时 iOS 不一定清钥匙串，所以第一次启动先看 Application Support 里有没有标记文件：
// 没有就把这个 App 能看到的钥匙串条目全删掉，再写标记。删了重装 = 从没配过对。

import Foundation
import Security

struct PhoneLinkRecord: Codable, Equatable {
    var key: Data
    var macIdentifier: String
    var counter: UInt64
}

enum PhoneKeychain {
    static var service: String { (Bundle.main.bundleIdentifier ?? "lockcurtain-remote") + ".pairing" }
    private static let linkAccount = "link"
    private static let phoneIDAccount = "phoneID"
    private static let markerName = "installed.marker"

    // MARK: - 第一次启动清钥匙串

    /// 没有标记文件 = 新装（或删了重装）：清掉所有钥匙串条目，再写标记
    static func wipeIfFreshInstall() {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true) else { return }
        let marker = dir.appendingPathComponent(markerName)
        guard !fm.fileExists(atPath: marker.path) else { return }
        for itemClass in [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassKey,
                          kSecClassCertificate, kSecClassIdentity] {
            SecItemDelete([kSecClass as String: itemClass] as CFDictionary)
        }
        try? Data().write(to: marker, options: .atomic)
    }

    // MARK: - 手机身份

    static func phoneID() -> UUID {
        if let data = read(phoneIDAccount), let text = String(data: data, encoding: .utf8),
           let id = UUID(uuidString: text) {
            return id
        }
        let id = UUID()
        write(Data(id.uuidString.utf8), account: phoneIDAccount)
        return id
    }

    // MARK: - 配对钥匙

    static func loadLink() -> PhoneLinkRecord? {
        read(linkAccount).flatMap { try? JSONDecoder().decode(PhoneLinkRecord.self, from: $0) }
    }

    @discardableResult
    static func saveLink(_ record: PhoneLinkRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        return write(data, account: linkAccount)
    }

    static func deleteLink() {
        SecItemDelete(query(linkAccount) as CFDictionary)
    }

    /// 发命令前调用：计数加一并先写进钥匙串，写成功才返回
    static func reserveNextCounter() -> (record: PhoneLinkRecord, counter: UInt64)? {
        guard var record = loadLink() else { return nil }
        record.counter += 1
        guard saveLink(record) else { return nil }
        return (record, record.counter)
    }

    // MARK: - 底层

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    private static func write(_ data: Data, account: String) -> Bool {
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
