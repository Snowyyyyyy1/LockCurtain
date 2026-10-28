// make-icon.swift —— 画 App 图标：macOS 的 .iconset（build.sh 再用 iconutil 打包），或 Windows 的 .ico
//
//   xcrun swiftc -o make-icon Tools/make-icon.swift
//   ./make-icon <输出目录>.iconset
//   ./make-icon --ico windows/LockCurtain/LockCurtain.ico
//
// 构图：整个圆角方块就是初代 Macintosh 的正面。米色塑料铺满，显像管屏幕占上面大半，下巴右边一道软驱口，屏幕上是 1-bit 像素笑脸。
// 不画整台 Mac 再垫底：macOS 26 起，外形不是圆角方块的 .icns 会被系统缩小、塞进一个灰色方块里。
// 质感对标系统自带图标：面板四边往后圆过去（上沿亮、下沿暗），屏幕嵌在一圈斜面里，显像管玻璃是鼓的、屏面透光。
// 图形按 macOS 图标网格画：1024 画布里方块占 824×824（100…924），连续曲率圆角，半径 185。
// 屏幕一层层都和外框同心：内圆角 = 外圆角 − 两层的间距，弧度才接得上。
// Windows 不裁形状，整张图按比例放大到几乎铺满画布。

import AppKit
import SwiftUI

let args = Array(CommandLine.arguments.dropFirst())

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255, blue: CGFloat(h & 0xff) / 255, alpha: a)
}
func white(_ a: CGFloat) -> CGColor { CGColor(gray: 1, alpha: a) }
func black(_ a: CGFloat) -> CGColor { CGColor(gray: 0, alpha: a) }
func gradient(_ cols: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient { CGGradient(colorsSpace: srgb, colors: cols as CFArray, locations: locs)! }
/// 连续曲率的圆角矩形，和系统图标的形状一致
func rr(_ r: CGRect, _ k: CGFloat) -> CGPath { RoundedRectangle(cornerRadius: k, style: .continuous).path(in: r).cgPath }

func fillLinear(_ c: CGContext, _ p: CGPath, _ cols: [CGColor], _ from: CGPoint, _ to: CGPoint, _ locs: [CGFloat]? = nil) {
    c.saveGState(); c.addPath(p); c.clip()
    c.drawLinearGradient(gradient(cols, locs), start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
}

func fillRadial(_ c: CGContext, _ p: CGPath, _ cols: [CGColor], _ center: CGPoint, _ r0: CGFloat, _ r1: CGFloat) {
    c.saveGState(); c.addPath(p); c.clip()
    c.drawRadialGradient(gradient(cols), startCenter: center, startRadius: r0, endCenter: center, endRadius: r1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
}

/// 内沿：形状里面、但不在「往 dy 挪过的同一形状」里的那一窄条，边是硬的。dy < 0 是上沿，dy > 0 是下沿
func innerEdge(_ c: CGContext, _ p: CGPath, _ color: CGColor, dy: CGFloat) {
    var t = CGAffineTransform(translationX: 0, y: dy)
    c.saveGState(); c.addPath(p); c.clip()
    c.addPath(p.copy(using: &t)!)
    c.addRect(p.boundingBox.insetBy(dx: -50, dy: -50))
    c.setFillColor(color); c.fillPath(using: .evenOdd)
    c.restoreGState()
}

/// 内阴影：形状外面那一圈往里投的影，边是软的。dy < 0 落在上沿，dy > 0 落在下沿；用白色就是往里晕开的光。
/// sd 是设计单位到设备像素的比例：CG 的阴影偏移和模糊不跟着 CTM 缩放，要自己乘
func innerShadow(_ c: CGContext, _ p: CGPath, _ color: CGColor, dy: CGFloat, blur: CGFloat, sd: CGFloat) {
    let pad = blur * 3 + abs(dy)
    c.saveGState(); c.addPath(p); c.clip()
    c.setShadow(offset: CGSize(width: 0, height: dy * sd), blur: blur * sd, color: color)
    c.addRect(p.boundingBox.insetBy(dx: -pad, dy: -pad)); c.addPath(p)
    c.setFillColor(black(1)); c.fillPath(using: .evenOdd)
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
/// 16px 的图标里屏面只有 9×7 个像素，放不下上面那张，换一张没有鼻子的小脸
let tinyFace = [
    ".#.#.",
    ".....",
    "#...#",
    ".###.",
]

/// 按设备像素画像素画：每格取整到整像素、左上角落在整像素上，小尺寸才不糊。一格不到 0.8 个像素（16px 的图标）时换小脸
func drawBits(_ c: CGContext, center: CGPoint, cell: CGFloat, color: CGColor) {
    let m = c.userSpaceToDeviceSpaceTransform, inv = m.inverted()
    let rows = cell * abs(m.a) < 0.8 ? tinyFace : face
    let dc = max(1, (cell * abs(m.a)).rounded())
    let w = CGFloat(rows[0].count), h = CGFloat(rows.count)
    // 设备坐标可能是 y 朝下的：up 是「往上一格」在设备里的方向
    let mid = center.applying(m), up: CGFloat = m.d < 0 ? -1 : 1
    let x0 = (mid.x - w * dc / 2).rounded(), top = (mid.y + up * h * dc / 2).rounded()
    c.setFillColor(color)
    for (r, row) in rows.enumerated() {
        for (k, ch) in row.enumerated() where ch == "#" {
            let y = top - up * CGFloat(r) * dc
            c.fill(CGRect(x: x0 + CGFloat(k) * dc, y: min(y, y - up * dc), width: dc, height: dc).applying(inv))
        }
    }
}

/// 按 macOS 网格（方块 100…924）画整张图标。sd 见 innerShadow
func drawIcon(_ c: CGContext, corner: CGFloat, sd: CGFloat) {
    let t = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = rr(t, corner)

    // 面板：米色塑料，上亮下暗。四边往后圆过去：上沿往里晕一圈光，下沿和两侧压暗，右边比左边暗一点
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10 * sd), blur: 24 * sd, color: black(0.3))
    c.addPath(tile); c.setFillColor(rgb(0xE6DECA)); c.fillPath()
    c.restoreGState()
    fillLinear(c, tile, [rgb(0xF6F1E4), rgb(0xE8E0CC), rgb(0xD3C9AF)], CGPoint(x: 0, y: t.maxY), CGPoint(x: 0, y: t.minY), [0, 0.5, 1])
    c.saveGState(); c.addPath(tile); c.clip()
    c.drawLinearGradient(gradient([black(0), black(0.07)]), start: CGPoint(x: t.maxX - 90, y: 0), end: CGPoint(x: t.maxX, y: 0), options: [])
    c.restoreGState()
    innerShadow(c, tile, rgb(0x5E5442, 0.35), dy: 10, blur: 26, sd: sd)
    innerShadow(c, tile, white(0.95), dy: -8, blur: 12, sd: sd)

    // 屏幕嵌在一圈斜面里：上面的斜面背光发暗，下面的朝上受光；斜面和面板交界，上沿一道暗线、下沿一道亮线
    let margin: CGFloat = 60, bevel: CGFloat = 36, border: CGFloat = 24
    let recessR = CGRect(x: t.minX + margin, y: t.maxY - margin - 568, width: t.width - margin * 2, height: 568)
    let recess = rr(recessR, corner - margin)
    fillLinear(c, recess, [rgb(0xA2977D), rgb(0xC3B99F), rgb(0xE2DAC6), rgb(0xF1EBDC)],
               CGPoint(x: 0, y: recessR.maxY), CGPoint(x: 0, y: recessR.minY), [0, 0.3, 0.75, 1])
    innerEdge(c, recess, rgb(0x5E5442, 0.35), dy: -3)
    innerEdge(c, recess, white(0.8), dy: 3)

    // 显像管：深色玻璃，上沿被斜面压出一道影；屏面透一点光到玻璃上
    let glassR = recessR.insetBy(dx: bevel, dy: bevel)
    let glass = rr(glassR, corner - margin - bevel)
    fillLinear(c, glass, [rgb(0x141516), rgb(0x2C2D30)], CGPoint(x: 0, y: glassR.maxY), CGPoint(x: 0, y: glassR.minY))
    let screenR = glassR.insetBy(dx: border, dy: border)
    let screen = rr(screenR, corner - margin - bevel - border)
    c.saveGState(); c.addPath(glass); c.clip()
    c.setShadow(offset: .zero, blur: 22 * sd, color: rgb(0xD8F0E8, 0.45))
    c.addPath(screen); c.setFillColor(rgb(0xEEF2EE)); c.fillPath()
    c.restoreGState()
    let mid = CGPoint(x: screenR.midX, y: screenR.midY)
    fillRadial(c, screen, [rgb(0xF5F8F5), rgb(0xE6EBE7)], CGPoint(x: mid.x, y: mid.y + 30), 60, 320)
    c.saveGState(); c.addPath(screen); c.clip()
    drawBits(c, center: CGPoint(x: mid.x, y: mid.y + 4), cell: 40, color: rgb(0x16181A))
    c.restoreGState()
    fillRadial(c, screen, [black(0), black(0.22)], mid, 170, 380)
    innerShadow(c, glass, black(0.75), dy: -9, blur: 14, sd: sd)

    // 玻璃是鼓的：左上角一团反光，顶上一窄条很淡的亮，都避开笑脸，眼睛才是纯黑的
    c.saveGState(); c.addPath(glass); c.clip()
    let glare = CGPoint(x: glassR.minX + 60, y: glassR.maxY - 50)
    c.drawRadialGradient(gradient([white(0.4), white(0)]), startCenter: glare, startRadius: 0, endCenter: glare, endRadius: 150, options: [])
    c.drawLinearGradient(gradient([white(0.12), white(0)]), start: CGPoint(x: 0, y: glassR.maxY), end: CGPoint(x: 0, y: glassR.maxY - 76), options: [])
    c.restoreGState()

    // 软驱口：下巴右边一道浅槽，槽里一条深缝，缝右边一个退盘的针孔。缝的左端和针孔都和槽的两头同心
    let chinY = (t.minY + recessR.minY) / 2 + 4
    let trayR = CGRect(x: recessR.maxX - 316, y: chinY - 27, width: 276, height: 54)
    let cap = trayR.height / 2
    let tray = rr(trayR, cap)
    fillLinear(c, tray, [rgb(0xCFC5AC), rgb(0xE4DCC8)], CGPoint(x: 0, y: trayR.maxY), CGPoint(x: 0, y: trayR.minY))
    innerShadow(c, tray, rgb(0x5E5442, 0.55), dy: -5, blur: 7, sd: sd)
    innerEdge(c, tray, white(0.85), dy: 2)
    let slotR = CGRect(x: trayR.minX + cap - 8, y: chinY - 8, width: 196, height: 16)
    let slot = rr(slotR, 8)
    fillLinear(c, slot, [rgb(0x0E0D0B), rgb(0x3A352D)], CGPoint(x: 0, y: slotR.maxY), CGPoint(x: 0, y: slotR.minY))
    innerEdge(c, slot, white(0.35), dy: 2)
    let pinR = CGRect(x: trayR.maxX - cap - 5, y: chinY - 5, width: 10, height: 10)
    fillLinear(c, CGPath(ellipseIn: pinR, transform: nil), [rgb(0x1C1A16), rgb(0x5A5244)],
               CGPoint(x: 0, y: pinR.maxY), CGPoint(x: 0, y: pinR.minY))

    // 方块边上一道很细的硬高光和一道细边，深色 Dock 上看得出轮廓
    innerEdge(c, tile, white(0.9), dy: -2)
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
