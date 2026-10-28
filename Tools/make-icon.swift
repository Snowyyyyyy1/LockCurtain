// make-icon.swift —— 画 App 图标：macOS 的 .iconset（build.sh 再用 iconutil 打包），或 Windows 的 .ico
//
//   xcrun swiftc -o make-icon Tools/make-icon.swift
//   ./make-icon <输出目录>.iconset
//   ./make-icon --ico windows/LockCurtain/LockCurtain.ico
//
// 构图：初代 Macintosh。浅灰底上一台米色的一体机（比真机矮胖，屏幕占大半），显像管屏幕上是 1-bit 像素笑脸。
// 质感对标系统自带图标：每样东西都有上亮下暗的渐变、内沿高光和投影，显像管左上一团反光。
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

/// 屏幕上的笑脸：1-bit 像素画，# 是黑点，第一行在最上面。自己画的，不是苹果 Happy Mac 的原图
let face = [
    ".#....#.",
    ".#....#.",
    "....#...",
    "....#...",
    "...##...",
    "........",
    "#......#",
    ".######.",
]

func drawBits(_ c: CGContext, _ rows: [String], center: CGPoint, px: CGFloat, color: CGColor) {
    let w = CGFloat(rows[0].count), h = CGFloat(rows.count)
    let x0 = center.x - w * px / 2, top = center.y + h * px / 2
    c.setFillColor(color)
    for (r, row) in rows.enumerated() {
        for (k, ch) in row.enumerated() where ch == "#" {
            c.fill(CGRect(x: x0 + CGFloat(k) * px, y: top - CGFloat(r + 1) * px, width: px, height: px))
        }
    }
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

    // 机身是米色塑料，比真机矮胖，屏幕占大半。从稍高处看：后面露出一窄条顶面，底下往里收一截脚
    let bodyR = CGRect(x: 222, y: 186, width: 580, height: 622)
    let body = rr(bodyR, 44)
    let topR = CGRect(x: bodyR.minX + 16, y: bodyR.maxY - 120, width: bodyR.width - 32, height: 152)
    let top = rr(topR, 40)
    let footR = CGRect(x: bodyR.minX + 22, y: 150, width: bodyR.width - 44, height: 60)
    let foot = rr(footR, 16)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14 * sd), blur: 34 * sd, color: black(0.4))
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    c.setFillColor(rgb(0xCFC6AE))
    for p in [foot, body, top] { c.addPath(p); c.fillPath() }
    c.endTransparencyLayer()
    c.restoreGState()
    fillLinear(c, top, [rgb(0xE9E2D0), rgb(0xD9D0BA)], CGPoint(x: 0, y: topR.maxY), CGPoint(x: 0, y: topR.maxY - 34))
    innerEdge(c, top, white(0.8), dy: -2)
    let handleR = CGRect(x: bodyR.midX - 130, y: topR.maxY - 22, width: 260, height: 12)
    fillLinear(c, rr(handleR, 6), [rgb(0x6E6656), rgb(0xA49A83)], CGPoint(x: 0, y: handleR.maxY), CGPoint(x: 0, y: handleR.minY))
    fillLinear(c, foot, [rgb(0x9F957D), rgb(0xB8AE95)], CGPoint(x: 0, y: footR.maxY), CGPoint(x: 0, y: footR.minY))
    innerEdge(c, foot, black(0.2), dy: 2)

    // 正面：上亮下暗，左沿受光、右沿压暗，看得出是圆角的塑料壳
    fillLinear(c, body, [rgb(0xF5EFE1), rgb(0xE6DECA), rgb(0xD2C8AF)], CGPoint(x: 0, y: bodyR.maxY), CGPoint(x: 0, y: bodyR.minY), [0, 0.55, 1])
    c.saveGState(); c.addPath(body); c.clip()
    c.drawLinearGradient(gradient([white(0.4), white(0)]), start: CGPoint(x: bodyR.minX, y: 0), end: CGPoint(x: bodyR.minX + 36, y: 0), options: [])
    c.drawLinearGradient(gradient([black(0), black(0.14)]), start: CGPoint(x: bodyR.maxX - 44, y: 0), end: CGPoint(x: bodyR.maxX, y: 0), options: [])
    c.restoreGState()
    innerEdge(c, body, white(0.95), dy: -4)
    innerEdge(c, body, rgb(0x857B66, 0.55), dy: 4)

    // 屏幕凹槽 → 显像管玻璃 → 发光的屏面，屏面上是像素笑脸，四角压暗
    let bezelR = CGRect(x: bodyR.minX + 40, y: bodyR.maxY - 472, width: bodyR.width - 80, height: 430)
    let bezel = rr(bezelR, 40)
    fillLinear(c, bezel, [rgb(0xC9BFA6), rgb(0xDED5BF)], CGPoint(x: 0, y: bezelR.maxY), CGPoint(x: 0, y: bezelR.minY))
    innerEdge(c, bezel, black(0.25), dy: -7)
    innerEdge(c, bezel, white(0.75), dy: 3)
    let crtR = bezelR.insetBy(dx: 24, dy: 24)
    let crt = rr(crtR, 60)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 3 * sd), blur: 6 * sd, color: black(0.35))
    c.addPath(crt); c.setFillColor(rgb(0x2A2B2D)); c.fillPath()
    c.restoreGState()
    fillLinear(c, crt, [rgb(0x232426), rgb(0x3C3D40)], CGPoint(x: 0, y: crtR.maxY), CGPoint(x: 0, y: crtR.minY))
    let scrR = crtR.insetBy(dx: 17, dy: 17)
    let mid = CGPoint(x: scrR.midX, y: scrR.midY)
    c.saveGState(); c.addPath(rr(scrR, 46)); c.clip()
    c.setFillColor(rgb(0xEEF2EE)); c.fill(scrR)
    drawBits(c, face, center: CGPoint(x: mid.x, y: mid.y + 2), px: 32, color: rgb(0x17191B))
    c.drawRadialGradient(gradient([black(0), black(0.30)]), startCenter: mid, startRadius: 100,
                         endCenter: mid, endRadius: 300, options: [.drawsAfterEndLocation])
    c.restoreGState()
    // 显像管是鼓的：左上一团反光
    let glare = CGPoint(x: crtR.minX + 90, y: crtR.maxY - 64)
    c.saveGState(); c.addPath(crt); c.clip()
    c.drawRadialGradient(gradient([white(0.38), white(0)]), startCenter: glare, startRadius: 0, endCenter: glare, endRadius: 200, options: [])
    c.restoreGState()

    // 软驱口：右下一条深缝，下沿亮一线
    let slotR = CGRect(x: bodyR.midX + 60, y: bodyR.minY + 64, width: 180, height: 20)
    let slot = rr(slotR, 9)
    fillLinear(c, slot, [rgb(0x1E1B17), rgb(0x48423A)], CGPoint(x: 0, y: slotR.maxY), CGPoint(x: 0, y: slotR.minY))
    innerEdge(c, slot, black(0.5), dy: -4)
    let lip = rr(slotR.offsetBy(dx: 0, dy: -3), 9)
    c.saveGState(); c.addPath(lip); c.addPath(slot); c.clip(using: .evenOdd)
    c.setFillColor(white(0.7)); c.fill(lip.boundingBox)
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
