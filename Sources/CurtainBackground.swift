// CurtainBackground.swift —— 遮罩的背景：当前壁纸、模糊壁纸、纯黑，或者程序画的几张图
//
// 程序画的图是静态的：每次显示遮罩时按屏幕的像素尺寸在后台线程画一张贴上去，不跑动画，
// 遮罩挂几个小时也不多耗电。用 Core Graphics 画（能在后台线程跑），坐标是屏幕的点、y 向下；
// 随机数用 MechEye.rand，同样尺寸的屏每次画出来都一样。
// 精致度照着图案来：光从左上方来，有层次、有辉光，中间留暗，让图案和文案看得清。

import AppKit
import CoreImage

enum CurtainBackground: String, CaseIterable, Identifiable {
    case wallpaper, blurred, black, starfield, hills, carbon

    var id: Self { self }

    var title: String {
        switch self {
        case .wallpaper: "壁纸"
        case .blurred: "模糊壁纸"
        case .black: "纯黑"
        case .starfield: "星空"
        case .hills: "远山"
        case .carbon: "碳纤维"
        }
    }

    /// 背景要用抓到的壁纸
    var usesWallpaper: Bool { self == .wallpaper || self == .blurred }

    /// 叠在背景上的黑色压暗层；程序画的图本身够暗，不再压
    var dim: CGFloat {
        switch self {
        case .wallpaper: 0.28
        case .blurred: 0.35
        default: 0
        }
    }

    /// 把抓到的壁纸处理成这个背景要的样子。模糊壁纸先缩到 1/4 再模糊，图层会放大回屏幕尺寸
    func prepare(_ wallpaper: CGImage) -> CGImage {
        guard self == .blurred else { return wallpaper }
        let small = CIImage(cgImage: wallpaper).transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        let soft = small.clampedToExtent()
            .applyingGaussianBlur(sigma: 24)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.15])
            .cropped(to: small.extent)
        return ciContext.createCGImage(soft, from: small.extent) ?? wallpaper
    }

    /// 程序画的背景，size 是屏幕的点、scale 是每点几个像素；壁纸类和纯黑返回 nil
    func render(size: CGSize, scale: CGFloat) -> CGImage? {
        let draw: (CGContext, CGSize, CGFloat) -> Void
        switch self {
        case .starfield: draw = Starfield.draw
        case .hills: draw = Hills.draw
        case .carbon: draw = Carbon.draw
        case .wallpaper, .blurred, .black: return nil
        }
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0, let ctx = bitmap(w, h) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        draw(ctx, size, scale)
        return ctx.makeImage()
    }
}

// MARK: - 共用的小工具

private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
/// CIContext 建一次很贵，所有模糊共用一个（线程安全）
private let ciContext = CIContext()

private func bitmap(_ w: Int, _ h: Int) -> CGContext? {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
}

private func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [CGFloat(hex >> 16 & 0xff) / 255, CGFloat(hex >> 8 & 0xff) / 255,
                                           CGFloat(hex & 0xff) / 255, a])!
}

private func gradient(_ stops: [(UInt32, CGFloat)], _ at: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: stops.map { color($0.0, $0.1) } as CFArray, locations: at)!
}

private func rand(_ i: Int, _ salt: UInt64) -> CGFloat { CGFloat(MechEye.rand(i, salt)) }

/// 近似正态的随机数，-1…1，越靠 0 越多
private func bell(_ i: Int, _ salt: UInt64) -> CGFloat {
    (rand(i, salt) + rand(i, salt &+ 1000) + rand(i, salt &+ 2000) - 1.5) / 1.5
}

/// 一维值噪声叠几层（fbm），0…1
private func fbm(_ x: CGFloat, _ salt: UInt64, octaves: Int = 5) -> CGFloat {
    var v: CGFloat = 0, amp: CGFloat = 0.5, f: CGFloat = 1, total: CGFloat = 0
    for o in 0..<octaves {
        let p = x * f, i = Int(floor(p)), t = p - floor(p)
        let a = rand(i, salt &+ UInt64(o) &* 77), b = rand(i + 1, salt &+ UInt64(o) &* 77)
        v += amp * (a + (b - a) * t * t * (3 - 2 * t))
        total += amp; f *= 2.03; amp *= 0.5
    }
    return v / total
}

/// 一团柔光：中心不透明度 a、边缘为 0，可以拉成椭圆再转个角度
private func glow(_ ctx: CGContext, at c: CGPoint, r: CGFloat, _ hex: UInt32, _ a: CGFloat,
                  stretch: CGFloat = 1, angle: CGFloat = 0) {
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.rotate(by: angle)
    ctx.scaleBy(x: stretch, y: 1)
    ctx.drawRadialGradient(gradient([(hex, a), (hex, a * 0.4), (hex, 0)], [0, 0.4, 1]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r, options: [])
    ctx.restoreGState()
}

/// 四角压暗
private func vignette(_ ctx: CGContext, _ s: CGSize, _ a: CGFloat) {
    let c = CGPoint(x: s.width / 2, y: s.height / 2)
    ctx.drawRadialGradient(gradient([(0, 0), (0, 0), (0, a)], [0, 0.5, 1]), startCenter: c, startRadius: 0,
                           endCenter: c, endRadius: hypot(s.width, s.height) / 2, options: [.drawsAfterEndLocation])
}

/// 屏幕中间（图案和文案那块）压暗一点
private func calmCenter(_ ctx: CGContext, _ s: CGSize, _ hex: UInt32, _ a: CGFloat) {
    glow(ctx, at: CGPoint(x: s.width / 2, y: s.height / 2 - 25), r: min(s.height * 0.34, s.width * 0.3), hex, a, stretch: 1.5)
}

// MARK: - 星空

/// 星空：一条银河从左下斜到右上、从图案上方经过，暖色的核心偏左，两边泛蓝紫，中线有暗尘带；
/// 底下撒满小星，几十颗亮星带光晕，最亮的几颗有十字星芒
private enum Starfield {
    static func draw(_ ctx: CGContext, _ s: CGSize, _ scale: CGFloat) {
        let W = s.width, H = s.height
        ctx.drawLinearGradient(gradient([(0x02040A, 1), (0x060A18, 1), (0x0C1330, 1)], [0, 0.55, 1]),
                               start: .zero, end: CGPoint(x: 0, y: H), options: [])

        let angle: CGFloat = -0.40
        let dir = CGVector(dx: cos(angle), dy: sin(angle)), nrm = CGVector(dx: -sin(angle), dy: cos(angle))
        let o = CGPoint(x: W * 0.5, y: H * 0.30), L = hypot(W, H) * 0.62, bw = H * 0.15
        func at(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: o.x + dir.dx * u + nrm.dx * v, y: o.y + dir.dy * u + nrm.dy * v)
        }
        /// 银河沿长度方向的亮度：核心在左下段，再叠一点起伏让它成团
        func bright(_ u: CGFloat) -> CGFloat {
            0.35 + 0.65 * exp(-pow((u + L * 0.28) / (L * 0.32), 2)) + 0.25 * (fbm(u / L * 4 + 10, 5) - 0.5)
        }

        // 银河的光：先铺一层宽的蓝紫色，再沿带子撒一堆小团，中间暖、两边冷，成团成絮
        ctx.setBlendMode(.screen)
        for i in 0..<90 {
            let u = (rand(i, 1) * 2 - 1) * L, v = bell(i, 2) * bw * 1.2
            glow(ctx, at: at(u, v), r: H * (0.1 + 0.1 * rand(i, 3)), rand(i, 4) < 0.6 ? 0x4A63D8 : 0x8A55C8,
                 0.05 * bright(u), stretch: 1.8, angle: angle)
        }
        for i in 0..<620 {
            let u = (rand(i, 5) * 2 - 1) * L, g = bell(i, 6), v = g * bw
            let warm = abs(g) < 0.35
            let hex: UInt32 = warm ? (rand(i, 7) < 0.5 ? 0xF4DDBA : 0xE9C9A4) : (rand(i, 7) < 0.6 ? 0x7C96FF : 0xB27FE8)
            let r = H * (0.018 + 0.05 * rand(i, 8)) * (1 - 0.4 * abs(g))
            glow(ctx, at: at(u, v), r: r, hex, (warm ? 0.11 : 0.07) * bright(u), stretch: 1.5, angle: angle + 0.3 * (rand(i, 9) - 0.5))
        }
        // 核心：偏左下的一大团暖光
        let core = -L * 0.28
        for i in 0..<70 {
            let u = core + bell(i, 15) * L * 0.18, v = bell(i, 16) * bw * 0.45
            glow(ctx, at: at(u, v), r: H * (0.03 + 0.06 * rand(i, 17)), 0xFFD9A6, 0.09, stretch: 1.4, angle: angle)
        }
        // 暗尘带：沿弯曲的中线压掉一部分光，主带两边还分出几缕
        ctx.setBlendMode(.normal)
        for i in 0..<320 {
            let u = (rand(i, 11) * 2 - 1) * L * 0.9
            let lane = rand(i, 14) < 0.7 ? 0 : (rand(i, 14) < 0.85 ? 0.35 : -0.4)
            let v = bw * (lane + 0.12 * sin(u / L * 7 + lane * 4) + 0.12 * bell(i, 12))
            glow(ctx, at: at(u, v), r: H * (0.006 + 0.022 * rand(i, 13)), 0x03050C, 0.34 * bright(u) * (lane == 0 ? 1 : 0.7),
                 stretch: 2.8, angle: angle + 0.4 * (rand(i, 18) - 0.5))
        }

        // 小星：一半均匀撒，其余挤在银河里，银河里的更小更密
        let n = Int(W * H / 300)
        for i in 0..<(n * 5 / 2) {
            let p = i < n ? CGPoint(x: rand(i, 21) * W, y: rand(i, 22) * H)
                          : at((rand(i, 23) * 2 - 1) * L, bell(i, 24) * bw * 0.9)
            let m = pow(rand(i, 26), 6)
            let r = 0.28 + 0.75 * m
            let a = min(1, 0.18 + 0.55 * pow(rand(i, 27), 2.5) + 0.3 * m)
            let t = rand(i, 28)
            ctx.setFillColor(color(t < 0.12 ? 0xFFD6A8 : t < 0.38 ? 0xC2D4FF : 0xFFFFFF, a))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }

        // 亮星：光晕 + 白核，最亮的几颗带十字星芒
        ctx.setBlendMode(.screen)
        for i in 0..<34 {
            let p = CGPoint(x: rand(i, 31) * W, y: rand(i, 32) * H)
            let m = rand(i, 33), hex: UInt32 = rand(i, 34) < 0.3 ? 0xFFDDB8 : 0xC9D9FF
            glow(ctx, at: p, r: 5 + 11 * m, hex, 0.22 + 0.25 * m)
            let r = 0.8 + 0.7 * m
            ctx.setFillColor(color(0xFFFFFF, 0.95))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            if i < 7 {
                for k in 0..<4 {
                    let a = CGFloat(k) * .pi / 2 + 0.12, len = 10 + 22 * m
                    let e = CGPoint(x: p.x + cos(a) * len, y: p.y + sin(a) * len)
                    ctx.saveGState()
                    ctx.move(to: p); ctx.addLine(to: e)
                    ctx.setLineWidth(0.8); ctx.replacePathWithStrokedPath(); ctx.clip()
                    ctx.drawLinearGradient(gradient([(hex, 0.75), (hex, 0)]), start: p, end: e, options: [])
                    ctx.restoreGState()
                }
            }
        }
        ctx.setBlendMode(.normal)
        calmCenter(ctx, s, 0x02040A, 0.5)
        vignette(ctx, s, 0.55)
    }
}

// MARK: - 远山

/// 远山：月夜的水墨群山。五层山脊由远到近、由淡到黑，每层山顶浓、往下化进雾里；
/// 中间低两边高，图案和文案落在山谷上方的夜空里。右上角一轮月亮，云丝从前面飘过
private enum Hills {
    static func draw(_ ctx: CGContext, _ s: CGSize, _ scale: CGFloat) {
        let W = s.width, H = s.height
        ctx.drawLinearGradient(gradient([(0x05080F, 1), (0x0B111E, 1), (0x1A2335, 1)], [0, 0.5, 1]),
                               start: .zero, end: CGPoint(x: 0, y: H * 0.78), options: [.drawsAfterEndLocation])

        // 月亮：大片冷光、贴边一圈亮晕，月面左上亮、带几块月海
        let mc = CGPoint(x: W * 0.8, y: H * 0.2), mr = H * 0.042
        ctx.setBlendMode(.screen)
        glow(ctx, at: mc, r: mr * 11, 0x7F95BF, 0.16)
        glow(ctx, at: mc, r: mr * 2.4, 0xD5DDEC, 0.28)
        ctx.setBlendMode(.normal)
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: mc.x - mr, y: mc.y - mr, width: 2 * mr, height: 2 * mr))
        ctx.clip()
        ctx.drawRadialGradient(gradient([(0xFBF7EA, 1), (0xE6E0CB, 1), (0xBDB59D, 1)], [0, 0.65, 1]),
                               startCenter: CGPoint(x: mc.x - mr * 0.35, y: mc.y - mr * 0.35), startRadius: 0,
                               endCenter: mc, endRadius: mr * 1.05, options: [.drawsAfterEndLocation])
        for i in 0..<7 {
            let p = CGPoint(x: mc.x + (rand(i, 41) - 0.45) * mr * 1.3, y: mc.y + (rand(i, 42) - 0.45) * mr * 1.3)
            glow(ctx, at: p, r: mr * (0.18 + 0.3 * rand(i, 43)), 0x9A927A, 0.3)
        }
        ctx.restoreGState()
        for i in 0..<5 {
            let p = CGPoint(x: mc.x + (rand(i, 44) - 0.6) * mr * 9, y: mc.y + (rand(i, 45) - 0.2) * mr * 2.4)
            glow(ctx, at: p, r: mr * (1.6 + 2 * rand(i, 46)), 0x8792A8, 0.09, stretch: 4.5)
        }

        // 山：(山脚高度, 最高峰, 山顶颜色, 峰数)。每层由几座尖峰叠成，左右坡宽窄不一，
        // 坡上再叠随高度变大的起伏，越高越嶙峋；越靠两边峰越高，中间留出山谷
        let layers: [(base: CGFloat, amp: CGFloat, ink: UInt32, peaks: Int)] = [
            (0.72, 0.17, 0x2E3A50, 4),
            (0.78, 0.24, 0x202A3C, 5),
            (0.85, 0.27, 0x141B29, 4),
            (0.92, 0.25, 0x0A0E17, 5),
            (0.99, 0.21, 0x04060B, 6),
        ]
        let mist: UInt32 = 0x35425C
        for (li, l) in layers.enumerated() {
            let salt = UInt64(50 + li * 7)
            let peaks = (0..<l.peaks).map { k -> (c: CGFloat, h: CGFloat, wl: CGFloat, wr: CGFloat) in
                let c = (CGFloat(k) + 0.15 + 0.7 * rand(k, salt)) / CGFloat(l.peaks) * W * 1.1 - W * 0.05
                let edge = pow(min(abs(c / W - 0.5) * 2, 1), 1.3)
                let w = W / CGFloat(l.peaks) * 0.85
                return (c, H * l.amp * (0.3 + 0.7 * edge) * (0.65 + 0.35 * rand(k, salt + 1)),
                        w * (0.6 + 0.6 * rand(k, salt + 2)), w * (0.6 + 0.6 * rand(k, salt + 3)))
            }
            let ridge = CGMutablePath()
            ridge.move(to: CGPoint(x: 0, y: H))
            var top = H
            var x: CGFloat = 0
            while x <= W + 2 {
                var h: CGFloat = 0
                for p in peaks {
                    let d = (x - p.c) / (x < p.c ? p.wl : p.wr)
                    if abs(d) < 1 { h = max(h, p.h * pow(1 - abs(d), 1.35)) }
                }
                h *= 1 + 0.32 * (fbm(x / W * 9, salt + 8) - 0.5) + 0.12 * (fbm(x / W * 38, salt + 9) - 0.5)
                let y = H * l.base - h
                top = min(top, y)
                ridge.addLine(to: CGPoint(x: x, y: y))
                x += 2
            }
            ridge.addLine(to: CGPoint(x: W, y: H))
            ridge.closeSubpath()

            // 峰顶浓、往下淡进雾里
            ctx.saveGState()
            ctx.addPath(ridge)
            ctx.clip()
            ctx.drawLinearGradient(gradient([(l.ink, 1), (l.ink, 1), (mist, 1)], [0, 0.3, 1]),
                                   start: CGPoint(x: 0, y: top),
                                   end: CGPoint(x: 0, y: H * (l.base + 0.02)), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
            // 山脊一道墨线，近处的浓
            ctx.addPath(ridge)
            ctx.setStrokeColor(color(0x020306, 0.15 + 0.1 * CGFloat(li)))
            ctx.setLineWidth(1.1)
            ctx.strokePath()

            // 山脚一层雾，盖住下一层山的接缝
            if li < layers.count - 1 {
                let y = H * (l.base + 0.01)
                ctx.drawLinearGradient(gradient([(mist, 0), (mist, 0.55), (mist, 0)]),
                                       start: CGPoint(x: 0, y: y - H * 0.06), end: CGPoint(x: 0, y: y + H * 0.05), options: [])
            }
        }
        calmCenter(ctx, s, 0x05080F, 0.35)
        vignette(ctx, s, 0.5)
    }
}

// MARK: - 碳纤维

/// 碳纤维：2×2 斜纹编织，每股纤维横截面中间亮两边暗，沿长度中间鼓起、两头钻到下面去；
/// 横股和竖股反光不一样，从左上到右下慢慢互换明暗；表面一层清漆，左上方一片柔和的高光
private enum Carbon {
    /// 一格的边长（点）
    static let cell: CGFloat = 7

    static func draw(_ ctx: CGContext, _ s: CGSize, _ scale: CGFloat) {
        let W = s.width, H = s.height, t = cell * 4
        guard let a = tile(hBright: true, scale), let b = tile(hBright: false, scale) else { return }
        let r = CGRect(x: 0, y: 0, width: t, height: t)
        ctx.draw(a, in: r, byTiling: true)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.draw(b, in: r, byTiling: true)
        ctx.setBlendMode(.destinationIn)
        ctx.drawLinearGradient(gradient([(0, 0), (0, 0.15), (0, 1)], [0, 0.35, 1]),
                               start: CGPoint(x: W * 0.15, y: 0), end: CGPoint(x: W * 0.85, y: H), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.endTransparencyLayer()

        ctx.setBlendMode(.screen)
        glow(ctx, at: CGPoint(x: W * 0.2, y: H * 0.1), r: W * 0.75, 0xD8E2F0, 0.10, stretch: 1.3, angle: 0.5)
        glow(ctx, at: CGPoint(x: W * 0.28, y: H * 0.18), r: W * 0.22, 0xE6EEF8, 0.07, stretch: 2.2, angle: 0.55)
        ctx.setBlendMode(.normal)
        calmCenter(ctx, s, 0x050607, 0.35)
        vignette(ctx, s, 0.65)
    }

    /// 4×4 格的一块，横股亮（hBright）或竖股亮
    static func tile(hBright: Bool, _ scale: CGFloat) -> CGImage? {
        let n = Int((cell * 4 * scale).rounded())
        guard n > 0, let ctx = bitmap(n, n) else { return nil }
        ctx.scaleBy(x: CGFloat(n) / (cell * 4), y: CGFloat(n) / (cell * 4))
        ctx.setFillColor(color(0x060708))
        ctx.fill(CGRect(x: 0, y: 0, width: cell * 4, height: cell * 4))
        for j in 0..<4 {
            for i in 0..<4 {
                let k = ((i - j) % 4 + 4) % 4
                let horizontal = k < 2
                let gap: CGFloat = 0.22
                let c = CGRect(x: CGFloat(i) * cell, y: CGFloat(j) * cell, width: cell, height: cell)
                    .insetBy(dx: horizontal ? 0 : gap, dy: horizontal ? gap : 0)
                let lit = horizontal == hBright
                let (edge, mid): (UInt32, UInt32) = lit ? (0x141619, 0x3B4046) : (0x0E0F12, 0x22252A)
                ctx.saveGState()
                ctx.clip(to: c)
                let across = horizontal ? (CGPoint(x: c.minX, y: c.minY), CGPoint(x: c.minX, y: c.maxY))
                                        : (CGPoint(x: c.minX, y: c.minY), CGPoint(x: c.maxX, y: c.minY))
                ctx.drawLinearGradient(gradient([(edge, 1), (mid, 1), (edge, 1)], [0, 0.45, 1]),
                                       start: across.0, end: across.1, options: [])
                // 纤维丝
                ctx.setStrokeColor(color(0xFFFFFF, lit ? 0.06 : 0.035))
                ctx.setLineWidth(0.25)
                for f in 1..<4 {
                    let o = CGFloat(f) / 4
                    if horizontal {
                        ctx.move(to: CGPoint(x: c.minX, y: c.minY + c.height * o)); ctx.addLine(to: CGPoint(x: c.maxX, y: c.minY + c.height * o))
                    } else {
                        ctx.move(to: CGPoint(x: c.minX + c.width * o, y: c.minY)); ctx.addLine(to: CGPoint(x: c.minX + c.width * o, y: c.maxY))
                    }
                }
                ctx.strokePath()
                // 一股跨两格，中间鼓起最亮，两头钻到下面去，压暗
                let first = horizontal ? k == 0 : k == 3
                let along = horizontal
                    ? (first ? (CGPoint(x: c.minX, y: 0), CGPoint(x: c.maxX, y: 0)) : (CGPoint(x: c.maxX, y: 0), CGPoint(x: c.minX, y: 0)))
                    : (first ? (CGPoint(x: 0, y: c.minY), CGPoint(x: 0, y: c.maxY)) : (CGPoint(x: 0, y: c.maxY), CGPoint(x: 0, y: c.minY)))
                ctx.drawLinearGradient(gradient([(0, 0.7), (0, 0.2), (0, 0)], [0, 0.45, 1]), start: along.0, end: along.1, options: [])
                ctx.restoreGState()
            }
        }
        return ctx.makeImage()
    }
}
