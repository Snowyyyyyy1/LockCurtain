// UnlockPanel.swift —— 离开模式「回来时：验证」用的解锁面板
//
// 像系统锁屏那样：头像、名字、密码框、触控 ID，全在 LockCurtain 自己的窗口里，
// 不弹任何系统框。密码交给系统在本机核对（OpenDirectory），LockCurtain 不保存、不记录。
// 面板是 nonactivatingPanel：不激活 LockCurtain 也能成为 key 窗口接键盘，agent 的 app 一直在前台。
// 不能靠切前台：macOS 14 起 NSApp.activate() 只是请求，tap 里收到的按键不算用户在操作 LockCurtain，
// 系统直接拒绝（实测 2026-10-29：弹面板 0.3 秒后 appActive=0、key=0，前台还是原来的 app）。

import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import OpenDirectory

@MainActor
final class UnlockPanel: NSPanel {
    /// 按回车、密码框里有内容时回调，密码框随即清空
    var onSubmit: ((String) -> Void)?
    /// Esc
    var onCancel: (() -> Void)?

    private let passwordField = NSSecureTextField(frame: .zero)
    private let hintLabel = NSTextField(labelWithString: "")
    private var touchIDView: LAAuthenticationView?

    /// ctx = nil 表示触控 ID 不可用，只显示密码
    init(contentRect: NSRect, ctx: LAContext?) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone]
        hidesOnDeactivate = false
        contentView?.wantsLayer = true          // 密码错时要抖 contentView 的 layer
        buildContent(ctx: ctx)
    }

    /// borderless 窗口默认不能成为 key，要接键盘得打开
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 吞掉所有 ⌘ / ⌃ 组合键。主菜单里有 ⌘Q 退出、⌘H 隐藏，面板拿到焦点后按下去会退出 LockCurtain、
    /// 露出没锁的桌面。按键等价先问 key window，这里返回 true 主菜单就收不到。
    /// 不带 ⌘ / ⌃ 的照常交给父类，回车、Esc 还要用
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .control]).isEmpty ? super.performKeyEquivalent(with: event) : true
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// 回车：取出密码、立刻清空，交给外面核对（面板里不留明文）
    @objc private func submitFromField() {
        let password = passwordField.stringValue
        passwordField.stringValue = ""
        onSubmit?(password)
    }

    func focusPassword() {
        makeKey()
        _ = makeFirstResponder(passwordField)
    }

    /// 核对密码期间禁止再输入
    func setBusy(_ busy: Bool) { passwordField.isEnabled = !busy }

    /// 密码不对：抖一下，再把焦点放回密码框
    func rejected() {
        if let layer = contentView?.layer {
            let shake = CAKeyframeAnimation(keyPath: "position.x")
            shake.values = [0, -10, 10, -6, 6, 0]
            shake.isAdditive = true
            shake.duration = 0.35
            layer.add(shake, forKey: "shake")
        }
        focusPassword()
    }

    /// 触控 ID 后来用不了（被锁定等）：收起图标，只留密码
    func useTouchID(_ on: Bool) {
        touchIDView?.isHidden = !on
        hintLabel.stringValue = on ? "触控 ID 或输入密码" : "输入密码"
    }

    /// 账户头像：OpenDirectory 里用户记录的 JPEGPhoto（第一个值是 Data），读不到用系统头像图标
    static func userPicture() -> NSImage? {
        if let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication)),
           let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(),
                                         attributes: [kODAttributeTypeJPEGPhoto]),
           let values = try? record.values(forAttribute: kODAttributeTypeJPEGPhoto),
           let data = values.first as? Data,
           let image = NSImage(data: data) {
            return image
        }
        return NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
    }

    private func buildContent(ctx: LAContext?) {
        let stack = NSStackView(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let avatar = NSImageView(frame: .zero)
        avatar.image = Self.userPicture()
        avatar.contentTintColor = NSColor.white.withAlphaComponent(0.85)   // 只对系统头像图标这类模板图生效
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 32
        avatar.layer?.masksToBounds = true
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 64),
            avatar.heightAnchor.constraint(equalToConstant: 64),
        ])

        let name = NSTextField(labelWithString: NSFullUserName())
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.textColor = .white

        let box = NSView(frame: .zero)
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        box.layer?.cornerRadius = 15
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 200),
            box.heightAnchor.constraint(equalToConstant: 30),
        ])
        passwordField.isBordered = false
        passwordField.drawsBackground = false
        passwordField.focusRingType = .none
        passwordField.textColor = .white
        passwordField.font = .systemFont(ofSize: 13)
        // 默认的占位字是深灰，压在深色遮罩上看不见
        passwordField.placeholderAttributedString = NSAttributedString(string: "输入密码", attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.45), .font: NSFont.systemFont(ofSize: 13),
        ])
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.target = self
        passwordField.action = #selector(submitFromField)
        // 高度不定死：文本框的字贴着顶上画，定高 28 会让字偏上；用自身高度再在框里垂直居中
        box.addSubview(passwordField)
        NSLayoutConstraint.activate([
            passwordField.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            passwordField.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            passwordField.widthAnchor.constraint(equalToConstant: 180),
        ])

        let hint = NSStackView(frame: .zero)
        hint.orientation = .horizontal
        hint.spacing = 6
        if let ctx {
            let authView = LAAuthenticationView(context: ctx, controlSize: .small)
            touchIDView = authView
            hint.addArrangedSubview(authView)
        }
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        hintLabel.stringValue = ctx == nil ? "输入密码" : "触控 ID 或输入密码"
        hint.addArrangedSubview(hintLabel)

        for v in [avatar, name, box, hint] { stack.addArrangedSubview(v) }
        guard let content = contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    /// 由系统在本机核对密码：LockCurtain 不保存、不记录密码，只拿到通过与否。
    /// 会阻塞（可能走网络账户），调用方放在后台线程
    nonisolated static func verifyLoginPassword(_ password: String) -> Bool {
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        else { return false }
        return (try? record.verifyPassword(password)) != nil
    }
}
