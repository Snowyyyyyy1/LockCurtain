#!/bin/bash
# generate.sh —— 用 Mac 的 Swift 实现重新生成 vectors.json（Windows 版 C# 实现的对照答案）
#
# 只在改了 Sources/CPace.swift / PairingCrypto.swift / LiftGate.swift / PairingAuthority.swift 时需要重跑；
# 输出是确定的（随机量都是固定值），没改协议时重跑应当和仓库里的一字不差。
set -euo pipefail
cd "$(dirname "$0")/../../.."
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
cp Tools/phone-vectors.swift "$D/main.swift"
xcrun swiftc -o "$D/gen" "$D/main.swift" Sources/CPace.swift Sources/PairingCrypto.swift Sources/LiftGate.swift Sources/PairingAuthority.swift
"$D/gen" > windows/Tests/PhoneVectors/vectors.json
echo "wrote windows/Tests/PhoneVectors/vectors.json"
