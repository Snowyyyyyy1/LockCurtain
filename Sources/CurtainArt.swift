// CurtainArt.swift —— 遮罩中间的图案，设置窗口里可以换
//
// 动画图案都是「时间 t → 一帧」的纯函数，用 TimelineView + Canvas 实时画；
// 同一个 t 永远画出同一帧，Tools/EyePreview.swift 靠这一点离线出预览。
// 两只眼还会盯光标，多一个参数 MechEye.Stare，记着光标什么时候动过、眼球最近一跳的起止点。
// 新加一种图案：在 CurtainArt 里加一个 case，补上 title / size / offsetY / draw。

import AppKit
import OpenDirectory
import SwiftUI

enum CurtainArt: String, CaseIterable, Identifiable {
    case mechEye, demonEye, talisman, clock, vault, padlock, custom, none

    var id: Self { self }

    var title: String {
        switch self {
        case .mechEye: "机械眼"
        case .demonEye: "魔瞳"
        case .talisman: "镇宅符"
        case .clock: "机械表"
        case .vault: "保险库"
        case .padlock: "挂锁"
        case .custom: "自定义图片"
        case .none: "不显示"
        }
    }

    /// 在遮罩上的边长（pt）
    var size: CGFloat {
        switch self {
        case .mechEye, .demonEye, .talisman, .clock, .vault, .padlock: 160
        case .custom: 140
        case .none: 0
        }
    }

    /// 中心相对屏幕中心的竖直偏移（负数在上方），和下面的文案留出间距
    var offsetY: CGFloat {
        switch self {
        case .custom: -78
        default: -88
        }
    }

    /// 动画图案的画法；静态图案为 nil。最后一个参数是盯光标的状态，只有两只眼用
    var draw: ((inout GraphicsContext, CGSize, Double, MechEye.Stare?) -> Void)? {
        switch self {
        case .mechEye: MechEye.draw
        case .demonEye: DemonEye.draw
        case .clock: { g, s, t, _ in ClockArt.draw(&g, size: s, t: t) }
        case .talisman: { g, s, t, _ in TalismanArt.draw(&g, size: s, t: t) }
        case .vault: { g, s, t, _ in VaultArt.draw(&g, size: s, t: t) }
        case .padlock: { g, s, t, _ in PadlockArt.draw(&g, size: s, t: t) }
        case .custom, .none: nil
        }
    }

    /// 会不会转过去盯着光标
    var stares: Bool { self == .mechEye || self == .demonEye }

    /// 停在一帧时画哪一刻：镇宅符停在写完、余光还在的时候，魔瞳避开眨眼，不然可能停在一张白纸或一只闭着的眼上
    func stillTime(_ t: Double) -> Double {
        switch self {
        case .talisman: t - t.truncatingRemainder(dividingBy: TalismanArt.cycle) + TalismanArt.still
        case .demonEye: DemonEye.pose(t).open < 0.95 ? t - 0.5 : t
        default: t
        }
    }
}

struct CurtainArtView: View {
    let art: CurtainArt
    /// 设置窗口里没选中的缩略图停在一帧，省得几个一起跑
    var animated = true
    /// 图案中心的屏幕坐标（原点在左下）。遮罩上给出，眼睛就会盯着光标；设置窗口里不给
    var center: CGPoint?
    @State private var stare = MechEye.Stare()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let draw = art.draw {
            // 30 帧够看出动作；遮罩可能挂几个小时，没必要跑满刷新率。系统开了「减弱动态效果」就停在一帧
            let paused = !animated || reduceMotion
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                Canvas { g, size in
                    // 遮罩吞掉鼠标移动，但光标照样动（系统画的），每帧读一次光标位置就够，不用新权限
                    if !paused, art.stares, let center { stare.feed(t, cursor: NSEvent.mouseLocation, eye: center) }
                    draw(&g, size, paused ? art.stillTime(t) : t, paused ? nil : stare)
                }
            }
        } else if art == .custom {
            CustomImageArt()
        }
    }
}

/// 自定义图片：用户选的图，没选就用账户头像。裁成圆形时像系统锁屏的头像，带一圈白边；不裁就按原比例放进方框
private struct CustomImageArt: View {
    @AppStorage(PrefKey.curtainImage) private var data: Data?
    @AppStorage(PrefKey.curtainImageRound) private var round = true

    var body: some View {
        if let img = data.flatMap(NSImage.init(data:)) ?? CurtainImage.accountPicture {
            if round {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: 120, height: 120)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
            } else {
                Image(nsImage: img).resizable().scaledToFit()
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
            }
        }
    }
}

enum CurtainImage {
    /// 最长边缩到这个像素数再存；遮罩上最大 140pt，Retina 下 280px 就够，留一点余量
    static let maxPixels = 512.0

    /// 账户头像（系统设置里给这个用户设的那张），读不到就用通用的账户图标。
    /// 每次建遮罩时重读，用户在系统设置里换了头像不用重启
    static var accountPicture: NSImage? {
        if let node = try? ODNode(session: .default(), type: ODNodeType(kODNodeTypeLocalNodes)),
           let rec = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: [kODAttributeTypeJPEGPhoto]),
           let jpeg = (try? rec.values(forAttribute: kODAttributeTypeJPEGPhoto))?.first as? Data,
           let small = encode(jpeg).flatMap(NSImage.init(data:)) {
            return small
        }
        return NSImage(named: NSImage.userAccountsName)
    }

    /// 读一张图，缩到 maxPixels 以内，带透明的存 PNG、不带的存 JPEG；读不了返回 nil
    static func encode(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,     // 按 EXIF 方向转正
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary)
        else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let alpha = props?[kCGImagePropertyHasAlpha] as? Bool ?? true
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: alpha ? .png : .jpeg, properties: alpha ? [:] : [.compressionFactor: 0.9])
    }
}
