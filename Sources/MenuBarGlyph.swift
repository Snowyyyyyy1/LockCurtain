// MenuBarGlyph.swift —— 菜单栏图标：和 App 图标同一台初代 Mac。单色模板图，深浅色菜单栏由系统上色
//
// 按 @2x 像素设计（40×40，y 朝下），直边都落在整像素上，Retina 下不发虚。
// 遮罩盖着时屏幕涂满、锁是抠出来的：用奇偶填充抠，不用 .clear，模板图画进去的上下文不一定是单独一层

import AppKit

enum MenuBarGlyph {
    static let idle = make(locked: false, label: "LockCurtain")
    static let locked = make(locked: true, label: "遮罩显示中")

    private static func make(locked: Bool, label: String) -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.scaleBy(x: 0.5, y: 0.5)
            draw(c, locked: locked)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = label
        return img
    }

    private static func rr(_ r: CGRect, _ k: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: k, cornerHeight: k, transform: nil) }

    private static func draw(_ c: CGContext, locked: Bool) {
        c.setFillColor(.black)
        // 机身外框、软驱口
        c.addPath(rr(CGRect(x: 1, y: 1, width: 38, height: 38), 7)); c.addPath(rr(CGRect(x: 4, y: 4, width: 32, height: 32), 4))
        c.fillPath(using: .evenOdd)
        c.fill(CGRect(x: 23, y: 31, width: 8, height: 2))

        let screen = CGRect(x: 8, y: 8, width: 24, height: 20)
        if locked {
            // 屏幕 → 锁身（抠掉）→ 钥匙孔（填回来）；锁梁的腿刚好停在锁身顶上，不重叠
            let shackle = CGMutablePath()
            shackle.move(to: CGPoint(x: 17, y: 18)); shackle.addLine(to: CGPoint(x: 17, y: 15))
            shackle.addArc(center: CGPoint(x: 20, y: 15), radius: 3, startAngle: .pi, endAngle: 0, clockwise: false)
            shackle.addLine(to: CGPoint(x: 23, y: 18))
            c.addPath(rr(screen, 4))
            c.addPath(shackle.copy(strokingWithWidth: 2, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
            c.addRect(CGRect(x: 14, y: 18, width: 12, height: 7))
            c.addRect(CGRect(x: 19, y: 20, width: 2, height: 3))
            c.fillPath(using: .evenOdd)
        } else {
            // 屏幕框里一张笑脸：两只眼、往左勾的鼻子、一道笑
            c.addPath(rr(screen, 4)); c.addPath(rr(screen.insetBy(dx: 2, dy: 2), 2)); c.fillPath(using: .evenOdd)
            c.fill(CGRect(x: 14, y: 13, width: 2, height: 4))
            c.fill(CGRect(x: 24, y: 13, width: 2, height: 4))
            c.fill(CGRect(x: 20, y: 13, width: 1, height: 5))
            c.fill(CGRect(x: 18, y: 17, width: 3, height: 1))
            let smile = CGMutablePath()
            smile.move(to: CGPoint(x: 14, y: 21.5)); smile.addQuadCurve(to: CGPoint(x: 26, y: 21.5), control: CGPoint(x: 20, y: 26.5))
            c.setStrokeColor(.black); c.setLineWidth(2); c.setLineCap(.round)
            c.addPath(smile); c.strokePath()
        }
    }
}
