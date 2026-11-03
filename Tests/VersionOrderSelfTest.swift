// VersionOrderSelfTest.swift —— 验证测试版的版本号在 Mac 的自动更新（Sparkle 2）里排得对，
// 以及 release-common.sh 的 vercmp（发版脚本用来判断测试通道该不该覆盖）和它一致
//
// Mac 的 CFBundleVersion / sparkle:version 是去掉「-」的版本号（build.sh、release-common.sh 的 mac_bundle_version）：
// Sparkle 2 的 SUStandardVersionComparator 遇到「-」就截断，1.0.4-beta.3 和 1.0.4 会算同一个版本。
// 这里用的就是 App 里那份 Sparkle.framework 的比较器（先跑一次 ./build.sh 下载）：
//
//   D=$TMPDIR/versionorder; S=.cache/Sparkle-2.10.1; rm -rf $D && mkdir -p $D
//   cp Tests/VersionOrderSelfTest.swift $D/main.swift
//   xcrun swiftc -F $S -framework Sparkle -Xlinker -rpath -Xlinker "$PWD/$S" -o $D/selftest $D/main.swift
//   $D/selftest          （在仓库根目录跑：要 source release-common.sh）
//
// Windows 那边对应 windows/Tests/VersionOrderSelfTest。全部通过返回 0，有失败返回 1。

import Foundation
import Sparkle

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
var total = 0
func check(_ cond: Bool, _ name: String) {
    total += 1
    print((cond ? "  OK   " : "  FAIL ") + name)
    if !cond { failures += 1 }
}

/// build.sh 写进 CFBundleVersion、release-common.sh 写进 sparkle:version 的样子
func bundleVersion(_ v: String) -> String { v.replacingOccurrences(of: "-", with: "") }

let sparkle = SUStandardVersionComparator.default
func sparkleCompare(_ a: String, _ b: String) -> ComparisonResult {
    sparkle.compareVersion(bundleVersion(a), toVersion: bundleVersion(b))
}

/// release-common.sh 的 vercmp
func shellCompare(_ a: String, _ b: String) -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", "source ./release-common.sh && vercmp \"$0\" \"$1\"", a, b]
    let pipe = Pipe()
    p.standardOutput = pipe
    try! p.run()
    p.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 99
}

func older(_ a: String, _ b: String) {
    check(sparkleCompare(a, b) == .orderedAscending && sparkleCompare(b, a) == .orderedDescending,
          "Sparkle: \(bundleVersion(a)) < \(bundleVersion(b))")
    check(shellCompare(a, b) == -1 && shellCompare(b, a) == 1, "vercmp: \(a) < \(b)")
}

older("1.0.4-beta.2", "1.0.4-beta.3")
older("1.0.4-beta.3", "1.0.4")
older("1.0.3", "1.0.4-beta.1")
older("1.0.3", "1.0.4-beta.3")
older("1.0.4-beta.9", "1.0.4-beta.10")
older("1.0.4-beta.3", "1.0.4-rc.1")
older("1.0.4", "1.0.5-beta.1")
older("1.0.4-beta.3", "1.0.5-beta.1")
older("1.0.2", "1.0.3")
older("1.0.3", "1.0.10")
check(sparkleCompare("1.0.4-beta.3", "1.0.4-beta.3") == .orderedSame && shellCompare("1.0.4-beta.3", "1.0.4-beta.3") == 0,
      "1.0.4-beta.3 == 1.0.4-beta.3")
// 为什么要去掉「-」：不去的话 Sparkle 2 认为 1.0.4-beta.3 和 1.0.4 一样，测试版永远升不到正式版
check(sparkle.compareVersion("1.0.4-beta.3", toVersion: "1.0.4") == .orderedSame,
      "Sparkle 2 原样比 1.0.4-beta.3 和 1.0.4 是相等的（所以 CFBundleVersion 不能带「-」）")
check(bundleVersion("1.0.3") == "1.0.3", "正式版号不变")

print(failures == 0 ? "全部通过（\(total) 项）" : "\(failures)/\(total) 项失败")
exit(failures == 0 ? 0 : 1)
