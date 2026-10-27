// make-icon.swift —— 画 App 图标：macOS 的 .iconset（build.sh 再用 iconutil 打包），或 Windows 的 .ico
//
//   xcrun swiftc -o make-icon Tools/make-icon.swift
//   ./make-icon <输出目录>.iconset
//   ./make-icon --ico windows/LockCurtain/LockCurtain.ico
//
// 构图：屏幕加锁。浅灰底上一台显示器（铝边框、黑玻璃、铝支架），屏幕是锁屏那样的蓝紫壁纸，中间一把白色的锁。
// 质感对标系统自带图标：每样东西都有上亮下暗的渐变、内沿高光和投影，玻璃左上一片斜的反光。
// 图形按 macOS 图标网格画：1024 画布里方块占 824×824（100…924），圆角半径 185，系统显示时会再按自己的形状裁一次。
// Windows 不裁形状，整张图按比例放大到几乎铺满画布。

import AppKit

let args = Array(CommandLine.arguments.dropFirst())

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255, blue: CGFloat(h & 0xff) / 255, alpha: a)
}
func white(_ a: CGFloat) -> CGColor { CGColor(gray: 1, alpha: a) }
func black(_ a: CGFloat) -> CGColor { CGColor(gray: 0, alpha: a) }
func gradient(_ cols: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient { CGGradient(colorsSpace: srgb, colors: cols as CFArray, locations: locs)! }
func rr(_ r: CGRect, _ k: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: k, cornerHeight: k, transform: nil) }

func fillLinear(_ c: CGContext, _ p: CGPath, _ cols: [CGColor], _ from: CGPoint, _ to: CGPoint, _ locs: [CGFloat]? = nil) {
    c.saveGState(); c.addPath(p); c.clip()
    c.drawLinearGradient(gradient(cols, locs), start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
}

/// 内沿：形状里面、但不在「往 dy 挪过的同一形状」里的那一窄条。dy < 0 是上沿，dy > 0 是下沿
func innerEdge(_ c: CGContext, _ p: CGPath, _ color: CGColor, dy: CGFloat) {
    var t = CGAffineTransform(translationX: 0, y: dy)
    c.saveGState(); c.addPath(p); c.clip()
    c.addPath(p.copy(using: &t)!)
    c.addRect(p.boundingBox.insetBy(dx: -50, dy: -50))
    c.setFillColor(color); c.fillPath(using: .evenOdd)
    c.restoreGState()
}

/// 锁：缎面锁身 + 圆管锁梁 + 挖进去的钥匙孔。(cx, cy) 是锁身中心，w 是锁身宽，sd 把阴影换算成设备像素
func drawLock(_ c: CGContext, cx: CGFloat, cy: CGFloat, w: CGFloat, sd: CGFloat) {
    let h = w * 0.80, R = w * 0.29, t = w * 0.15
    let bodyR = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    let body = rr(bodyR, w * 0.17)
    let legTop = cy + h / 2 + w * 0.13
    let shackle = CGMutablePath()
    shackle.move(to: CGPoint(x: cx - R, y: cy))
    shackle.addLine(to: CGPoint(x: cx - R, y: legTop))
    shackle.addArc(center: CGPoint(x: cx, y: legTop), radius: R, startAngle: .pi, endAngle: 0, clockwise: true)
    shackle.addLine(to: CGPoint(x: cx + R, y: cy))

    // 整把锁一起投影，锁梁和锁身的影子不叠两层
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10 * sd), blur: 26 * sd, color: black(0.55))
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    c.setStrokeColor(rgb(0xBFC3CB)); c.setLineWidth(t); c.addPath(shackle); c.strokePath()
    c.setFillColor(rgb(0xE6E8EC)); c.addPath(body); c.fillPath()
    c.endTransparencyLayer()
    c.restoreGState()

    // 锁梁：整根中灰，再叠一道偏左上的亮面和一道细高光，看起来是圆管
    for (color, width, shift) in [(rgb(0xA9AEB7), 1.0, 0.0), (rgb(0xE9EBEF), 0.62, 0.1), (white(0.95), 0.2, 0.18)] as [(CGColor, CGFloat, CGFloat)] {
        var m = CGAffineTransform(translationX: -t * shift * 0.9, y: t * shift)
        c.setStrokeColor(color); c.setLineWidth(t * width); c.addPath(shackle.copy(using: &m)!); c.strokePath()
    }

    // 锁身：上亮下暗，上沿亮边、下沿暗边，顶上被锁梁压出一点影子
    fillLinear(c, body, [rgb(0xFFFFFF), rgb(0xF1F2F5), rgb(0xCDD1D8)], CGPoint(x: 0, y: bodyR.maxY), CGPoint(x: 0, y: bodyR.minY), [0, 0.45, 1])
    innerEdge(c, body, white(1), dy: -3)
    innerEdge(c, body, rgb(0x8E939C, 0.55), dy: 3)
    c.saveGState(); c.addPath(body); c.clip()
    c.drawLinearGradient(gradient([black(0.14), black(0)]), start: CGPoint(x: 0, y: bodyR.maxY), end: CGPoint(x: 0, y: bodyR.maxY - h * 0.12), options: [])
    c.restoreGState()

    // 钥匙孔一笔画完：圆从右下接口绕过顶到左下接口，再往下是上窄下宽的槽。上沿内阴影，下沿反一点光
    let kr = w * 0.09, kc = CGPoint(x: cx, y: cy + h * 0.07), a = acos(0.38), bottom = cy - h * 0.20
    let hole = CGMutablePath()
    hole.addArc(center: kc, radius: kr, startAngle: -a, endAngle: -.pi + a, clockwise: false)
    hole.addLine(to: CGPoint(x: cx - kr * 0.58, y: bottom))
    hole.addLine(to: CGPoint(x: cx + kr * 0.58, y: bottom))
    hole.closeSubpath()
    fillLinear(c, hole, [rgb(0x15161A), rgb(0x34373F)], CGPoint(x: 0, y: kc.y + kr), CGPoint(x: 0, y: bottom))
    innerEdge(c, hole, black(0.7), dy: -3)
    innerEdge(c, hole, white(0.35), dy: 2)
}

/// 按 macOS 网格（方块 100…924）画整张图标。sd 是设计单位到设备像素的比例：CG 的阴影偏移和模糊不跟着 CTM 缩放，要自己乘
func drawIcon(_ c: CGContext, corner: CGFloat, sd: CGFloat) {
    let tile = rr(CGRect(x: 100, y: 100, width: 824, height: 824), corner)

    // 底：浅灰，上面一团暖白的光
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10 * sd), blur: 24 * sd, color: black(0.3))
    c.addPath(tile); c.setFillColor(rgb(0xE8E9ED)); c.fillPath()
    c.restoreGState()
    fillLinear(c, tile, [rgb(0xFDFDFE), rgb(0xEEEFF2), rgb(0xD8DAE0)], CGPoint(x: 0, y: 924), CGPoint(x: 0, y: 100), [0, 0.5, 1])
    c.saveGState(); c.addPath(tile); c.clip()
    c.drawRadialGradient(gradient([white(0.7), white(0)]), startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
                         endCenter: CGPoint(x: 512, y: 900), endRadius: 520, options: [])
    c.restoreGState()

    // 支架：铝，左右是圆柱的明暗，顶上被屏幕挡出一截影子；底座贴着底有接触影
    let base = rr(CGRect(x: 360, y: 236, width: 304, height: 26), 13)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -6 * sd), blur: 16 * sd, color: black(0.35))
    c.addPath(base); c.setFillColor(rgb(0xB0B4BB)); c.fillPath()
    c.restoreGState()
    let neck = CGMutablePath()
    neck.addLines(between: [CGPoint(x: 446, y: 380), CGPoint(x: 578, y: 380), CGPoint(x: 596, y: 262), CGPoint(x: 428, y: 262)])
    neck.closeSubpath()
    fillLinear(c, neck, [rgb(0x8C9098), rgb(0xD5D8DD), rgb(0xF4F5F7), rgb(0xC9CCD2), rgb(0x8A8E96)],
               CGPoint(x: 428, y: 0), CGPoint(x: 596, y: 0), [0, 0.25, 0.45, 0.7, 1])
    c.saveGState(); c.addPath(neck); c.clip()
    c.drawLinearGradient(gradient([black(0.35), black(0)]), start: CGPoint(x: 0, y: 380), end: CGPoint(x: 0, y: 330), options: [])
    c.restoreGState()
    fillLinear(c, base, [rgb(0xF2F3F5), rgb(0xC6C9CF), rgb(0x9DA1A9)], CGPoint(x: 0, y: 262), CGPoint(x: 0, y: 236), [0, 0.5, 1])
    innerEdge(c, base, white(0.9), dy: -2)

    // 显示器：铝边框 → 黑玻璃 → 屏幕
    let frameR = CGRect(x: 182, y: 368, width: 660, height: 432)
    let frame = rr(frameR, 44)
    let glassR = frameR.insetBy(dx: 8, dy: 8)
    let glass = rr(glassR, 37)
    let scr = glassR.insetBy(dx: 16, dy: 16)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14 * sd), blur: 34 * sd, color: black(0.3))
    c.addPath(frame); c.setFillColor(rgb(0xC0C3C9)); c.fillPath()
    c.restoreGState()
    fillLinear(c, frame, [rgb(0xF3F4F6), rgb(0xCDD0D5), rgb(0xA4A8AF)], CGPoint(x: 0, y: frameR.maxY), CGPoint(x: 0, y: frameR.minY), [0, 0.5, 1])
    innerEdge(c, frame, white(0.95), dy: -2.5)
    innerEdge(c, frame, black(0.25), dy: 2.5)
    c.addPath(glass); c.setFillColor(rgb(0x070708)); c.fillPath()

    // 屏幕：锁屏那样的深蓝底，左上一团紫光、右下一团青光，四周压暗，中间是锁
    c.saveGState(); c.addPath(rr(scr, 22)); c.clip()
    c.drawLinearGradient(gradient([rgb(0x2B3A8C), rgb(0x161B4A), rgb(0x080A1C)], [0, 0.5, 1]),
                         start: CGPoint(x: 0, y: scr.maxY), end: CGPoint(x: 0, y: scr.minY), options: [])
    let glows: [(hex: UInt32, alpha: CGFloat, center: CGPoint, radius: CGFloat)] = [
        (0x7A5CFF, 0.55, CGPoint(x: scr.minX + 120, y: scr.maxY - 40), 360),
        (0x22C3E6, 0.35, CGPoint(x: scr.maxX - 80, y: scr.minY + 60), 340),
    ]
    for g in glows {
        c.drawRadialGradient(gradient([rgb(g.hex, g.alpha), rgb(g.hex, 0)]), startCenter: g.center, startRadius: 0,
                             endCenter: g.center, endRadius: g.radius, options: [])
    }
    c.drawRadialGradient(gradient([black(0), black(0.35)]), startCenter: CGPoint(x: scr.midX, y: scr.midY), startRadius: 120,
                         endCenter: CGPoint(x: scr.midX, y: scr.midY), endRadius: 420, options: [.drawsAfterEndLocation])
    drawLock(c, cx: scr.midX, cy: scr.midY - 24, w: 176, sd: sd)
    c.restoreGState()

    // 玻璃反光：左上一片斜的淡光，盖住屏幕和黑边
    c.saveGState(); c.addPath(glass); c.clip()
    let refl = CGMutablePath()
    refl.addLines(between: [CGPoint(x: glassR.minX, y: glassR.maxY), CGPoint(x: glassR.minX + glassR.width * 0.58, y: glassR.maxY),
                            CGPoint(x: glassR.minX + glassR.width * 0.30, y: glassR.minY), CGPoint(x: glassR.minX, y: glassR.minY)])
    refl.closeSubpath()
    c.addPath(refl); c.clip()
    c.drawLinearGradient(gradient([white(0.10), white(0.02)]), start: CGPoint(x: glassR.minX, y: glassR.maxY), end: CGPoint(x: glassR.midX, y: glassR.minY), options: [])
    c.restoreGState()

    // 方块内沿一圈高光，外面一道细边，深色 Dock 上看得出轮廓
    innerEdge(c, tile, white(0.9), dy: -3)
    innerEdge(c, tile, black(0.1), dy: 3)
    c.addPath(tile); c.setStrokeColor(black(0.1)); c.setLineWidth(1.5); c.strokePath()
}

struct Layout {
    let tile: CGRect
    let corner: CGFloat
    static let mac = Layout(tile: CGRect(x: 100, y: 100, width: 824, height: 824), corner: 185)
    static let windows = Layout(tile: CGRect(x: 24, y: 24, width: 976, height: 976), corner: 200)
}

func render(_ px: Int, _ l: Layout) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    let c = ctx.cgContext
    // 先按输出尺寸缩放，再把 macOS 网格里的方块挪到这个布局的方块上
    let dev = CGFloat(px) / 1024, k = l.tile.width / 824
    c.scaleBy(x: dev, y: dev)
    c.translateBy(x: l.tile.minX - 100 * k, y: l.tile.minY - 100 * k)
    c.scaleBy(x: k, y: k)
    drawIcon(c, corner: l.corner / k, sd: dev * k)
    ctx.flushGraphics()
    return rep
}

/// .ico：256 用 PNG，其余用 32 位 DIB（BGRA 自下而上 + 全 0 的 AND 掩码），老的读取方也认
func ico(_ sizes: [Int]) -> Data {
    let images: [Data] = sizes.map { px in
        let rep = render(px, .windows)
        if px >= 256 { return rep.representation(using: .png, properties: [:])! }
        var d = Data()
        func u16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
        func u32(_ v: Int) { u16(v & 0xffff); u16(v >> 16 & 0xffff) }
        let maskRow = (px + 31) / 32 * 4
        u32(40); u32(px); u32(px * 2); u16(1); u16(32); u32(0); u32(px * px * 4 + maskRow * px); u32(0); u32(0); u32(0); u32(0)
        // rep 是预乘过的 RGBA，DIB 要不预乘的 BGRA
        let raw = rep.bitmapData!, row = rep.bytesPerRow
        for y in (0..<px).reversed() {
            for x in 0..<px {
                let p = raw + y * row + x * 4, a = Int(p[3])
                func un(_ v: UInt8) -> UInt8 { a == 0 ? 0 : UInt8(min(255, (Int(v) * 255 + a / 2) / a)) }
                d.append(contentsOf: [un(p[2]), un(p[1]), un(p[0]), UInt8(a)])
            }
        }
        d.append(Data(count: maskRow * px))
        return d
    }
    var out = Data()
    func u16(_ v: Int) { out.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
    func u32(_ v: Int) { u16(v & 0xffff); u16(v >> 16 & 0xffff) }
    u16(0); u16(1); u16(sizes.count)
    var offset = 6 + 16 * sizes.count
    for (px, img) in zip(sizes, images) {
        out.append(UInt8(px >= 256 ? 0 : px)); out.append(UInt8(px >= 256 ? 0 : px))
        out.append(0); out.append(0); u16(1); u16(32); u32(img.count); u32(offset)
        offset += img.count
    }
    for img in images { out.append(img) }
    return out
}

if args.first == "--ico", args.count > 1 {
    try! ico([16, 20, 24, 32, 40, 48, 64, 256]).write(to: URL(fileURLWithPath: args[1]))
    print("wrote \(args[1])")
} else {
    let out = args.first ?? "AppIcon.iconset"
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try! render(base * scale, .mac).representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
        }
    }
    print("wrote \(out)")
}
