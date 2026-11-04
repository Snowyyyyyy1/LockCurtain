// StatusPanel.swift —— 菜单栏左键弹出的面板：常用操作 + 手机一行 + 保持唤醒和谁在阻止睡眠 + 过去 24 小时
//
// 右键是菜单（撤下幕布、保持唤醒、配对 / 撤销配对、退出 LockCurtain 都在那里，见 AppDelegate.buildStatusMenu）。
// 「手机」那一行（A2）：已连上 / 没连上；没配对时右边是「配对手机」按钮，按钮行里不再有配对。整行点开 设置 › 手机。
// 阻止睡眠的列表放在 TimelineView 里每 2 秒重读一次；面板关掉后视图不再渲染，也就不再读。
// 保持唤醒的剩余时间跟着同一个 TimelineView 刷新。
// 过去 24 小时要跑 pmset（3～4 秒），每次打开面板时在后台读，5 分钟内不重读

import AppKit
import SwiftUI

struct StatusPanelActions {
    let enterAway: () -> Void
    let preview: () -> Void
    let openPairing: () -> Void
    let openPhonePage: () -> Void
    let openSettings: () -> Void
}

@MainActor
final class StatusPanelController {
    private let popover = NSPopover()
    private let ledger = SleepLedgerStore()

    init(actions: StatusPanelActions, keepAwake: KeepAwake, pairing: PhonePairing) {
        popover.behavior = .transient
        // 先收起面板再执行：进离开模式、预览会马上盖住屏幕
        let close = { [popover] in popover.performClose(nil) }
        let host = NSHostingController(rootView: StatusPanelView(
            enterAway: { close(); actions.enterAway() },
            preview: { close(); actions.preview() },
            openPairing: { close(); actions.openPairing() },
            openPhonePage: { close(); actions.openPhonePage() },
            openSettings: { close(); actions.openSettings() },
            ledger: ledger, keepAwake: keepAwake, pairing: pairing))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
    }

    func toggle(from button: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil); return }
        ledger.refreshIfStale()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // 系统开着键盘导航时，第一个按钮会带蓝色焦点环；打开时不聚焦，Tab 照样能进
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
    }
}

/// 暗色下用黄、亮色下用橙：黄字在浅色背景上看不清
private let warmYellow = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemYellow : .systemOrange
})

private struct StatusPanelView: View {
    let enterAway: () -> Void
    let preview: () -> Void
    let openPairing: () -> Void
    let openPhonePage: () -> Void
    let openSettings: () -> Void
    @ObservedObject var ledger: SleepLedgerStore
    @ObservedObject var keepAwake: KeepAwake
    @ObservedObject var pairing: PhonePairing

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(action: enterAway) { Label("盖上幕布", systemImage: "figure.walk.departure") }
                    .buttonStyle(.borderedProminent)
                Button("预览幕布", action: preview)
                Spacer()
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("设置…")
            }
            PhoneRow(pairing: pairing, openPairing: openPairing, openPhonePage: openPhonePage)
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                SleepBlockersCard(snapshot: SleepBlockers.snapshot(), keepAwake: keepAwake)
            }
            SleepHistoryCard(store: ledger)
        }
        .padding(14)
        .frame(width: 360)
    }
}

/// 「手机」一行（A2）
private struct PhoneRow: View {
    @ObservedObject var pairing: PhonePairing
    let openPairing: () -> Void
    let openPhonePage: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone").font(.system(size: 16)).frame(width: 20)
            Text("手机").font(.system(size: 13))
            Spacer()
            if pairing.phones.isEmpty {
                Button("配对手机", action: openPairing).controlSize(.small)
            } else {
                let on = pairing.anyPhoneConnected
                HStack(spacing: 5) {
                    Circle().fill(on ? Color(nsColor: .systemGreen) : Color(nsColor: .systemGray)).frame(width: 8, height: 8)
                    Text(on ? "已连上" : "没连上").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .frame(height: 28)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: openPhonePage)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct SleepBlockersCard: View {
    let snapshot: SleepBlockersSnapshot
    @ObservedObject var keepAwake: KeepAwake
    @State private var pickingTime = false
    @State private var endTime = Date()

    /// LockCurtain 自己的断言由上面保持唤醒那一行代表，不再重复列
    private var rows: [SleepBlocker] { snapshot.others }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(warmYellow)
                    .frame(width: 30, height: 30)
                    .background(warmYellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                Text("阻止睡眠")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(warmYellow)
                Spacer()
                if !keepAwake.isOn && !pickingTime { keepAwakeMenu }
            }
            if pickingTime { timePicker }
            if let until = keepAwake.until { keepAwakeRow(until) }
            if rows.isEmpty && !keepAwake.isOn {
                Text("没有 app 在阻止睡眠。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Image(nsImage: row.icon)
                        .resizable()
                        .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !row.reason.isEmpty {
                            Text(row.reason)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    KindBadge(kind: row.kind)
                }
                .help(row.reason)
            }
            if snapshot.systemServices > 0 {
                Text("另有 \(snapshot.systemServices) 个系统服务也在阻止睡眠。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    private var keepAwakeMenu: some View {
        Menu("保持唤醒") {
            KeepAwakeMenuItems(keepAwake: keepAwake) {
                endTime = KeepAwakeText.defaultEndTime()
                pickingTime = true
            }
        }
        .fixedSize()
        .help("不盖幕布，只让电脑不睡；屏幕照样会熄灭")
    }

    private var timePicker: some View {
        KeepAwakeTimePicker(keepAwake: keepAwake, endTime: $endTime) { pickingTime = false }
    }

    private func keepAwakeRow(_ until: KeepAwake.Until) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("LockCurtain 保持唤醒")
                    .font(.system(size: 13, weight: .medium))
                Text(Self.detail(until))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("停止") { keepAwake.stop() }
        }
    }

    private static func detail(_ until: KeepAwake.Until) -> String { KeepAwakeText.detail(until) }
}

private struct KindBadge: View {
    let kind: SleepBlockKind

    var body: some View {
        let (text, color) = kind == .display ? ("显示器", Color(nsColor: .systemBlue)) : ("系统", warmYellow)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.18), in: Capsule())
    }
}

// MARK: - 过去 24 小时

private let sleepColor = Color(nsColor: .systemIndigo)
private let activeColor = Color(nsColor: .systemGreen).opacity(0.75)

private func duration(_ seconds: Double) -> String { KeepAwakeText.duration(seconds) }

private struct SleepHistoryCard: View {
    @ObservedObject var store: SleepLedgerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("过去 24 小时").font(.system(size: 13, weight: .semibold))
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
            }
            if let l = store.ledger {
                VStack(spacing: 4) {
                    HistoryBar(ledger: l).frame(height: 12)
                    HStack { Text("24 小时前"); Spacer(); Text("12 小时前"); Spacer(); Text("现在") }
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                HStack(alignment: .top, spacing: 18) {
                    LegendItem(color: sleepColor, label: "睡眠", seconds: l.asleep.totalDuration)
                    LegendItem(color: activeColor, label: "在用", seconds: l.active.totalDuration)
                    LegendItem(color: warmYellow, label: "被阻止", seconds: l.blocked.totalDuration)
                        .help("醒着、没人在用，但有程序不让它睡")
                }
                if !l.apps.isEmpty {
                    Text("被谁阻止").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(l.apps.prefix(5)) { c in
                    let app = SleepBlockers.display(processName: c.id)
                    HStack(spacing: 8) {
                        Image(nsImage: app.icon).resizable().frame(width: 18, height: 18)
                        Text(app.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(duration(c.seconds)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if !l.services.isEmpty {
                    let names = l.services.prefix(2).map(\.id).joined(separator: "、") + (l.services.count > 2 ? " 等" : "")
                    Text("系统服务 \(duration(l.servicesTotal))（\(names)）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if store.error != nil {
                // D12：读不到时能再读一次（错误细节写日志，不上界面）
                HStack(spacing: 6) {
                    Text("没读到。").font(.callout).foregroundStyle(.secondary)
                    Button("再读一次") { store.refresh() }.controlSize(.small)
                }
            } else {
                Text("正在读取电源日志…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 24 小时的时间条：底色是醒着但没人用、也没被拦着（在等空闲计时）
private struct HistoryBar: View {
    let ledger: SleepLedger

    var body: some View {
        Canvas { ctx, size in
            let w = ledger.window
            func paint(_ set: IntervalSet, _ color: Color) {
                for iv in set.intervals {
                    let x0 = CGFloat((iv.start - w.start) / w.duration) * size.width
                    let x1 = CGFloat((iv.end - w.start) / w.duration) * size.width
                    ctx.fill(Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)), with: .color(color))
                }
            }
            paint(ledger.asleep, sleepColor)
            paint(ledger.active, activeColor)
            paint(ledger.blocked, warmYellow)
        }
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

private struct LegendItem: View {
    let color: Color
    let label: String
    let seconds: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(duration(seconds)).font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .lineLimit(1)
    }
}
