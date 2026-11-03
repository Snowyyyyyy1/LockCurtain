// PairingCryptoSelfTest.swift —— 配对加密层自测（不碰蓝牙）
//
// 运行（verify.sh 里也有）：
//   cp Tests/PairingCryptoSelfTest.swift /tmp/pc/main.swift
//   xcrun swiftc -o /tmp/pc/t /tmp/pc/main.swift Sources/CPace.swift Sources/PairingCrypto.swift Sources/PairingAuthority.swift Sources/LiftGate.swift Sources/PairingSelfTest.swift
//   /tmp/pc/t
// 另外在登录钥匙串里用一个测试专用的 service 存一条、读回、删掉，验证 Mac 的钥匙串存取。

import CryptoKit
import Foundation

var (lines, passed) = PairingSelfTest.run()

// 钥匙串存取（测试专用 service，跑完删干净）
let keychain = KeychainPairingStore(service: "dev.local.lockcurtain.selftest.pairing")
let id = UUID()
let record = PairingRecord(key: SymmetricKey(size: .bits256), lastCounter: 7)
let saved = keychain.save(record, for: id)
let loaded = keychain.load(id)
let updated = keychain.save(PairingRecord(key: record.key, lastCounter: 8), for: id)
let listed = keychain.allPhoneIDs().contains(id)
let reloaded = keychain.load(id)
keychain.delete(id)
let gone = keychain.load(id) == nil
let ok = saved && loaded == record && updated && listed && reloaded?.lastCounter == 8 && gone
lines.insert("\(ok ? "PASS" : "FAIL")  钥匙串：存、读、改计数、列出、删除", at: lines.count - 1)
if !ok { passed = false }

print(lines.joined(separator: "\n"))
exit(passed ? 0 : 1)
