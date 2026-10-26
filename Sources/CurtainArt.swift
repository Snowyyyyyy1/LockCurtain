// CurtainArt.swift —— 遮罩中间的图案，设置窗口里可以换
//
// 动画图案都是「时间 t → 一帧」的纯函数，用 TimelineView + Canvas 实时画；
// 同一个 t 永远画出同一帧，Tools/EyePreview.swift 靠这一点离线出预览。
// 新加一种图案：在 CurtainArt 里加一个 case，补上 title / size / offsetY / draw。

import AppKit
import SwiftUI

enum CurtainArt: String, CaseIterable, Identifiable {
    case mechEye, sentryEye, avatar, none

    var id: Self { self }

    var title: String {
        switch self {
        case .mechEye: "机械眼"
        case .sentryEye: "Sentry 之眼"
        case .avatar: "头像"
        case .none: "不显示"
        }
    }

    /// 在遮罩上的边长（pt）
    var size: CGFloat {
        switch self {
        case .mechEye, .sentryEye: 160
        case .avatar: 85
        case .none: 0
        }
    }

    /// 中心相对屏幕中心的竖直偏移（负数在上方），和下面的文案留出间距
    var offsetY: CGFloat {
        switch self {
        case .avatar: -60
        default: -88
        }
    }

    /// 动画图案的画法；静态图案为 nil
    var draw: ((inout GraphicsContext, CGSize, Double) -> Void)? {
        switch self {
        case .mechEye: MechEye.draw
        case .sentryEye: SentryEye.draw
        case .avatar, .none: nil
        }
    }
}

struct CurtainArtView: View {
    let art: CurtainArt
    /// 设置窗口里没选中的缩略图停在一帧，省得几个一起跑
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let draw = art.draw {
            // 30 帧够看出动作；遮罩可能挂几个小时，没必要跑满刷新率。系统开了「减弱动态效果」就停在一帧
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated || reduceMotion)) { tl in
                Canvas { g, size in draw(&g, size, tl.date.timeIntervalSinceReferenceDate) }
            }
        } else if art == .avatar {
            AvatarArt()
        }
    }
}

/// 原来的头像圆圈，仿系统锁屏
private struct AvatarArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 39).strokeBorder(Color.white.opacity(0.92), lineWidth: 2)
            if let img = NSImage(named: NSImage.userAccountsName) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 44, height: 44)
            }
        }
        .frame(width: 85, height: 85)
    }
}

/// Lakr233/Sentry 的 EyeView（MIT）改写成按 t 画：橙红虹膜、放射纹理 20 秒转一圈、瞳孔 2 秒一缩
enum SentryEye {
    /// 画布中心为原点，半径 100 的坐标系
    static func draw(_ g: inout GraphicsContext, size: CGSize, t: Double) {
        let s = min(size.width, size.height) / 200
        g.translateBy(x: size.width / 2, y: size.height / 2)
        g.scaleBy(x: s, y: s)
        g.clip(to: MechEye.circle(100))

        g.stroke(MechEye.circle(100), with: .color(.orange.opacity(0.3)), lineWidth: 8)
        g.fill(MechEye.circle(90), with: .radialGradient(Gradient(colors: [.red.opacity(0.8), .orange, .red.opacity(0.9)]),
                                                         center: .zero, startRadius: 30, endRadius: 90))

        let spin = (t / 20).truncatingRemainder(dividingBy: 1) * 360
        var outer = Path(), inner = Path()
        for k in 0..<36 {
            outer.move(to: .zero); outer.addLine(to: MechEye.polar(80, spin + Double(k) * 10 - 90))
        }
        for k in 0..<24 {
            inner.move(to: .zero); inner.addLine(to: MechEye.polar(50, Double(k) * 15 - 90))
        }
        g.stroke(outer, with: .color(.black.opacity(0.3)), lineWidth: 1)
        g.stroke(inner, with: .color(.red.opacity(0.4)), lineWidth: 0.5)

        // 原版是 easeInOut 2 秒、来回往复，在 1 和 0.8 之间
        let pupil = 25 * (0.9 + 0.1 * cos(t * .pi / 2))
        g.fill(MechEye.circle(pupil), with: .radialGradient(Gradient(colors: [.black, .red.opacity(0.2)]),
                                                            center: .zero, startRadius: pupil * 0.2, endRadius: pupil))
        g.fill(MechEye.circle(4), with: .color(.red.opacity(0.6)))
    }
}
