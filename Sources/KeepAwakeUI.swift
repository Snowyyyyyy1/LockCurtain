// KeepAwakeUI.swift —— 保持唤醒在面板、设置页、右键菜单里共用的那几块（A3：同一个菜单，同一份代码）

import AppKit
import SwiftUI

enum KeepAwakeText {
    /// 3 小时 5 分 / 45 分 / 不到 1 分
    static func duration(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        if m < 1 { return "不到 1 分" }
        if m < 60 { return "\(m) 分" }
        return m % 60 == 0 ? "\(m / 60) 小时" : "\(m / 60) 小时 \(m % 60) 分"
    }

    /// 面板和设置页那一行的详情
    static func detail(_ until: KeepAwake.Until) -> String {
        switch until {
        case .forever:
            return "直到你点停止；屏幕照样会熄灭"
        case .date(let end):
            let day = Calendar.current.isDateInToday(end) ? "" : "明天"
            return "到\(day) \(end.formatted(date: .omitted, time: .shortened))，还剩 \(duration(end.timeIntervalSinceNow))"
        case .appQuits(_, let name):
            return "\(name) 退出就结束"
        }
    }

    /// 右键菜单「保持唤醒 ▸」在跑时置灰的那一行（copy v15.1 §17.4）
    static func menuStatus(_ until: KeepAwake.Until, clockTime: Bool) -> String {
        switch until {
        case .forever:
            return "一直开着，点「停止」才停"
        case .date(let end):
            if clockTime { return "到 \(end.formatted(date: .omitted, time: .shortened))，到点自己停" }
            return "\(remaining(end.timeIntervalSinceNow))，到点自己停"
        case .appQuits(_, let name):
            return "\(name) 开着，关掉就停"
        }
    }

    /// 还剩 1 小时 20 分；不到一分钟时是「不到 1 分钟」（copy v15 §17.3，和手机上一样，别出现「还剩 0 分」）
    static func remaining(_ seconds: Double) -> String {
        seconds < 60 ? "不到 1 分钟" : "还剩 \(duration(seconds))"
    }

    /// 「到指定时间…」默认是一小时以后的第一个整点
    static func defaultEndTime() -> Date {
        Calendar.current.nextDate(after: Date().addingTimeInterval(3600), matching: DateComponents(minute: 0),
                                  matchingPolicy: .nextTime) ?? Date()
    }

    /// 选的钟点今天已经过了就是明天
    static func nextOccurrence(of time: Date) -> Date? {
        let hm = Calendar.current.dateComponents([.hour, .minute], from: time)
        return Calendar.current.nextDate(after: Date(), matching: hm, matchingPolicy: .nextTime)
    }

    /// 「某个 app 开着时」能选的 app
    static func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

/// 开始 / 改时长 的菜单项：一直 / 1 小时 / 2 小时 / 5 小时 / 到指定时间… / ─ / 某个 app 开着时 ▸
struct KeepAwakeMenuItems: View {
    @ObservedObject var keepAwake: KeepAwake
    let pickTime: () -> Void

    var body: some View {
        Button("一直") { keepAwake.start(.forever) }
        ForEach([1, 2, 5], id: \.self) { h in
            Button("\(h) 小时") { keepAwake.start(.date(Date().addingTimeInterval(Double(h) * 3600))) }
        }
        Button("到指定时间…", action: pickTime)
        Divider()
        Menu("某个 app 开着时") {
            let apps = KeepAwakeText.runningApps()
            if apps.isEmpty { Text("现在没有") }
            ForEach(apps, id: \.processIdentifier) { app in
                let name = app.localizedName ?? "pid \(app.processIdentifier)"
                Button(name) { keepAwake.start(.appQuits(app.processIdentifier, name: name)) }
            }
        }
    }
}

/// 带边框的下拉按钮：画成和旁边「停止」一样的 .bordered 按钮（同高同样式），点开弹出和 KeepAwakeMenuItems 一样的菜单。
/// SwiftUI 的 Menu / NSPopUpButton 在设置页的分组表单里都会被画成「文字 + 小圆圈」，没有边框，所以这里用按钮 + NSMenu
struct KeepAwakePullDown: View {
    let title: String
    @ObservedObject var keepAwake: KeepAwake
    let pickTime: () -> Void
    @State private var menuOwner: PullDownMenu?

    var body: some View {
        Button {
            let owner = PullDownMenu(keepAwake: keepAwake, pickTime: pickTime)
            menuOwner = owner   // NSMenuItem 的 target 不持有，菜单弹着的时候要有人拿着
            owner.menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .buttonStyle(.bordered)
    }
}

/// 弹出的 NSMenu：一直 / 1 小时 / 2 小时 / 5 小时 / 到指定时间… / ─ / 某个 app 开着时 ▸
@MainActor final class PullDownMenu: NSObject {
    let menu = NSMenu()
    private let keepAwake: KeepAwake
    private let pickTime: () -> Void

    init(keepAwake: KeepAwake, pickTime: @escaping () -> Void) {
        self.keepAwake = keepAwake
        self.pickTime = pickTime
        super.init()
        menu.autoenablesItems = false
        add("一直", to: menu) { $0.start(.forever) }
        for h in [1, 2, 5] {
            add("\(h) 小时", to: menu) { $0.start(.date(Date().addingTimeInterval(Double(h) * 3600))) }
        }
        add("到指定时间…", to: menu) { [pickTime] _ in pickTime() }
        menu.addItem(.separator())
        let appsItem = NSMenuItem(title: "某个 app 开着时", action: nil, keyEquivalent: "")
        let apps = NSMenu()
        apps.autoenablesItems = false
        let list = KeepAwakeText.runningApps()
        if list.isEmpty {
            let none = NSMenuItem(title: "现在没有", action: nil, keyEquivalent: "")
            none.isEnabled = false
            apps.addItem(none)
        }
        for app in list {
            let name = app.localizedName ?? "pid \(app.processIdentifier)"
            let pid = app.processIdentifier
            add(name, to: apps) { $0.start(.appQuits(pid, name: name)) }
        }
        appsItem.submenu = apps
        menu.addItem(appsItem)
    }

    private final class Action: NSObject {
        let run: @MainActor (KeepAwake) -> Void
        init(_ run: @escaping @MainActor (KeepAwake) -> Void) { self.run = run }
    }

    private func add(_ title: String, to menu: NSMenu, _ run: @escaping @MainActor (KeepAwake) -> Void) {
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Action(run)
        menu.addItem(item)
    }

    @objc private func fire(_ item: NSMenuItem) { (item.representedObject as? Action)?.run(keepAwake) }
}

/// 「到指定时间…」选钟点那一行
struct KeepAwakeTimePicker: View {
    @ObservedObject var keepAwake: KeepAwake
    @Binding var endTime: Date
    let done: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("保持唤醒到").font(.system(size: 13))
            DatePicker("", selection: $endTime, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .fixedSize()
            Spacer()
            Button("取消", action: done)
            Button("开始") {
                if let end = KeepAwakeText.nextOccurrence(of: endTime) { keepAwake.start(.date(end), clockTime: true) }
                done()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
