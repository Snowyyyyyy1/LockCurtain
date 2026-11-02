#!/bin/bash
# verify.sh —— 合并前的固定检查：跑全部自测，再完整编译一次，任何一步失败都以非零退出
#
# 要在沙箱外跑：沙箱里 SwiftUI 的宏插件起不来，会报假的编译错误。
# 不包括 Tests/CaptureProbe.swift（会真的盖上遮罩）和 Windows 版。
set -euo pipefail
cd "$(dirname "$0")"

D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

# 用法：selftest <自测名> <一起编译的源文件…>，和各自文件头写的运行方式一致
selftest() {
  local name=$1; shift
  echo "== $name"
  mkdir "$D/$name"
  cp "Tests/$name.swift" "$D/$name/main.swift"   # 顶层代码必须放在 main.swift 里
  xcrun swiftc -o "$D/$name/selftest" "$D/$name/main.swift" "${@/#/Sources/}"
  "$D/$name/selftest"
}

selftest RulesSelfTest Rules.swift
selftest ScreenChangeCoalescerSelfTest ScreenChangeCoalescer.swift
selftest PairingCryptoSelfTest PairingCrypto.swift PairingAuthority.swift PairingSelfTest.swift
selftest SleepLogSelfTest SleepLog.swift IntervalSet.swift SleepLedger.swift SleepBlockers.swift ProcessTable.swift

echo "== build.sh"
./build.sh

echo
echo "verify: 全部通过"
