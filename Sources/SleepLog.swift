// SleepLog.swift —— 解析 `pmset -g log` 的电源断言和睡眠/唤醒事件，并读取该命令的输出
//
// 移植自 mac-sleep-doctor 的 Sources/Models/PowerLog.swift（只保留断言与睡眠/唤醒事件）、
// Sources/Clients/PowerLogParser.swift、Sources/Clients/PowerLogClient.swift（readLog 部分，改为同步）。
// 唤醒请求（Wake Requests）、延迟（Delays）和 WakeTime 没有移植。
//
// 日志格式示例（来自 macOS 27.2 上 57k 行的真实日志）：
//
//   2026-09-22 21:36:36 +0800 Assertions          \tPID 3527(nsurlsessiond) Created SystemIsActive "NSURLSessionTask 5A00F064..." 00:00:00  id:0x0xc0000856e [System: ...]
//   2026-09-22 21:54:44 +0800 Sleep               \tEntering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active Using Batt (Charge:79%) 123 secs
//   2026-09-22 21:56:47 +0800 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty bluetooth-pcie/ Using BATT (Charge:79%) 10 secs
//
// 时间戳带有 `+0800` 这样的偏移量。解析时必须使用这个偏移，不能用本机时区：
// 否则跨夏令时切换时，同一块墙上时间会被解析错。

import Foundation

/// 日志中的一条断言记录。
struct AssertionLogEntry: Sendable, Hashable {
    /// 真实日志中出现过的全部动作词。漏掉一个会悄悄破坏统计，所以用测试锁定这个集合。
    enum Action: String, Sendable {
        case created = "Created"
        case released = "Released"
        case summary = "Summary"
        case timedOut = "TimedOut"
        case turnedOn = "TurnedOn"
        case turnedOff = "TurnedOff"
        case clientDied = "ClientDied"
        case capExpired = "CapExpired"

        /// 该动作是否结束断言的一段有效区间。
        var closesInterval: Bool {
            switch self {
            case .released, .timedOut, .turnedOff, .clientDied, .capExpired: true
            case .created, .turnedOn, .summary: false
            }
        }

        /// 该动作是否开始断言的一段有效区间。
        var opensInterval: Bool {
            switch self {
            case .created, .turnedOn: true
            case .released, .timedOut, .turnedOff, .clientDied, .capExpired, .summary: false
            }
        }
    }

    let timestamp: Date
    let pid: pid_t
    let processName: String
    let action: Action
    let type: String
    let name: String
    /// 内核在这一行报告的累计时长（秒）。
    let reportedDuration: Double
    let assertionID: String
}

/// 一次睡眠或唤醒事件。
struct SleepEvent: Sendable, Hashable {
    enum Kind: String, Sendable {
        case sleep = "Sleep"
        case darkWake = "DarkWake"
        case wake = "Wake"

        var label: String {
            switch self {
            case .sleep: "睡眠"
            case .darkWake: "后台唤醒"
            case .wake: "唤醒"
            }
        }
    }

    let timestamp: Date
    let kind: Kind
    let reason: String
    /// 前一段睡眠状态持续的秒数（日志报告了才有）。
    let duration: Double
    let powerSource: String?
    let batteryPercent: Int?

    /// 是否为空闲睡眠（而不是维护性唤醒）。
    var isIdleSleep: Bool {
        reason.hasPrefix("Idle") || reason.hasPrefix("Sleep Service")
            || reason.hasPrefix("Maintenance") || reason == "Sleep"
    }
}

/// 一次解析的结果。
struct SleepLog: Sendable {
    var assertions: [AssertionLogEntry] = []
    var events: [SleepEvent] = []
    var parsedAt: Date = .distantPast
    /// 源文本的行数，用于界面底部的「已解析 N 行」。
    var sourceLineCount: Int = 0

    static let empty = SleepLog()
}

/// 解析 `pmset -g log` 的文本。
enum SleepLogParser {

    // MARK: - 正则
    //
    // 时间戳（`2026-09-22 21:36:36 +0800`）已在循环里单独取出，这些正则只匹配
    // 时间戳之后的部分，但仍保留时间戳格式作为前缀校验。

    /// 断言生命周期。真实日志中出现过的动作词计数：
    /// Created 8002, Released 43595, Summary 3009, TimedOut 341, TurnedOn 137,
    /// TurnedOff 95, ClientDied 32, CapExpired 7。
    private static let assertionRegex = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}\s+Assertions\s+PID (\d+)\(([^)]*)\) (\w+) (\w+) "([^"]*)" (\d+):(\d+):(\d+)\s+id:(\S+)"#
    )

    /// `Entering Sleep state due to 'Reason':... N secs`，原因用单引号括起，可以含空格。
    private static let sleepRegex = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4} .*?Entering (Sleep|DarkWake|Wake) state due to '([^']*)'(.*?)(\d+) secs"#
    )

    /// `DarkWake from Source [flags] : due to <reason> Using BATT (Charge:79%) 10 secs`
    ///
    /// 原因止于字面上的 ` Using `，不能止于斜杠：真实原因里含斜杠（如 `RTP.multi-touch/HID Activity`），
    /// 按 `/` 切分会把它截断。`N secs` 在区间四舍五入为零时会省略。
    private static let darkWakeRegex = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4} .*?DarkWake from [^\[]*\[?[^\]]*\]?\s*:?\s*due to (.*?) Using (\w+) \(Charge:(\d+)%\)(?:\s+(\d+) secs)?"#
    )

    /// `Wake from Source [flags] : due to <reason> Using AC (Charge:65%)`
    /// 同时匹配 `DarkWake to FullWake from ...` 这种变体。
    private static let wakeRegex = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4} .*?(?:DarkWake to FullWake|Wake) from [^\[]*\[?[^\]]*\]?\s*:?\s*due to (.*?) Using (\w+) \(Charge:(\d+)%\)(?:\s+(\d+) secs)?"#
    )

    // MARK: - 入口

    /// 解析全文。since 不为 nil 时，时间早于 since 的行直接跳过。
    static func parse(_ text: String, since: Date? = nil) -> SleepLog {
        var log = SleepLog()
        log.parsedAt = Date()

        var lines = 0
        text.enumerateLines { line, _ in
            lines += 1
            // 一周的日志约 9 万行，这里按字节取固定列：line.count、index(offsetBy:) 要逐个字符数，太慢
            let u8 = line.utf8
            guard u8.count > 46 else { return }

            // 类别列：从第 26 个字节开始，固定 20 个字节，右侧空格填充
            let category = String(decoding: u8.dropFirst(26).prefix(20).prefix { $0 != 32 && $0 != 9 }, as: UTF8.self)
            guard category == "Assertions" || category == "Sleep"
                    || category == "DarkWake" || category == "Wake" else { return }

            // 时间戳是前 25 个字节 `yyyy-MM-dd HH:mm:ss +0800`；解析失败的行直接跳过
            guard let date = timestamp(u8), since.map({ date >= $0 }) ?? true else { return }

            if category == "Assertions" {
                if let entry = parseAssertion(line, date: date) {
                    log.assertions.append(entry)
                }
            } else if let event = parseEvent(line, date: date) {
                log.events.append(event)
            }
        }

        log.sourceLineCount = lines
        return log
    }

    /// `yyyy-MM-dd HH:mm:ss +0800` → Date，按行内的偏移换算，跨夏令时也对。
    /// 手写解析：DateFormatter 每行一次，一周的日志要好几秒
    static func timestamp(_ u8: String.UTF8View) -> Date? {
        let b = Array(u8.prefix(25))
        guard b.count == 25, b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"), b[10] == UInt8(ascii: " "),
              b[13] == UInt8(ascii: ":"), b[16] == UInt8(ascii: ":"), b[19] == UInt8(ascii: " "),
              b[20] == UInt8(ascii: "+") || b[20] == UInt8(ascii: "-") else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            var v = 0
            for i in from..<from + len {
                guard (48...57).contains(b[i]) else { return nil }
                v = v * 10 + Int(b[i] - 48)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let s = num(17, 2),
              let oh = num(21, 2), let om = num(23, 2),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, s < 61 else { return nil }
        // 公历日期 → 1970-01-01 起的天数（Howard Hinnant 的 days_from_civil）
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo > 2 ? mo - 3 : mo + 9) + 2) / 5 + d - 1
        let days = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
        let offset = (oh * 3600 + om * 60) * (b[20] == UInt8(ascii: "-") ? -1 : 1)
        return Date(timeIntervalSince1970: Double(days * 86_400 + h * 3600 + mi * 60 + s - offset))
    }

    // MARK: - 字段解析

    private static func parseAssertion(_ line: String, date: Date) -> AssertionLogEntry? {
        guard let m = assertionRegex.firstMatch(in: line, range: line.fullNSRange),
              let pidRaw = string(line, m, 1),
              let pid = pid_t(pidRaw),
              let proc = string(line, m, 2),
              let actionRaw = string(line, m, 3),
              let type = string(line, m, 4),
              let name = string(line, m, 5),
              let hRaw = string(line, m, 6), let h = Int(hRaw),
              let mnRaw = string(line, m, 7), let mn = Int(mnRaw),
              let sRaw = string(line, m, 8), let s = Int(sRaw),
              let id = string(line, m, 9)
        else { return nil }

        // 未知动作词不丢弃这一行，而是当作 .created 处理（宁可多记，也不漏记）。
        let action = AssertionLogEntry.Action(rawValue: actionRaw) ?? .created
        return AssertionLogEntry(
            timestamp: date,
            pid: pid,
            processName: proc,
            action: action,
            type: type,
            name: name,
            reportedDuration: Double(h * 3600 + mn * 60 + s),
            assertionID: id
        )
    }

    private static func parseEvent(_ line: String, date: Date) -> SleepEvent? {
        // 必须先匹配 DarkWake：`Wake from ` 是 `DarkWake from ` 的子串，更具体的模式要优先。
        if let m = darkWakeRegex.firstMatch(in: line, range: line.fullNSRange),
           let reason = string(line, m, 1),
           let power = string(line, m, 2),
           let charge = string(line, m, 3) {
            return SleepEvent(
                timestamp: date,
                kind: .darkWake,
                reason: reason.trimmingCharacters(in: .whitespaces),
                // `N secs` 在区间为零时省略。
                duration: string(line, m, 4).flatMap(Double.init) ?? 0,
                powerSource: power,
                batteryPercent: Int(charge)
            )
        }

        if let m = wakeRegex.firstMatch(in: line, range: line.fullNSRange),
           let reason = string(line, m, 1),
           let power = string(line, m, 2),
           let charge = string(line, m, 3) {
            return SleepEvent(
                timestamp: date,
                kind: .wake,
                reason: reason.trimmingCharacters(in: .whitespaces),
                duration: string(line, m, 4).flatMap(Double.init) ?? 0,
                powerSource: power,
                batteryPercent: Int(charge)
            )
        }

        if let m = sleepRegex.firstMatch(in: line, range: line.fullNSRange),
           let kind = string(line, m, 1).flatMap(SleepEvent.Kind.init(rawValue:)),
           let reason = string(line, m, 2),
           let secs = string(line, m, 4) {
            return SleepEvent(
                timestamp: date,
                kind: kind,
                reason: reason,
                duration: Double(secs) ?? 0,
                powerSource: nil,
                batteryPercent: nil
            )
        }
        return nil
    }

    // MARK: - 辅助

    private static func string(_ line: String, _ match: NSTextCheckingResult, _ group: Int) -> String? {
        substring(line as NSString, match.range(at: group))
    }

    private static func substring(_ ns: NSString, _ range: NSRange) -> String? {
        guard range.location != NSNotFound, range.length > 0,
              range.location + range.length <= ns.length else { return nil }
        return ns.substring(with: range)
    }
}

extension StringProtocol {
    var fullNSRange: NSRange { NSRange(startIndex..<endIndex, in: self) }
}

/// 读取 `pmset -g log` 的错误。
enum SleepLogError: Error {
    case nonZeroExit(Int32)
    case undecodableOutput(Int)
}

/// 同步运行 `pmset -g log`，返回原始文本。不需要特权，不做缓存。
enum SleepLogReader {
    static func readSystemLog() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "log"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        // 必须先读完 stdout 再 waitUntilExit，否则超过 64 KB 管道缓冲区时会死锁。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SleepLogError.nonZeroExit(process.terminationStatus)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SleepLogError.undecodableOutput(data.count)
        }
        return text
    }
}
