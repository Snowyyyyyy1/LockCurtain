// RulesPane.swift —— 设置窗口的「规则」页：规则列表 + 编辑器

import AppKit
import SwiftUI

/// Calendar 的 weekday（1 = 周日），按周一开头排
private let weekdaysMondayFirst = [2, 3, 4, 5, 6, 7, 1]

struct RulesPane: View {
    @ObservedObject var store: RuleStore
    @State private var editing: CurtainRule?
    @State private var isNew = false

    var body: some View {
        Form {
            Section {
                if store.rules.isEmpty {
                    Text("还没有规则。").foregroundStyle(.secondary)
                }
                ForEach($store.rules) { $rule in
                    HStack {
                        Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name.isEmpty ? "未命名规则" : rule.name)
                            Text(rule.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("编辑") { isNew = false; editing = rule }
                    }
                    .contextMenu {
                        Button("删除", role: .destructive) { store.rules.removeAll { $0.id == rule.id } }
                    }
                }
            } header: {
                Text("自动进入离开模式")
            } footer: {
                Text("一条规则里开着的条件全部满足时，进入离开模式，并且只在「刚满足」的那一刻触发一次：你回来撤掉遮罩后，要等条件先不成立、再次成立，才会再触发。锁屏期间不触发。")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("新建规则…") {
                    isNew = true
                    var r = CurtainRule(name: "离开 10 分钟")
                    r.idleMinutes = 10
                    editing = r
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule, isNew: isNew) { saved in
                if let i = store.rules.firstIndex(where: { $0.id == saved.id }) { store.rules[i] = saved }
                else { store.rules.append(saved) }
                editing = nil
            } onDelete: {
                store.rules.removeAll { $0.id == rule.id }
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
    }
}

// MARK: - 编辑器

private struct RuleEditor: View {
    @State var rule: CurtainRule
    let isNew: Bool
    let onSave: (CurtainRule) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void
    @State private var newProcess = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("名称", text: $rule.name)
                }
                Section {
                    idleSection
                    processSection
                    timeSection
                    Toggle("接着电源", isOn: $rule.requireACPower)
                } header: {
                    Text("以下条件全部满足时进入离开模式")
                } footer: {
                    if !rule.hasConditions {
                        Text("至少打开一个条件，否则这条规则不会触发。").foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew { Button("删除规则", role: .destructive, action: onDelete) }
                Spacer()
                Button("取消", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(isNew ? "添加" : "保存") { onSave(rule) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 560)
    }

    // 空闲
    @ViewBuilder private var idleSection: some View {
        Toggle("空闲一段时间", isOn: Binding(
            get: { rule.idleMinutes != nil },
            set: { rule.idleMinutes = $0 ? 10 : nil }))
        if let m = rule.idleMinutes {
            Stepper(value: Binding(get: { m }, set: { rule.idleMinutes = $0 }), in: 1...240) {
                Text("键盘和鼠标 \(m) 分钟没动")
            }
        }
    }

    // 进程
    @ViewBuilder private var processSection: some View {
        Toggle("某个 app 或进程在运行", isOn: Binding(
            get: { rule.processes != nil },
            set: { rule.processes = $0 ? [] : nil }))
        if let list = rule.processes {
            ForEach(list, id: \.self) { p in
                HStack {
                    Text(displayName(p))
                    Text(p).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Button { rule.processes?.removeAll { $0 == p } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("进程名，如 claude", text: $newProcess)
                    .onSubmit(addProcess)
                Button("添加", action: addProcess).disabled(newProcess.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu("运行中的 app") {
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                            if let id = app.bundleIdentifier { add(id) }
                        }
                    }
                }
                .fixedSize()
            }
            if list.isEmpty {
                Text("列表里任意一个在运行即满足。命令行工具（没有 bundle ID）填进程名。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // 时间段
    @ViewBuilder private var timeSection: some View {
        Toggle("在某个时间段内", isOn: Binding(
            get: { rule.timeWindow != nil },
            set: { rule.timeWindow = $0 ? .default : nil }))
        if let w = rule.timeWindow {
            HStack {
                DatePicker("从", selection: minuteBinding(\.start), displayedComponents: .hourAndMinute)
                DatePicker("到", selection: minuteBinding(\.end), displayedComponents: .hourAndMinute)
            }
            HStack(spacing: 4) {
                ForEach(weekdaysMondayFirst, id: \.self) { d in
                    let on = w.weekdays.contains(d)
                    Button(Calendar.current.veryShortWeekdaySymbols[d - 1]) {
                        if on { rule.timeWindow?.weekdays.remove(d) } else { rule.timeWindow?.weekdays.insert(d) }
                    }
                    .buttonStyle(.bordered)
                    .tint(on ? .accentColor : .secondary)
                }
            }
            if w.start > w.end {
                Text("跨午夜：后半夜算开始那天。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func addProcess() {
        add(newProcess.trimmingCharacters(in: .whitespaces))
        newProcess = ""
    }

    private func add(_ p: String) {
        guard !p.isEmpty, !(rule.processes ?? []).contains(p) else { return }
        rule.processes = (rule.processes ?? []) + [p]
    }

    private func displayName(_ p: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: p).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: p).map { FileManager.default.displayName(atPath: $0.path) }
            ?? p
    }

    /// TimeWindow 存的是当天第几分钟，DatePicker 要 Date
    private func minuteBinding(_ key: WritableKeyPath<TimeWindow, Int>) -> Binding<Date> {
        Binding(
            get: {
                let m = rule.timeWindow?[keyPath: key] ?? 0
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                rule.timeWindow?[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}

// MARK: - 摘要

extension CurtainRule {
    var summary: String {
        var parts: [String] = []
        if let m = idleMinutes { parts.append("空闲 \(m) 分钟") }
        if let p = processes { parts.append(p.isEmpty ? "进程（未填）" : p.joined(separator: " / ") + " 在运行") }
        if let w = timeWindow {
            func hm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
            let days = w.weekdays.count == 7 ? "每天" : weekdaysMondayFirst.filter(w.weekdays.contains)
                .map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: "、")
            parts.append("\(days) \(hm(w.start))–\(hm(w.end))")
        }
        if requireACPower { parts.append("接着电源") }
        return parts.isEmpty ? "没有条件，不会触发" : parts.joined(separator: "，")
    }
}
