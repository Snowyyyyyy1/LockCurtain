// make-icon.swift —— 用 CoreGraphics 画 App 图标，输出 .iconset 目录（build.sh 再用 iconutil 打包）
//
//   xcrun swift Tools/make-icon.swift <输出目录>.iconset
//
// 构图：夜空底色的圆角方块，两侧丝绒幕布被金色系带束起、向中间拉开，露出一弯发光的月牙。
// 尺寸按 macOS 图标网格：1024 画布里内容占 824×824，圆角半径 185。

import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// 在 1024 坐标系（原点左上）里画整张图标
func draw(_ c: CGContext) {
    c.translateBy(x: 0, y: 1024)
    c.scaleBy(x: 1, y: -1)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // 投影
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.35))
    c.addPath(tilePath); c.setFillColor(rgb(0x151838)); c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(tilePath); c.clip()

    // 夜空：上深下略亮，中间偏上一团月光
    c.drawLinearGradient(gradient([(0, rgb(0x0E1030)), (0.65, rgb(0x232766)), (1, rgb(0x2E2A6E))]),
                         start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    let moonCenter = CGPoint(x: 520, y: 470)
    c.drawRadialGradient(gradient([(0, rgb(0xFFE9A8, 0.42)), (0.45, rgb(0xB9A4FF, 0.12)), (1, rgb(0x000000, 0))]),
                         startCenter: moonCenter, startRadius: 0, endCenter: moonCenter, endRadius: 330, options: [])

    // 星星：四角星
    func sparkle(_ p: CGPoint, _ r: CGFloat, _ a: CGFloat) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: p.x, y: p.y - r))
        path.addQuadCurve(to: CGPoint(x: p.x + r, y: p.y), control: p)
        path.addQuadCurve(to: CGPoint(x: p.x, y: p.y + r), control: p)
        path.addQuadCurve(to: CGPoint(x: p.x - r, y: p.y), control: p)
        path.addQuadCurve(to: CGPoint(x: p.x, y: p.y - r), control: p)
        c.addPath(path); c.setFillColor(rgb(0xFFF6DA, a)); c.fillPath()
    }
    sparkle(CGPoint(x: 395, y: 330), 22, 0.95)
    sparkle(CGPoint(x: 640, y: 610), 15, 0.8)
    sparkle(CGPoint(x: 612, y: 300), 10, 0.7)
    sparkle(CGPoint(x: 430, y: 640), 9, 0.6)

    // 月牙：大圆减去右上偏移的圆
    c.saveGState()
    c.setShadow(offset: .zero, blur: 46, color: rgb(0xFFE08A, 0.85))
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    let r: CGFloat = 132
    c.addEllipse(in: CGRect(x: moonCenter.x - r, y: moonCenter.y - r, width: 2 * r, height: 2 * r))
    c.clip()
    c.addRect(tile)
    c.addEllipse(in: CGRect(x: moonCenter.x - r + 70, y: moonCenter.y - r - 48, width: 2 * r, height: 2 * r))
    c.clip(using: .evenOdd)
    c.drawLinearGradient(gradient([(0, rgb(0xFFF7D6)), (1, rgb(0xFFD86B))]),
                         start: CGPoint(x: moonCenter.x - r, y: moonCenter.y - r),
                         end: CGPoint(x: moonCenter.x + r, y: moonCenter.y + r), options: [])
    c.endTransparencyLayer()
    c.restoreGState()

    // 幕布：上沿宽、在系带处收紧、往下再散开
    func drape(mirror: Bool) {
        c.saveGState()
        if mirror { c.translateBy(x: 1024, y: 0); c.scaleBy(x: -1, y: 1) }
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 60, y: 120))
        p.addLine(to: CGPoint(x: 440, y: 120))
        p.addCurve(to: CGPoint(x: 236, y: 640), control1: CGPoint(x: 400, y: 330), control2: CGPoint(x: 268, y: 520))
        p.addCurve(to: CGPoint(x: 310, y: 960), control1: CGPoint(x: 218, y: 740), control2: CGPoint(x: 278, y: 860))
        p.addLine(to: CGPoint(x: 60, y: 960))
        p.closeSubpath()

        c.saveGState()
        c.setShadow(offset: CGSize(width: 10, height: 6), blur: 30, color: rgb(0x000000, 0.5))
        c.addPath(p); c.setFillColor(rgb(0x5A1A3E)); c.fillPath()
        c.restoreGState()

        // 褶皱：沿 x 方向明暗交替
        c.saveGState()
        c.addPath(p); c.clip()
        c.drawLinearGradient(gradient([
            (0.00, rgb(0x3A0E28)), (0.12, rgb(0x8E2F5E)), (0.24, rgb(0x4C1434)),
            (0.38, rgb(0xA23B6C)), (0.52, rgb(0x5A1A3E)), (0.68, rgb(0xB24A78)),
            (0.84, rgb(0x6A2048)), (1.00, rgb(0x3E1030)),
        ]), start: CGPoint(x: 100, y: 0), end: CGPoint(x: 440, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        // 越往下越暗，压住底部
        c.drawLinearGradient(gradient([(0, rgb(0x000000, 0)), (1, rgb(0x000000, 0.35))]),
                             start: CGPoint(x: 0, y: 500), end: CGPoint(x: 0, y: 960), options: [])
        c.restoreGState()

        // 金色系带
        c.saveGState()
        let band = CGMutablePath()
        band.move(to: CGPoint(x: 70, y: 615))
        band.addQuadCurve(to: CGPoint(x: 256, y: 626), control: CGPoint(x: 165, y: 655))
        band.addLine(to: CGPoint(x: 252, y: 660))
        band.addQuadCurve(to: CGPoint(x: 70, y: 650), control: CGPoint(x: 165, y: 690))
        band.closeSubpath()
        c.setShadow(offset: CGSize(width: 0, height: 4), blur: 8, color: rgb(0x000000, 0.45))
        c.addPath(band); c.clip()
        c.drawLinearGradient(gradient([(0, rgb(0xFFE7A0)), (0.5, rgb(0xE0A93E)), (1, rgb(0x9A6A1C))]),
                             start: CGPoint(x: 0, y: 612), end: CGPoint(x: 0, y: 690), options: [])
        c.restoreGState()

        c.restoreGState()
    }
    drape(mirror: false)
    drape(mirror: true)

    // 顶部帷幔
    let valance = CGMutablePath()
    valance.move(to: CGPoint(x: 100, y: 100))
    valance.addLine(to: CGPoint(x: 924, y: 100))
    valance.addLine(to: CGPoint(x: 924, y: 196))
    let scallops = 5
    let w = 824.0 / Double(scallops)
    for i in (0..<scallops).reversed() {
        let x0 = 100 + CGFloat(Double(i) * w)
        valance.addQuadCurve(to: CGPoint(x: x0, y: 196), control: CGPoint(x: x0 + CGFloat(w / 2), y: 250))
    }
    valance.closeSubpath()
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 10), blur: 22, color: rgb(0x000000, 0.5))
    c.addPath(valance); c.setFillColor(rgb(0x4A1434)); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(valance); c.clip()
    c.drawLinearGradient(gradient([(0, rgb(0x4E1236)), (0.7, rgb(0x6E2250)), (1, rgb(0x3A0C28))]),
                         start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 250), options: [])
    c.restoreGState()
    // 沿扇形下沿描金边
    let trim = CGMutablePath()
    trim.move(to: CGPoint(x: 100, y: 196))
    for i in 0..<scallops {
        let x0 = 100 + CGFloat(Double(i) * w)
        trim.addQuadCurve(to: CGPoint(x: x0 + CGFloat(w), y: 196), control: CGPoint(x: x0 + CGFloat(w / 2), y: 250))
    }
    c.saveGState()
    c.addPath(trim)
    c.setStrokeColor(rgb(0xE8B852)); c.setLineWidth(8); c.setLineCap(.round); c.strokePath()
    c.restoreGState()

    c.restoreGState()

    // 细高光描边，让图标在深色 Dock 上有边界
    c.addPath(tilePath)
    c.setStrokeColor(rgb(0xFFFFFF, 0.10)); c.setLineWidth(2); c.strokePath()
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    let c = ctx.cgContext
    c.interpolationQuality = .high
    c.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(c)
    ctx.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * scale).write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
    }
}
print("wrote \(out)")
