// ArtPresets.swift —— 机械眼以外的动画图案：魔瞳、镇宅符、机械表、保险库门、挂锁
//
// 和 MechEye 一样：整个图案是时间 t 的纯函数，画布中心为原点、半径 120 的坐标系。
// 精致度也照着机械眼来：材质分层、光从左上方来、有投影和高光，动作带过冲或余光。

import SwiftUI

private typealias M = MechEye

/// 来光方向（单位向量，指向光源）
private let light = CGPoint(x: -0.6, y: -0.8)

private func line(_ a: CGPoint, _ b: CGPoint) -> Path {
    var p = Path()
    p.move(to: a)
    p.addLine(to: b)
    return p
}

func smoothstep(_ x: Double) -> Double {
    let x = min(max(x, 0), 1)
    return x * x * (3 - 2 * x)
}

private func mix(_ a: UInt32, _ b: UInt32, _ k: Double) -> Color {
    func ch(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 0xff) / 255 }
    let k = min(max(k, 0), 1)
    return Color(.sRGB, red: ch(a, 16) + (ch(b, 16) - ch(a, 16)) * k, green: ch(a, 8) + (ch(b, 8) - ch(a, 8)) * k,
                 blue: ch(a, 0) + (ch(b, 0) - ch(a, 0)) * k)
}

/// 倒角描边：左上亮、右下暗；inset 反过来，看起来是往下凹的
private func bevel(_ r: Double, at c: CGPoint = .zero, hi: Double = 0.55, lo: Double = 0.4, inset: Bool = false) -> GraphicsContext.Shading {
    let colors = [Color.white.opacity(hi), Color.black.opacity(lo)]
    return .linearGradient(Gradient(colors: inset ? colors.reversed() : colors),
                           startPoint: CGPoint(x: c.x - r * 0.7, y: c.y - r * 0.7), endPoint: CGPoint(x: c.x + r * 0.7, y: c.y + r * 0.7))
}

/// 抛光金属圆柱，从 a 到 b，两端宽 w0、w1；高光落在朝向光源的一侧
private func cylinder(_ g: inout GraphicsContext, _ a: CGPoint, _ b: CGPoint, _ w0: Double, _ w1: Double) {
    let len = hypot(b.x - a.x, b.y - a.y)
    let n = CGPoint(x: -(b.y - a.y) / len, y: (b.x - a.x) / len)
    let lit = n.x * light.x + n.y * light.y
    var p = Path()
    p.move(to: CGPoint(x: a.x + n.x * w0 / 2, y: a.y + n.y * w0 / 2))
    p.addLine(to: CGPoint(x: b.x + n.x * w1 / 2, y: b.y + n.y * w1 / 2))
    p.addLine(to: CGPoint(x: b.x - n.x * w1 / 2, y: b.y - n.y * w1 / 2))
    p.addLine(to: CGPoint(x: a.x - n.x * w0 / 2, y: a.y - n.y * w0 / 2))
    p.closeSubpath()
    let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), w = max(w0, w1) / 2
    let stops: [Gradient.Stop] = [.init(color: M.rgb(0x5C626B), location: 0),
                                  .init(color: M.rgb(0xF4F6F9), location: 0.5 - 0.3 * lit),
                                  .init(color: M.rgb(0x41464E), location: 1)]
    g.fill(p, with: .linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: m.x + n.x * w, y: m.y + n.y * w),
                                    endPoint: CGPoint(x: m.x - n.x * w, y: m.y - n.y * w)))
}

/// 抛光金属球：铆钉、把手球头
private func sphere(_ g: inout GraphicsContext, _ c: CGPoint, _ r: Double) {
    g.fill(M.circle(r, c), with: .radialGradient(Gradient(colors: [M.rgb(0xF7F8FA), M.rgb(0x9097A0), M.rgb(0x41454C)]),
                                                 center: CGPoint(x: c.x + light.x * r * 0.45, y: c.y + light.y * r * 0.45),
                                                 startRadius: 0, endRadius: r * 1.5))
}

/// 中间起一道棱的金属条（刻度、指针）：两个斜面按来光方向一亮一暗。
/// profile 是沿长度（0…1）各处的半宽
private func ridged(_ g: inout GraphicsContext, from a: CGPoint, to b: CGPoint, profile: [(Double, Double)]) {
    let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
    let len = hypot(d.x, d.y)
    let n = CGPoint(x: -d.y / len, y: d.x / len)
    let lit = n.x * light.x + n.y * light.y
    func pt(_ u: Double, _ s: Double) -> CGPoint { CGPoint(x: a.x + d.x * u + n.x * s, y: a.y + d.y * u + n.y * s) }
    for side in [1.0, -1.0] {
        var p = Path()
        p.move(to: pt(profile[0].0, 0))
        for (u, hw) in profile { p.addLine(to: pt(u, hw * side)) }
        p.addLine(to: pt(profile[profile.count - 1].0, 0))
        p.closeSubpath()
        let k = 0.5 + 0.5 * lit * side
        g.fill(p, with: .linearGradient(Gradient(colors: [mix(0x50565F, 0xFFFFFF, k), mix(0x3E434A, 0xDDE2E8, k)]),
                                        startPoint: a, endPoint: b))
    }
}

// MARK: - 机械表

/// 机械表：滚花表壳、抛光表圈、太阳纹表盘、立体刻度和多面体指针。6 点位开了个窗，
/// 看得到摆轮来回摆、擒纵轮一跳一格，秒针跟着一秒跳 3 下。显示本机当前时间
enum ClockArt {
    static let beats = 3.0                        // 每秒跳几下；摆轮一来一回是两跳
    static let window = CGPoint(x: 0, y: 50)      // 6 点位的镂空窗

    static func draw(_ g: inout GraphicsContext, size: CGSize, t: Double) {
        M.unitSpace(&g, size)
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSinceReferenceDate: t))
        let frac = t - t.rounded(.down)           // 时区偏移都是整秒，小数部分直接取 t 的
        let beat = (frac * beats).rounded(.down)
        let second = Double(c.second ?? 0) + (beat + M.spring((frac * beats - beat) / beats, omega: 70, zeta: 0.4)) / beats
        let minute = Double(c.minute ?? 0) + (Double(c.second ?? 0) + frac) / 60
        let hour = Double((c.hour ?? 0) % 12) + minute / 60

        drawCase(&g)
        drawDial(&g)
        drawMovement(&g, t: t)
        drawIndices(&g)
        drawHands(&g, hour: hour, minute: minute, second: second)
        drawCrystal(&g)
    }

    /// 表壳：滚花外圈 + 抛光斜面表圈 + 和机械眼一样的一圈橙色余光
    static func drawCase(_ g: inout GraphicsContext) {
        g.stroke(M.circle(116), with: .color(M.rgb(0xFF8A3D, 0.22)), lineWidth: 5)
        var sh = g
        sh.addFilter(.shadow(color: .black.opacity(0.55), radius: 10, y: 6))
        sh.fill(M.circle(112), with: .color(M.rgb(0x6E737C)))

        g.fill(M.ring(112, 103), with: .conicGradient(M.brushed, center: .zero, angle: .degrees(-20)), style: FillStyle(eoFill: true))
        var knurl = Path()
        for k in 0..<144 {
            let deg = Double(k) * 2.5
            knurl.move(to: M.polar(103.5, deg))
            knurl.addLine(to: M.polar(111.6, deg))
        }
        g.stroke(knurl, with: .color(.black.opacity(0.3)), lineWidth: 0.8)
        g.stroke(M.circle(111.3), with: bevel(111), lineWidth: 1.4)

        g.fill(M.ring(103, 93), with: .linearGradient(Gradient(colors: [M.rgb(0xFAFBFC), M.rgb(0xB4BAC2), M.rgb(0x60656D), M.rgb(0x9DA3AB)]),
                                                      startPoint: CGPoint(x: -75, y: -75), endPoint: CGPoint(x: 75, y: 75)),
               style: FillStyle(eoFill: true))
        g.stroke(M.circle(103), with: .color(.black.opacity(0.45)), lineWidth: 1)
        g.stroke(M.circle(93.6), with: bevel(93, hi: 0.3, lo: 0.6, inset: true), lineWidth: 1.6)
    }

    /// 太阳纹表盘：亮度按 cos 2θ 起伏（左上、右下两瓣反光），叠一层极细的放射纹；外圈分钟轨
    static func drawDial(_ g: inout GraphicsContext) {
        let stops = (0...24).map { k -> Gradient.Stop in
            let a = Double(k) / 24 * 2 * .pi
            return .init(color: mix(0x131925, 0x3A4762, 0.5 + 0.5 * cos(2 * (a - 1.25 * .pi))), location: Double(k) / 24)
        }
        g.fill(M.circle(93), with: .conicGradient(Gradient(stops: stops), center: .zero, angle: .zero))
        var rays = Path()
        for k in 0..<240 {
            rays.move(to: M.polar(6, Double(k) * 1.5))
            rays.addLine(to: M.polar(92, Double(k) * 1.5))
        }
        g.stroke(rays, with: .color(.white.opacity(0.035)), lineWidth: 0.5)
        g.fill(M.circle(93), with: .radialGradient(Gradient(colors: [.clear, .black.opacity(0.5)]), center: .zero, startRadius: 45, endRadius: 93))

        g.stroke(M.circle(88), with: .color(.white.opacity(0.3)), lineWidth: 0.6)
        g.stroke(M.circle(82), with: .color(.white.opacity(0.3)), lineWidth: 0.6)
        var ticks = Path()
        for k in 0..<60 where k % 5 != 0 {
            ticks.move(to: M.polar(82, Double(k) * 6))
            ticks.addLine(to: M.polar(88, Double(k) * 6))
        }
        g.stroke(ticks, with: .color(.white.opacity(0.6)), lineWidth: 0.8)
        for k in 0..<12 {
            g.fill(M.circle(1.6, M.polar(85, Double(k) * 30)), with: .color(M.rgb(0xDDEFD6, 0.9)))
        }
    }

    /// 镂空窗：日内瓦波纹底板、擒纵轮、来回摆的摆轮和游丝、摆轮夹板上的红宝石
    static func drawMovement(_ g: inout GraphicsContext, t: Double) {
        let c = window, r = 21.0
        var w = g
        w.clip(to: M.circle(r, c))

        var plate = w
        plate.translateBy(x: c.x, y: c.y)
        plate.rotate(by: .degrees(-28))
        for k in -5...5 {
            let x = Double(k) * 5
            plate.fill(Path(CGRect(x: x - 2.5, y: -r - 4, width: 5, height: 2 * r + 8)),
                       with: .linearGradient(Gradient(colors: [M.rgb(0x7A808A), M.rgb(0xC9CED5), M.rgb(0x6C727B)]),
                                             startPoint: CGPoint(x: x - 2.5, y: 0), endPoint: CGPoint(x: x + 2.5, y: 0)))
        }
        w.fill(M.circle(r, c), with: .color(.black.opacity(0.35)))

        // 擒纵轮：一跳转半个齿
        let b = (t * beats).rounded(.down)
        let esc = (b + M.spring((t * beats - b) / beats, omega: 80, zeta: 0.4)) * 12
        let ec = CGPoint(x: c.x + 10, y: c.y + 8)
        var teeth = Path()
        for k in 0..<15 {
            let a = esc + Double(k) * 24
            teeth.move(to: CGPoint(x: ec.x + 4 * cos(a * .pi / 180), y: ec.y + 4 * sin(a * .pi / 180)))
            teeth.addLine(to: CGPoint(x: ec.x + 8.5 * cos((a + 9) * .pi / 180), y: ec.y + 8.5 * sin((a + 9) * .pi / 180)))
            teeth.addLine(to: CGPoint(x: ec.x + 6.5 * cos((a + 16) * .pi / 180), y: ec.y + 6.5 * sin((a + 16) * .pi / 180)))
        }
        w.fill(M.circle(6.6, ec), with: .color(M.rgb(0xB8893A)))
        w.stroke(teeth, with: .color(M.rgb(0xD9AE5C)), lineWidth: 1)
        w.fill(M.circle(4, ec), with: .color(M.rgb(0x3A3F46)))

        // 摆轮：频率是跳数的一半，过中点时正好跳一下
        let swing = 150 * sin(.pi * beats * t)
        let gold = Gradient(colors: [M.rgb(0xF6DC9A), M.rgb(0xC79A45), M.rgb(0x7D5A1E)])
        var bal = w
        bal.translateBy(x: c.x, y: c.y)
        bal.rotate(by: .degrees(swing))
        var bsh = bal
        bsh.addFilter(.shadow(color: .black.opacity(0.6), radius: 1.5, x: 1, y: 1.5))
        bsh.stroke(M.circle(13.5), with: .linearGradient(gold, startPoint: CGPoint(x: -13, y: -13), endPoint: CGPoint(x: 13, y: 13)), lineWidth: 2.6)
        for k in 0..<3 {
            bal.stroke(line(.zero, M.polar(12.5, Double(k) * 120)), with: .color(M.rgb(0xC79A45)), lineWidth: 1.5)
        }
        for k in 0..<4 {
            bal.fill(M.circle(1.3, M.polar(15.2, Double(k) * 90 + 45)), with: .color(M.rgb(0xF1D58E)))
        }
        // 游丝：外端固定、内端跟着摆轮转，看起来一松一紧
        var spring = Path()
        for i in 0...90 {
            let u = Double(i) / 90
            let a = u * 3.5 * 2 * .pi + swing * .pi / 180 * (1 - u)
            let p = CGPoint(x: c.x + (2.2 + 7.6 * u) * cos(a), y: c.y + (2.2 + 7.6 * u) * sin(a))
            if i == 0 { spring.move(to: p) } else { spring.addLine(to: p) }
        }
        w.stroke(spring, with: .color(M.rgb(0x6F8FD8, 0.9)), lineWidth: 0.5)

        // 摆轮夹板 + 红宝石轴承
        var cock = w
        cock.addFilter(.shadow(color: .black.opacity(0.55), radius: 2, x: 1, y: 2))
        cylinder(&cock, CGPoint(x: c.x - 26, y: c.y - 12), c, 7, 5)
        cock.fill(M.circle(4.2, c), with: .radialGradient(Gradient(colors: [M.rgb(0xF4F6F9), M.rgb(0x8C929B)]),
                                                         center: CGPoint(x: c.x - 1.5, y: c.y - 1.5), startRadius: 0, endRadius: 6))
        w.fill(M.circle(1.9, c), with: .radialGradient(Gradient(colors: [M.rgb(0xFF6A7A), M.rgb(0xA0102A)]),
                                                      center: CGPoint(x: c.x - 0.6, y: c.y - 0.6), startRadius: 0, endRadius: 2.2))
        w.fill(M.circle(0.6, CGPoint(x: c.x - 0.7, y: c.y - 0.7)), with: .color(.white.opacity(0.8)))
        w.stroke(M.circle(r - 0.5, c), with: .color(.black.opacity(0.55)), lineWidth: 3)

        g.stroke(M.circle(r + 1, c), with: .linearGradient(Gradient(colors: [M.rgb(0xF4F6F9), M.rgb(0x6A7079), M.rgb(0xC9CED5)]),
                                                           startPoint: CGPoint(x: c.x - r, y: c.y - r), endPoint: CGPoint(x: c.x + r, y: c.y + r)),
                 lineWidth: 2.4)
    }

    /// 抛光立体刻度，12 点是双条；6 点被镂空窗占了
    static func drawIndices(_ g: inout GraphicsContext) {
        var sh = g
        sh.addFilter(.shadow(color: .black.opacity(0.65), radius: 1.5, x: 0.8, y: 1.4))
        for k in 0..<12 where k != 6 {
            let deg = Double(k) * 30 - 90
            let n = CGPoint(x: -sin(deg * .pi / 180), y: cos(deg * .pi / 180))
            for o in k == 0 ? [-3.6, 3.6] : [0.0] {
                let a = M.polar(63, deg), b = M.polar(79, deg)
                let hw = k == 0 ? 2.2 : (k % 3 == 0 ? 3.2 : 2.6)
                ridged(&sh, from: CGPoint(x: a.x + n.x * o, y: a.y + n.y * o), to: CGPoint(x: b.x + n.x * o, y: b.y + n.y * o),
                       profile: [(0, hw), (1, hw)])
            }
        }
    }

    /// 多面体（dauphine）时针、分针，橙色秒针带配重圈；三根针离表盘高度不同，影子也错开
    static func drawHands(_ g: inout GraphicsContext, hour: Double, minute: Double, second: Double) {
        func hand(_ value: Double, _ period: Double, tail: Double, length: Double, width: Double, height: Double) {
            let deg = value / period * 360 - 90
            var h = g
            h.addFilter(.shadow(color: .black.opacity(0.55), radius: 1 + height * 0.6, x: height * 0.5, y: height))
            h.drawLayer { l in
                ridged(&l, from: M.polar(-tail, deg), to: M.polar(length, deg), profile: [(0, width * 0.55), (0.16, width), (1, 0)])
                l.stroke(line(M.polar(length * 0.3, deg), M.polar(length * 0.78, deg)), with: .color(M.rgb(0xDDEFD6, 0.85)),
                         style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            }
        }
        hand(hour, 12, tail: 10, length: 52, width: 5.5, height: 2)
        hand(minute, 60, tail: 12, length: 78, width: 4.6, height: 3)
        sphere(&g, .zero, 5.2)

        let deg = second / 60 * 360 - 90
        let orange = M.rgb(0xFF8A3D)
        var s = g
        s.addFilter(.shadow(color: .black.opacity(0.5), radius: 2.5, x: 2, y: 4))
        s.drawLayer { l in
            l.stroke(line(M.polar(-12, deg), M.polar(86, deg)), with: .color(orange), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            l.stroke(line(M.polar(-12, deg), M.polar(-24, deg)), with: .color(orange), lineWidth: 2.2)
            l.stroke(M.circle(3.4, M.polar(-20, deg)), with: .color(orange), lineWidth: 1.4)
            l.fill(M.circle(3.2), with: .color(orange))
        }
        g.fill(M.circle(1.1), with: .color(M.rgb(0x2A1A10)))
    }

    /// 表镜：和机械眼的玻璃罩一样，左上一道弧形反光 + 小高光点 + 边缘压暗
    static func drawCrystal(_ g: inout GraphicsContext) {
        var glass = g
        glass.clip(to: M.circle(93))
        var arc = Path()
        arc.addArc(center: .zero, radius: 80, startAngle: .degrees(200), endAngle: .degrees(255), clockwise: false)
        glass.stroke(arc, with: .color(.white.opacity(0.16)), style: StrokeStyle(lineWidth: 8, lineCap: .round))
        var spot = glass
        spot.addFilter(.blur(radius: 3))
        spot.fill(M.circle(5, CGPoint(x: -44, y: -54)), with: .color(.white.opacity(0.3)))
        glass.fill(M.circle(93), with: .radialGradient(Gradient(colors: [.clear, .black.opacity(0.3)]),
                                                       center: .zero, startRadius: 65, endRadius: 94))
    }
}

// MARK: - 保险库门

/// 保险库门：方形拉丝钢墙板里嵌一扇厚圆门，门中间是船舵式转轮，轮毂是密码盘。
/// 密码盘每 1.6 秒拨到一个新数字（左右交替，带一点过冲），拨完三个数，转轮沉沉地拧 90° 再回位
enum VaultArt {
    static let slot = 1.6

    /// 第 m 次拨号停在的角度
    static func stop(_ m: Int) -> Double { M.rand(m, 51) * 360 }

    /// 第 m 次拨号拨到一半时的角度：偶数次顺时针、奇数次逆时针，至少转 120°
    static func dialAngle(_ m: Int, _ tau: Double) -> Double {
        let dir = m % 2 == 0 ? 1.0 : -1.0
        var delta = ((stop(m) - stop(m - 1)) * dir).truncatingRemainder(dividingBy: 360)
        if delta < 0 { delta += 360 }
        if delta < 120 { delta += 360 }
        return stop(m - 1) + dir * delta * M.spring(tau, omega: 9, zeta: 0.7)
    }

    static func draw(_ g: inout GraphicsContext, size: CGSize, t: Double) {
        M.unitSpace(&g, size)
        // 一轮 4 段：前 3 段各拨一个数，第 4 段拧转轮
        let cycle = Int((t / (4 * slot)).rounded(.down))
        let within = t - Double(cycle) * 4 * slot
        let k = min(3, Int((within / slot).rounded(.down)))
        let tau = within - Double(k) * slot
        let dial = k < 3 ? dialAngle(cycle * 3 + k, tau) : dialAngle(cycle * 3 + 2, slot)
        let wheel = k < 3 ? 0 : 90 * (M.spring(tau - 0.1, omega: 14, zeta: 0.55) - M.spring(tau - 0.8, omega: 14, zeta: 0.6))

        drawWall(&g)
        drawDoor(&g)
        drawWheel(&g, wheel)
        drawDial(&g, dial)
    }

    /// 墙板：横向拉丝的方形钢板（比门暗一档，把门衬出来）+ 四角螺丝 + 门缝
    static func drawWall(_ g: inout GraphicsContext) {
        let plate = Path(roundedRect: CGRect(x: -108, y: -108, width: 216, height: 216), cornerRadius: 28)
        var sh = g
        sh.addFilter(.shadow(color: .black.opacity(0.55), radius: 10, y: 6))
        sh.fill(plate, with: .color(M.rgb(0x6E737C)))
        g.fill(plate, with: .linearGradient(Gradient(colors: [0x4F565F, 0x8A919B, 0x5E656E, 0x9AA1AA, 0x535A63].map { M.rgb($0) }),
                                            startPoint: CGPoint(x: -108, y: -108), endPoint: CGPoint(x: 108, y: 108)))
        var brush = g
        brush.clip(to: plate)
        var lines = Path()
        for k in 0..<72 {
            let y = -108 + Double(k) * 3
            lines.move(to: CGPoint(x: -108, y: y))
            lines.addLine(to: CGPoint(x: 108, y: y))
        }
        brush.stroke(lines, with: .color(.white.opacity(0.06)), lineWidth: 0.6)
        g.stroke(plate, with: bevel(108, hi: 0.6, lo: 0.45), lineWidth: 1.6)
        for (x, y) in [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)] {
            M.screw(&g, CGPoint(x: x * 92, y: y * 92), r: 4.6, slot: x * y * 0.7)
        }
        g.fill(M.circle(100), with: .color(M.rgb(0x0A0B0D)))
        g.stroke(M.circle(100), with: bevel(100, hi: 0.4, lo: 0.7, inset: true), lineWidth: 1.6)
    }

    /// 门：一圈很宽的抛光斜边显出门的厚度，门面拉丝 + 几道浅车削纹，边缘压暗
    static func drawDoor(_ g: inout GraphicsContext) {
        var sh = g
        sh.addFilter(.shadow(color: .black.opacity(0.6), radius: 4, y: 3))
        sh.fill(M.circle(96), with: .color(M.rgb(0x6E737C)))
        g.fill(M.ring(96, 84), with: .linearGradient(Gradient(colors: [M.rgb(0xF4F6F9), M.rgb(0xA9AFB8), M.rgb(0x5D636B), M.rgb(0x8E959E)]),
                                                     startPoint: CGPoint(x: -80, y: -80), endPoint: CGPoint(x: 80, y: 80)),
               style: FillStyle(eoFill: true))
        g.stroke(M.circle(95.4), with: bevel(95), lineWidth: 1.2)
        g.stroke(M.circle(84), with: .color(.black.opacity(0.45)), lineWidth: 1.2)
        g.fill(M.circle(83.4), with: .conicGradient(M.brushed, center: .zero, angle: .degrees(70)))
        var lathe = Path()
        for k in 0..<4 { lathe.addPath(M.circle(64 + Double(k) * 5)) }
        g.stroke(lathe, with: .color(.black.opacity(0.12)), lineWidth: 0.8)
        g.fill(M.circle(83.4), with: .radialGradient(Gradient(colors: [.clear, .black.opacity(0.28)]),
                                                     center: .zero, startRadius: 50, endRadius: 84))
    }

    /// 船舵式转轮：6 根辐条伸出轮缘，末端是握把和球头
    static func drawWheel(_ g: inout GraphicsContext, _ angle: Double) {
        var sh = g
        sh.addFilter(.shadow(color: .black.opacity(0.6), radius: 5, x: 2.5, y: 5))
        sh.drawLayer { l in
            for k in 0..<6 {
                let deg = angle - 90 + Double(k) * 60
                cylinder(&l, M.polar(20, deg), M.polar(60, deg), 8.5, 6)
                cylinder(&l, M.polar(59, deg), M.polar(68, deg), 7.4, 7.4)
                sphere(&l, M.polar(70.5, deg), 5.8)
            }
            l.fill(M.ring(53, 45), with: .linearGradient(Gradient(colors: [M.rgb(0xF1F3F6), M.rgb(0xA7ADB6), M.rgb(0x5D636B), M.rgb(0x8E959E)]),
                                                         startPoint: CGPoint(x: -48, y: -48), endPoint: CGPoint(x: 48, y: 48)),
                   style: FillStyle(eoFill: true))
            l.stroke(M.circle(53), with: bevel(53, hi: 0.7, lo: 0.5), lineWidth: 1)
            l.stroke(M.circle(45), with: bevel(45, hi: 0.4, lo: 0.6, inset: true), lineWidth: 1)
        }
    }

    /// 密码盘：抛光底座 + 转动的黑色刻度盘（50 格）+ 滚花旋钮；12 点固定一个橙色对位标
    static func drawDial(_ g: inout GraphicsContext, _ angle: Double) {
        var sh = g
        sh.addFilter(.shadow(color: .black.opacity(0.55), radius: 3, y: 2.5))
        sh.fill(M.circle(28), with: .radialGradient(Gradient(colors: [M.rgb(0xF4F6F9), M.rgb(0x9AA1AA), M.rgb(0x4E535B)]),
                                                    center: CGPoint(x: -9, y: -11), startRadius: 0, endRadius: 40))
        g.stroke(M.circle(28), with: .color(.black.opacity(0.45)), lineWidth: 1)

        var d = g
        d.rotate(by: .degrees(angle))
        d.fill(M.circle(24), with: .radialGradient(Gradient(colors: [M.rgb(0x2A2E35), M.rgb(0x0C0D10)]),
                                                   center: .zero, startRadius: 8, endRadius: 24))
        var minor = Path(), major = Path()
        for k in 0..<50 {
            let deg = Double(k) * 7.2
            if k % 5 == 0 {
                major.move(to: M.polar(16.5, deg))
                major.addLine(to: M.polar(23, deg))
            } else {
                minor.move(to: M.polar(19.5, deg))
                minor.addLine(to: M.polar(23, deg))
            }
        }
        d.stroke(minor, with: .color(.white.opacity(0.45)), lineWidth: 0.6)
        d.stroke(major, with: .color(.white.opacity(0.9)), lineWidth: 1.1)
        d.fill(M.circle(1.6, M.polar(14, -90)), with: .color(M.rgb(0xFF8A3D)))

        var knob = d
        knob.addFilter(.shadow(color: .black.opacity(0.6), radius: 2, y: 1.5))
        knob.fill(M.circle(12.5), with: .radialGradient(Gradient(colors: [M.rgb(0xF7F8FA), M.rgb(0x9097A0), M.rgb(0x41454C)]),
                                                         center: CGPoint(x: -4, y: -5), startRadius: 0, endRadius: 18))
        var knurl = Path()
        for k in 0..<30 {
            knurl.move(to: M.polar(10.6, Double(k) * 12))
            knurl.addLine(to: M.polar(12.4, Double(k) * 12))
        }
        d.stroke(knurl, with: .color(.black.opacity(0.35)), lineWidth: 0.8)
        d.fill(M.circle(5.5), with: .radialGradient(Gradient(colors: [M.rgb(0xFFFFFF), M.rgb(0xA8AEB7)]),
                                                    center: CGPoint(x: -1.8, y: -2.2), startRadius: 0, endRadius: 7))

        var mark = Path()
        mark.addLines([M.polar(24.5, -90), M.polar(29.5, -95), M.polar(29.5, -85)])
        mark.closeSubpath()
        g.fill(mark, with: .color(M.rgb(0xFF8A3D)))
    }
}

// MARK: - 挂锁

/// 叠片钢挂锁：抛光钢锁梁、一片片叠起来的拉丝钢锁身、四角铆钉、黄铜锁芯。
/// 每 7 秒验一次锁：锁芯拧一下，锁梁往下一沉坐实、锁身跟着一震，锁芯回位，一道反光从锁身扫过
enum PadlockArt {
    static let cycle = 7.0
    static let body = CGRect(x: -56, y: -16, width: 112, height: 86)
    static let plug = CGPoint(x: 0, y: 34)

    static func draw(_ g: inout GraphicsContext, size: CGSize, t: Double) {
        M.unitSpace(&g, size)
        g.translateBy(x: 0, y: 10)                // 锁梁在上，整体视觉中心往下挪一点
        let tau = t - (t / cycle).rounded(.down) * cycle
        let turn = 38 * (M.spring(tau, omega: 30, zeta: 0.55) - M.spring(tau - 0.75, omega: 26, zeta: 0.5))
        let seat = 3 * (M.spring(tau - 0.3, omega: 60, zeta: 0.4) - M.spring(tau - 0.5, omega: 30, zeta: 0.45))
        let hit = tau - 0.32
        let shake = hit > 0 ? 1.1 * exp(-hit * 10) * sin(hit * 75) : 0
        let glow = 0.55 + 0.25 * sin(t * 2 * .pi / 3.2) + 0.4 * max(0, 1 - abs(tau - 0.4) / 0.4)

        var lock = g
        lock.translateBy(x: shake * 0.3, y: shake)
        drawShackle(&lock, drop: seat)
        drawBody(&lock)
        drawPlug(&lock, turn: turn, glow: glow)
        drawShine(&lock, tau: tau)
    }

    /// 锁梁：粗钢棒弯成 U 形，按圆柱打光：左腿和顶上外侧亮、右腿里侧亮
    static func drawShackle(_ g: inout GraphicsContext, drop: Double) {
        let y0 = body.minY + 6, top = body.minY - 30 + drop, r = 36.0
        func u(_ rr: Double, from: Double, to: Double, leftLeg: Bool, rightLeg: Bool) -> Path {
            var p = Path()
            if leftLeg {
                p.move(to: CGPoint(x: -rr, y: y0))
                p.addLine(to: CGPoint(x: -rr, y: top))
            }
            p.addArc(center: CGPoint(x: 0, y: top), radius: rr, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
            if rightLeg { p.addLine(to: CGPoint(x: rr, y: y0)) }
            return p
        }
        let bar = u(r, from: 180, to: 360, leftLeg: true, rightLeg: true)
        var sh = g
        sh.addFilter(.shadow(color: .black.opacity(0.5), radius: 6, x: 2, y: 5))
        sh.stroke(bar, with: .color(M.rgb(0x33373D)), style: StrokeStyle(lineWidth: 17))
        g.stroke(bar, with: .linearGradient(Gradient(colors: [M.rgb(0xEEF1F5), M.rgb(0xA4ABB5), M.rgb(0x6A7079), M.rgb(0x9097A1)]),
                                            startPoint: CGPoint(x: -40, y: top - 40), endPoint: CGPoint(x: 40, y: y0)),
                 style: StrokeStyle(lineWidth: 14.5))
        g.stroke(u(r + 3.6, from: 180, to: 290, leftLeg: true, rightLeg: false), with: .color(.white.opacity(0.75)),
                 style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        g.stroke(line(CGPoint(x: r - 3.6, y: top + 4), CGPoint(x: r - 3.6, y: y0)), with: .color(.white.opacity(0.45)),
                 style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        g.stroke(u(r + 4, from: 310, to: 360, leftLeg: false, rightLeg: true), with: .color(.black.opacity(0.35)),
                 style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        g.stroke(u(r - 4, from: 200, to: 300, leftLeg: false, rightLeg: false), with: .color(.black.opacity(0.25)),
                 style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    /// 锁身：9 片拉丝钢叠起来，每片反光位置略错开；两侧压暗显出厚度；四角铆钉；锁梁入口的护圈
    static func drawBody(_ g: inout GraphicsContext) {
        let shape = Path(roundedRect: body, cornerRadius: 9)
        var sh = g
        sh.addFilter(.shadow(color: .black.opacity(0.55), radius: 9, y: 6))
        sh.fill(shape, with: .color(M.rgb(0x6E737C)))

        var plates = g
        plates.clip(to: shape)
        let n = 9, h = body.height / 9
        let sheen = Gradient(colors: [0x7C838D, 0xC9CED5, 0xEEF1F4, 0xA3AAB3, 0xD3D8DE, 0x8A919B].map { M.rgb($0) })
        for k in 0..<n {
            let r = CGRect(x: body.minX, y: body.minY + Double(k) * h, width: body.width, height: h)
            let shift = (M.rand(k, 41) - 0.5) * 22
            plates.fill(Path(r), with: .linearGradient(sheen, startPoint: CGPoint(x: body.minX + shift, y: 0),
                                                       endPoint: CGPoint(x: body.maxX + shift, y: 0)))
            plates.stroke(line(CGPoint(x: body.minX, y: r.minY + 0.5), CGPoint(x: body.maxX, y: r.minY + 0.5)),
                          with: .color(.white.opacity(0.5)), lineWidth: 0.8)
            plates.stroke(line(CGPoint(x: body.minX, y: r.maxY - 0.4), CGPoint(x: body.maxX, y: r.maxY - 0.4)),
                          with: .color(.black.opacity(0.45)), lineWidth: 0.8)
        }
        plates.fill(Path(body), with: .linearGradient(Gradient(stops: [.init(color: .black.opacity(0.35), location: 0),
                                                                       .init(color: .clear, location: 0.12),
                                                                       .init(color: .clear, location: 0.88),
                                                                       .init(color: .black.opacity(0.45), location: 1)]),
                                                      startPoint: CGPoint(x: body.minX, y: 0), endPoint: CGPoint(x: body.maxX, y: 0)))
        g.stroke(shape, with: .color(.black.opacity(0.5)), lineWidth: 1)

        for x in [body.minX + 9, body.maxX - 9] {
            for y in [body.minY + 9, body.maxY - 9] {
                g.fill(M.circle(4.3, CGPoint(x: x + 0.6, y: y + 1)), with: .color(.black.opacity(0.35)))
                sphere(&g, CGPoint(x: x, y: y), 3.8)
            }
        }
        for x in [-36.0, 36] {
            let collar = Path(roundedRect: CGRect(x: x - 11, y: body.minY - 3.5, width: 22, height: 7.5), cornerRadius: 3.5)
            g.fill(collar, with: .linearGradient(Gradient(colors: [M.rgb(0xF4F6F9), M.rgb(0x8C929B), M.rgb(0x5A6068)]),
                                                 startPoint: CGPoint(x: x, y: body.minY - 3.5), endPoint: CGPoint(x: x, y: body.minY + 4)))
            g.stroke(collar, with: .color(.black.opacity(0.4)), lineWidth: 0.8)
        }
    }

    /// 黄铜锁芯：下凹的钢外壳 + 车削纹黄铜芯 + 锁孔，锁孔里透出一点橙光
    static func drawPlug(_ g: inout GraphicsContext, turn: Double, glow: Double) {
        let c = plug
        g.fill(M.circle(19.5, c), with: .radialGradient(Gradient(colors: [M.rgb(0x5A6068), M.rgb(0xB9BFC7)]),
                                                       center: CGPoint(x: c.x - 5, y: c.y - 6), startRadius: 0, endRadius: 26))
        g.stroke(M.circle(19.5, c), with: bevel(19.5, at: c, hi: 0.55, lo: 0.45), lineWidth: 1.4)
        g.stroke(M.circle(15.6, c), with: bevel(15.6, at: c, hi: 0.35, lo: 0.6, inset: true), lineWidth: 1.4)

        g.fill(M.circle(14.6, c), with: .radialGradient(Gradient(colors: [M.rgb(0xFBE7B0), M.rgb(0xD6A54C), M.rgb(0x8A611F)]),
                                                       center: CGPoint(x: c.x + light.x * 6, y: c.y + light.y * 6), startRadius: 0, endRadius: 22))
        for rr in stride(from: 4.0, to: 14.5, by: 1.5) {
            g.stroke(M.circle(rr, c), with: .color(.black.opacity(0.06)), lineWidth: 0.5)
        }
        g.stroke(M.circle(14.7, c), with: .color(.black.opacity(0.6)), lineWidth: 0.8)

        var k = g
        k.translateBy(x: c.x, y: c.y)
        k.rotate(by: .degrees(turn))
        var slot = Path()
        slot.addRoundedRect(in: CGRect(x: -1.9, y: -11, width: 3.8, height: 21), cornerSize: CGSize(width: 1.5, height: 1.5))
        slot.addRect(CGRect(x: -1.9, y: -5, width: 5.4, height: 2.6))
        slot.addRect(CGRect(x: -3.5, y: 2.5, width: 3.6, height: 2.6))
        k.fill(slot, with: .color(M.rgb(0x15171B)))
        var ember = k
        ember.clip(to: slot)
        ember.fill(M.circle(12), with: .radialGradient(Gradient(colors: [M.rgb(0xFF7A2A, min(1, 0.85 * glow)), M.rgb(0xB0200A, 0.4 * glow), .clear]),
                                                       center: .zero, startRadius: 0, endRadius: 12))
        k.fill(M.circle(1.1, CGPoint(x: 0, y: -12.8)), with: .color(.black.opacity(0.55)))
    }

    /// 反光：锁梁坐实之后，一条斜带 0.9 秒从左扫到右
    static func drawShine(_ g: inout GraphicsContext, tau: Double) {
        let k = (tau - 0.9) / 0.9
        guard k > 0, k < 1 else { return }
        var shine = g
        shine.clip(to: Path(roundedRect: body, cornerRadius: 9))
        shine.blendMode = .plusLighter
        shine.addFilter(.blur(radius: 5))
        let x = -110 + 220 * smoothstep(k)
        var band = Path()
        band.addLines([CGPoint(x: x - 14, y: body.maxY + 4), CGPoint(x: x + 14, y: body.maxY + 4),
                       CGPoint(x: x + 54, y: body.minY - 4), CGPoint(x: x + 26, y: body.minY - 4)])
        band.closeSubpath()
        shine.fill(band, with: .color(.white.opacity(0.35 * sin(k * .pi))))
    }
}

// MARK: - 魔瞳

/// 魔瞳：竖着的杏仁形眼眶（像天眼）里一只发光的竖瞳，背后一圈慢慢转的符文法阵。
/// 眼珠沿用机械眼的注视节奏（转到新位置带过冲），上下转得多、左右转得少；转眼时竖瞳先张开、再收窄对焦；偶尔眨一下眼
enum DemonEye {
    static let ember = M.rgb(0xFF5A1F)

    struct Pose {
        var gaze: CGPoint      // 眼珠偏移
        var slit: Double       // 竖瞳半宽
        var open: Double       // 眼睑张开程度，0 = 闭上
        var glow: Double       // 发光强度
    }

    static func pose(_ t: Double, _ stare: MechEye.Stare? = nil) -> Pose {
        let p = M.pose(t, stare)
        let i = M.slotIndex(t)
        let tau = t - M.moveTime(i)
        var slit = 3.5 + 3.5 * M.rand(i, 8) + 7 * M.kick(tau, peak: 0.15)
        var open = 1.0
        if M.rand(i, 7) < 0.18 {
            let b = tau - 1.0
            if b > 0, b < 0.07 { open = 1 - b / 0.07 }
            else if b >= 0.07, b < 0.11 { open = 0 }
            else if b >= 0.11 { open = min(1, M.spring(b - 0.11, omega: 24, zeta: 0.7)) }
        }
        // 盯光标时竖瞳收窄，每跳一下先张开再收回；不眨眼
        if let s = stare {
            let l = M.lock(t, s)
            slit += (2.5 + 7 * M.kick(t - s.hop.t, peak: 0.15) - slit) * l
            open += (1 - open) * l
        }
        return Pose(gaze: CGPoint(x: p.gaze.x * 0.9, y: p.gaze.y * 1.9), slit: slit, open: open, glow: p.glow)
    }

    static func draw(_ g: inout GraphicsContext, size: CGSize, t: Double, stare: MechEye.Stare?) {
        M.unitSpace(&g, size)
        let p = pose(t, stare)
        drawSigil(&g, t: t, glow: p.glow)
        let eye = almond(p.open)

        var rim = g
        rim.blendMode = .plusLighter
        rim.addFilter(.blur(radius: 7))
        rim.stroke(eye, with: .color(ember.opacity(0.55 * p.glow)), lineWidth: 7)

        var inside = g
        inside.clip(to: eye)
        let box = Path(CGRect(x: -100, y: -100, width: 200, height: 200))
        inside.fill(box, with: .radialGradient(Gradient(colors: [M.rgb(0x2E0B0D), M.rgb(0x0A0203)]), center: .zero, startRadius: 10, endRadius: 100))
        drawIris(&inside, p)
        // 眼睑压在眼球上的阴影顺着眼眶走，光从左上来，阴影往右下偏；上下眼角压暗
        var shade = inside
        shade.translateBy(x: 1.5, y: 2.5)
        shade.addFilter(.blur(radius: 7))
        shade.stroke(eye, with: .color(.black.opacity(0.85)), lineWidth: 20)
        inside.fill(box, with: .radialGradient(Gradient(colors: [.clear, .black.opacity(0.65)]), center: .zero, startRadius: 50, endRadius: 100))
        g.stroke(eye, with: .color(M.rgb(0x140405)), lineWidth: 3)
        g.stroke(eye, with: .color(M.rgb(0xFF8A3D, 0.5)), lineWidth: 0.8)
    }

    /// 竖着的杏仁形眼眶；左右两片眼睑往中间合，open = 0 时合成一条竖线
    static func almond(_ open: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 3, y: -94))
        p.addQuadCurve(to: CGPoint(x: -2, y: 94), control: CGPoint(x: 84 * open, y: -4))
        p.addQuadCurve(to: CGPoint(x: 3, y: -94), control: CGPoint(x: -80 * open, y: 6))
        p.closeSubpath()
        return p
    }

    /// 符文法阵：三道细圈夹着一圈 24 个符文，60 秒转一圈，带一层余光。
    /// 每个符文是一根竖笔加上几种附加笔画（横、斜、顶上的小圈、尖角），组合由编号决定
    static func drawSigil(_ g: inout GraphicsContext, t: Double, glow: Double) {
        var c = g
        c.rotate(by: .degrees(t * 6))
        var rings = Path()
        for r in [114.0, 110.5, 95.5] { rings.addPath(M.circle(r)) }
        var glyphs = Path()
        for k in 0..<24 {
            let base = Double(k) * 15
            func pt(_ u: Double, _ v: Double) -> CGPoint { M.polar(98.5 + v * 9.5, base + u * 3.2) }
            let bits = Int(M.rand(k, 61) * 16)
            glyphs.move(to: pt(0, 0)); glyphs.addLine(to: pt(0, 1))
            if bits & 1 != 0 { glyphs.move(to: pt(-0.8, 0.45)); glyphs.addLine(to: pt(0.8, 0.45)) }
            if bits & 2 != 0 { glyphs.move(to: pt(0, 0.7)); glyphs.addLine(to: pt(0.9, 0.2)) }
            if bits & 4 != 0 { glyphs.move(to: pt(-0.9, 1)); glyphs.addLine(to: pt(0, 0.65)); glyphs.addLine(to: pt(0.9, 1)) }
            if bits & 8 != 0 || bits == 0 { glyphs.move(to: pt(-0.8, 0)); glyphs.addLine(to: pt(0, 0.3)) }
            glyphs.addPath(M.circle(0.9, M.polar(102.8, base + 7.5)))
        }
        var halo = c
        halo.blendMode = .plusLighter
        halo.addFilter(.blur(radius: 3))
        halo.stroke(rings, with: .color(ember.opacity(0.45 * glow)), lineWidth: 2.5)
        halo.stroke(glyphs, with: .color(ember.opacity(0.55 * glow)), lineWidth: 2.5)
        c.stroke(rings, with: .color(M.rgb(0xFFB070, 0.7)), lineWidth: 0.8)
        c.stroke(glyphs, with: .color(M.rgb(0xFFCF9A, 0.9)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
    }

    /// 虹膜：金 → 橙 → 深红的放射纤维，外圈一道暗环；竖瞳边缘发烫；跟着注视方向压扁，假装是球面在转
    static func drawIris(_ g: inout GraphicsContext, _ p: Pose) {
        let r = 44.0
        let d = hypot(p.gaze.x, p.gaze.y)
        let dir = Angle.radians(atan2(p.gaze.y, p.gaze.x))
        var e = g
        e.translateBy(x: p.gaze.x, y: p.gaze.y)
        e.rotate(by: dir)
        e.scaleBy(x: 1 - 0.16 * min(d / (M.maxGaze * 1.9), 1.2), y: 1)
        e.rotate(by: -dir)

        var bloom = e
        bloom.blendMode = .plusLighter
        bloom.fill(M.circle(r + 20), with: .radialGradient(Gradient(colors: [ember.opacity(0.4 * p.glow), .clear]),
                                                           center: .zero, startRadius: r - 6, endRadius: r + 20))
        let stops: [(UInt32, Double)] = [(0xFFE08A, 0), (0xFFA22E, 0.26), (0xE8451A, 0.52), (0x9E0E12, 0.8), (0x2A0204, 1)]
        e.fill(M.circle(r), with: .radialGradient(Gradient(stops: stops.map { .init(color: M.rgb($0.0), location: $0.1) }),
                                                  center: .zero, startRadius: 0, endRadius: r))
        var bright = Path(), dark = Path()
        for k in 0..<120 {
            let a = Double(k) * 3 + 2 * M.rand(k, 71)
            let r0 = 8 + 10 * M.rand(k, 72), r1 = 28 + 14 * M.rand(k, 73)
            if k % 2 == 0 {
                bright.move(to: M.polar(r0, a)); bright.addLine(to: M.polar(r1, a))
            } else {
                dark.move(to: M.polar(r0, a)); dark.addLine(to: M.polar(r1, a))
            }
        }
        e.stroke(bright, with: .color(M.rgb(0xFFD27A, 0.35)), lineWidth: 0.7)
        e.stroke(dark, with: .color(M.rgb(0x3A0306, 0.45)), lineWidth: 0.8)
        var collar = Path()
        for k in 0...48 {
            let pt = M.polar(16 + 2.5 * M.rand(k % 48, 74), Double(k) * 7.5)
            if k == 0 { collar.move(to: pt) } else { collar.addLine(to: pt) }
        }
        e.stroke(collar, with: .color(M.rgb(0xFFE6A0, 0.4)), lineWidth: 0.9)
        e.stroke(M.circle(r - 1.2), with: .color(.black.opacity(0.75)), lineWidth: 3)

        var slit = Path()
        slit.move(to: CGPoint(x: 0, y: -36))
        slit.addQuadCurve(to: CGPoint(x: 0, y: 36), control: CGPoint(x: p.slit * 2, y: 0))
        slit.addQuadCurve(to: CGPoint(x: 0, y: -36), control: CGPoint(x: -p.slit * 2, y: 0))
        var hot = e
        hot.blendMode = .plusLighter
        hot.addFilter(.blur(radius: 3))
        hot.stroke(slit, with: .color(M.rgb(0xFFB040, 0.6 * p.glow)), lineWidth: 3.5)
        e.fill(slit, with: .color(.black))

        // 角膜上的湿润反光，跟着眼珠走
        var wet = e
        wet.addFilter(.blur(radius: 1.2))
        wet.fill(Path(ellipseIn: CGRect(x: -24, y: -27, width: 13, height: 7)), with: .color(.white.opacity(0.7)))
        wet.fill(M.circle(2, CGPoint(x: 15, y: 17)), with: .color(.white.opacity(0.35)))
    }
}

// MARK: - 镇宅符

/// 镇宅符：照《太上秘法镇宅灵符》（正统道藏洞真部神符类）第三十道描的，原注「盗贼不侵，万事称意」。
/// 底本是识典古籍的影印本，坐标从原图上量下来再按比例缩到纸面；只是把墨线换成黄纸朱砂。
/// 顶上是连线的星点，下面左右两列「日」字框夹着中间一列复文（共、罒、非、日、生、大、土、口）。
/// 一张悬空、微微飘着的黄符纸，按从上到下、一行一行的顺序写出来，笔尖发烫；写完整张亮一下，余光呼吸一阵，最后褪掉重写
enum TalismanArt {
    static let paper = CGRect(x: -46, y: -106, width: 92, height: 212)
    static let cycle = 14.0
    static let writing = (start: 0.5, end: 7.5)
    static let still = 10.0                 // 停在一帧时画周期里的这一刻：写完了、余光还在
    static let cinnabar: UInt32 = 0xC42218

    struct Stroke {
        var pts: [CGPoint]
        var width: Double
        var smooth = false                  // true：Catmull-Rom 顺滑经过各点；false：折线，转角是尖的
    }

    /// 原图坐标（影印本裁图上的像素）换到纸面坐标
    static func src(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: (x - 169.5) * 0.33, y: (y - 398.5) * 0.33) }

    static let strokes: [Stroke] = {
        var s: [Stroke] = []
        func line(_ p: (Double, Double)...) { s.append(Stroke(pts: p.map { src($0.0, $0.1) }, width: 1.6)) }
        func curve(_ p: (Double, Double)...) { s.append(Stroke(pts: p.map { src($0.0, $0.1) }, width: 1.6, smooth: true)) }
        /// 星点：从正上方起顺时针一圈
        func star(_ x: Double, _ y: Double) {
            s.append(Stroke(pts: (0...24).map { k in src(x + 6 * sin(Double(k) * .pi / 12), y - 6 * cos(Double(k) * .pi / 12)) }, width: 1.2))
        }
        /// 两点之间的连线，碰到星点的一头留出星的半径
        func link(_ a: (Double, Double), _ b: (Double, Double), fromStar: Bool = true, toStar: Bool = true) {
            let len = hypot(b.0 - a.0, b.1 - a.1), u = ((b.0 - a.0) / len, (b.1 - a.1) / len)
            let ra = fromStar ? 6.0 : 0, rb = toStar ? 6.0 : 0
            line((a.0 + u.0 * ra, a.1 + u.1 * ra), (b.0 - u.0 * rb, b.1 - u.1 * rb))
        }
        /// 日字框：左竖、上横、右竖、中横、下横，四个角往外挑一下；mid 为 nil 时是口字
        func box(_ x0: Double, _ x1: Double, _ y0: Double, _ mid: Double?, _ y1: Double, midFrom: Double? = nil) {
            let d = 3.0
            line((x0, y0), (x0, y1))
            line((x0 - d, y0 - d), (x0, y0), (x1, y0), (x1 + d, y0 - d))
            line((x1, y0), (x1, y1))
            if let mid { line((midFrom ?? x0, mid), (x1, mid)) }
            line((x0 - d, y1 + d), (x0, y1), (x1, y1), (x1 + d, y1 + d))
        }
        func left(_ y0: Double, _ mid: Double, _ y1: Double, midFrom: Double? = nil) { box(77.5, 135, y0, mid, y1, midFrom: midFrom) }
        func right(_ y0: Double, _ mid: Double, _ y1: Double) { box(207, 261.5, y0, mid, y1) }

        // 星点和连线
        star(75.6, 136); link((75.6, 136), (253.4, 135.3)); star(253.4, 135.3)
        star(75.3, 167); link((75.3, 167), (122, 148.4)); star(122, 148.4); link((122, 148.4), (168.4, 164.7)); star(168.4, 164.7)
        let (ul, ur, c, ll, lr) = ((115.4, 186.3), (219.3, 185.9), (167.5, 207.2), (115.4, 227.5), (220.8, 227.5))
        star(ul.0, ul.1); link(ul, c); star(c.0, c.1); link(c, lr); star(lr.0, lr.1)
        star(ll.0, ll.1); link(ll, c); link(c, ur); star(ur.0, ur.1)
        for y in [203.0, 235] { star(75.3, y) }
        star(77, 274.4)
        for y in [168.4, 203, 237] { star(252.3, y) }
        star(256.6, 273.4)
        link((93.4, 269), (135.6, 255.6), fromStar: false); star(135.6, 255.6); link((135.6, 255.6), (203, 276)); star(203, 276)

        // 第一行：日、共、己字回折
        left(289.3, 309, 328.6, midFrom: 82)
        line((141, 295), (195.6, 295)); line((156, 283.6), (156, 309)); line((178.8, 283.6), (178.8, 309))
        line((139, 313.6), (195.6, 313.6)); line((157, 321), (147, 332.4)); line((175, 321), (190, 332.4))
        line((199.2, 286.7), (207.1, 292.2), (261.5, 292.2), (264.6, 288.6)); line((261.5, 292.2), (261.5, 310), (264.6, 315.5))
        line((199.8, 304.4), (207.1, 310), (261.5, 310)); line((207.1, 310), (207.1, 330.1), (203.4, 333.8))
        line((207.1, 330.1), (261.5, 330.1))
        // 第二行：日、罒、缺左上角的日
        left(345.5, 364.6, 382)
        line((145, 345.5), (145, 363)); line((145, 345.5), (197.5, 345.5), (197.5, 363))
        line((162, 345.5), (162, 363)); line((176, 345.5), (176, 363)); line((145, 363), (197.5, 363))
        line((265.2, 325.2), (261.5, 330.1), (261.5, 380.9), (269.5, 386.4)); line((201.6, 350.3), (205.9, 354), (261.5, 354))
        line((207.1, 354), (207.1, 380.9)); line((203.4, 383.9), (207.1, 380.9), (261.5, 380.9))
        // 第三行：日、非、日
        left(397, 412.6, 429)
        line((162, 365), (162, 421), (159.5, 427))
        for y in [379.0, 395, 407.4] { line((143, y), (162, y)) }
        line((178, 365), (178, 426))
        for y in [375.5, 391.4, 405.5] { line((178, y), (192, y)) }
        right(395, 412, 428)
        // 第四到第八行：左右都是日字框，中间日、生、大、土、口
        left(443, 458.4, 474, midFrom: 85); box(151.6, 189, 435.5, 455.2, 476.8); right(443, 459, 473)
        left(489.3, 505.2, 522)
        line((152, 491), (146, 502)); line((149, 495), (190, 495)); line((149.7, 512.7), (190, 512.7))
        line((169.4, 478), (169.4, 528.6)); line((145, 528.6), (193.8, 528.6))
        right(489.3, 505.2, 521)
        left(537, 554, 569.5)
        line((143, 554), (193.8, 554)); line((169.4, 536), (169.4, 558.6))
        curve((167.5, 561.4), (157.2, 568), (152.5, 583), (147.8, 597)); curve((175, 562.4), (186.3, 568), (190, 583), (198.4, 598))
        right(536, 552, 569)
        left(585, 601.8, 617.7)
        line((145, 606.4), (195.6, 606.4)); line((169.4, 593), (169.4, 620.5)); line((148.8, 619.6), (190, 619.6))
        right(584, 601.8, 616.8)
        left(631.8, 647.7, 663.6); box(154.4, 189, 631.8, nil, 659); right(631.8, 647.7, 663.6)
        return s
    }()

    /// 写完的笔画形状是固定的，先算好；正在写的那一笔每帧现算
    static let shapes: [(body: Path, caps: Path, tip: CGPoint)] = strokes.map { brush($0, upTo: 1) }

    /// 每一笔开始和写完的时刻（周期内）：先按长度排出时长（太短的也给一点时间），笔与笔之间稍停，再整体缩放到书写时段里
    static let schedule: [(start: Double, end: Double)] = {
        var t = 0.0
        let raw = strokes.map { st -> (Double, Double) in
            let d = max(0.05, zip(st.pts, st.pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } / 300)
            defer { t += d + 0.03 }
            return (t, t + d)
        }
        let k = (writing.end - writing.start) / raw[raw.count - 1].1
        return raw.map { (writing.start + $0.0 * k, writing.start + $0.1 * k) }
    }()

    /// 毛边纸：长边每隔几个单位抖一点
    static let sheet: Path = {
        let (x0, x1, y0, y1) = (paper.minX, paper.maxX, paper.minY, paper.maxY)
        func j(_ i: Int) -> Double { (M.rand(i, 95) - 0.5) * 1.2 }
        var pts: [CGPoint] = []
        for i in 0...11 { pts.append(CGPoint(x: x0 + (x1 - x0) * Double(i) / 11, y: y0 + j(i))) }
        for i in 1...26 { pts.append(CGPoint(x: x1 + j(100 + i), y: y0 + (y1 - y0) * Double(i) / 26)) }
        for i in 1...11 { pts.append(CGPoint(x: x1 - (x1 - x0) * Double(i) / 11, y: y1 + j(200 + i))) }
        for i in 1..<26 { pts.append(CGPoint(x: x0 + j(300 + i), y: y1 - (y1 - y0) * Double(i) / 26)) }
        var p = Path()
        p.addLines(pts)
        p.closeSubpath()
        return p
    }()

    static func draw(_ g: inout GraphicsContext, size: CGSize, t: Double) {
        M.unitSpace(&g, size)
        let tc = t.truncatingRemainder(dividingBy: cycle)
        // 纸绕上边中点轻轻摆，整张上下浮
        g.translateBy(x: 0, y: 2.5 * sin(t * 2 * .pi / 4.3) + paper.minY)
        g.rotate(by: .degrees(1.3 * sin(t * 2 * .pi / 6.5)))
        g.translateBy(x: 0, y: -paper.minY)
        drawPaper(&g)

        let done = schedule[schedule.count - 1].end
        let fade = 1 - smoothstep((tc - cycle + 1.4) / 1.0)
        let charge = tc < done ? 0 : (exp(-(tc - done) / 0.35) + 0.18 + 0.1 * sin((tc - done) * 2 * .pi / 2.4)) * fade

        var aura = g
        aura.blendMode = .plusLighter
        aura.addFilter(.blur(radius: 8))
        aura.stroke(sheet, with: .color(M.rgb(0xFFB14A, 0.6 * charge)), lineWidth: 4)

        var ink = g
        ink.blendMode = .multiply
        ink.opacity = fade
        ink.drawLayer { l in paint(&l, tc: tc) { _ in 1 } }
        // 刚写下的笔画发烫，过半秒冷下来；写完整张一起亮
        var glow = g
        glow.blendMode = .plusLighter
        glow.addFilter(.blur(radius: 3))
        glow.drawLayer { l in
            paint(&l, tc: tc, color: M.rgb(0xFFA43C)) { i in
                min(1, (tc < schedule[i].end ? 1 : exp(-(tc - schedule[i].end) / 0.5)) * fade + charge)
            }
        }
        // 笔尖
        for i in strokes.indices where tc >= schedule[i].start && tc < schedule[i].end {
            let tip = brush(strokes[i], upTo: (tc - schedule[i].start) / (schedule[i].end - schedule[i].start)).tip
            var hot = g
            hot.blendMode = .plusLighter
            hot.addFilter(.blur(radius: 2))
            hot.fill(M.circle(3.5, tip), with: .color(M.rgb(0xFFE2A0, 0.9)))
            g.fill(M.circle(1.1, tip), with: .color(.white.opacity(0.9)))
        }
    }

    /// 把已经写到的部分画出来；alpha(i) 是第 i 笔的不透明度
    static func paint(_ g: inout GraphicsContext, tc: Double, color: Color = M.rgb(cinnabar), alpha: (Int) -> Double) {
        for i in strokes.indices where tc > schedule[i].start {
            let f = (tc - schedule[i].start) / (schedule[i].end - schedule[i].start)
            let b = f >= 1 ? shapes[i] : brush(strokes[i], upTo: f)
            let c = color.opacity(alpha(i))
            g.fill(b.body, with: .color(c))
            g.fill(b.caps, with: .color(c))
        }
    }

    static func drawPaper(_ g: inout GraphicsContext) {
        var sh = g
        sh.addFilter(.shadow(color: .black.opacity(0.5), radius: 9, x: 3, y: 7))
        sh.fill(sheet, with: .color(M.rgb(0xE2B84E)))
        var p = g
        p.clip(to: sheet)
        p.fill(sheet, with: .linearGradient(Gradient(colors: [M.rgb(0xF6DC86), M.rgb(0xE8BE55), M.rgb(0xCF9A35)]),
                                            startPoint: CGPoint(x: paper.minX, y: paper.minY), endPoint: CGPoint(x: paper.maxX, y: paper.maxY)))
        // 纸面微微拱起：两边暗一点，靠左那条亮一点
        p.fill(sheet, with: .linearGradient(Gradient(stops: [.init(color: .black.opacity(0.1), location: 0), .init(color: .white.opacity(0.08), location: 0.3),
                                                             .init(color: .clear, location: 0.6), .init(color: .black.opacity(0.16), location: 1)]),
                                            startPoint: CGPoint(x: paper.minX, y: 0), endPoint: CGPoint(x: paper.maxX, y: 0)))
        // 纸纤维
        var dark = Path(), bright = Path()
        for i in 0..<180 {
            let c = CGPoint(x: paper.minX + paper.width * M.rand(i, 91), y: paper.minY + paper.height * M.rand(i, 92))
            let d = M.polar(1.5 + 3.5 * M.rand(i, 94), 360 * M.rand(i, 93))
            let seg = line(CGPoint(x: c.x - d.x, y: c.y - d.y), CGPoint(x: c.x + d.x, y: c.y + d.y))
            if i % 2 == 0 { dark.addPath(seg) } else { bright.addPath(seg) }
        }
        p.stroke(dark, with: .color(M.rgb(0x9A6A1C, 0.22)), lineWidth: 0.5)
        p.stroke(bright, with: .color(M.rgb(0xFFF3C4, 0.3)), lineWidth: 0.5)
        // 边缘做旧，往里晕一圈褐色
        var edge = p
        edge.addFilter(.blur(radius: 4))
        edge.stroke(sheet, with: .color(M.rgb(0x7A4A10, 0.45)), lineWidth: 7)
        // 印好的朱砂边框
        var frame = p
        frame.blendMode = .multiply
        frame.stroke(Path(paper.insetBy(dx: 6, dy: 6)), with: .color(M.rgb(cinnabar, 0.9)), lineWidth: 1.6)
        frame.stroke(Path(paper.insetBy(dx: 9, dy: 9)), with: .color(M.rgb(cinnabar, 0.8)), lineWidth: 0.6)
    }

    /// Catmull-Rom 插值，让笔画顺滑地经过每个点
    static func spline(_ p: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            for s in 0..<8 {
                let u = Double(s) / 8, u2 = u * u, u3 = u2 * u
                func f(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
                    0.5 * (2 * b + (c - a) * u + (2 * a - 5 * b + 4 * c - d) * u2 + (3 * b - a - 3 * c + d) * u3)
                }
                out.append(CGPoint(x: f(p0.x, p1.x, p2.x, p3.x), y: f(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        out.append(p[p.count - 1])
        return out
    }

    /// 折线按 2 个单位一段加密，好让笔宽沿长度变化；转角处的点保留，转角还是尖的
    static func densify(_ p: [CGPoint]) -> [CGPoint] {
        var out = [p[0]]
        for (a, b) in zip(p, p.dropFirst()) {
            let n = max(1, Int((hypot(b.x - a.x, b.y - a.y) / 2).rounded(.up)))
            for k in 1...n { out.append(CGPoint(x: a.x + (b.x - a.x) * Double(k) / Double(n), y: a.y + (b.y - a.y) * Double(k) / Double(n))) }
        }
        return out
    }

    /// 笔画：起笔略重、收笔稍提的一条带子，两头是圆的；只画前 f（0…1），顺便给出笔尖位置
    static func brush(_ st: Stroke, upTo f: Double) -> (body: Path, caps: Path, tip: CGPoint) {
        let s = st.smooth ? spline(st.pts) : densify(st.pts)
        let width = st.width
        var acc = [0.0]
        for i in 1..<s.count { acc.append(acc[i - 1] + hypot(s[i].x - s[i - 1].x, s[i].y - s[i - 1].y)) }
        let total = acc[acc.count - 1], end = total * f
        var left: [CGPoint] = [], right: [CGPoint] = [], caps: [(CGPoint, Double)] = []
        for i in 0..<s.count {
            var c = s[i], d = acc[i]
            if d > end, i > 0 {
                let k = (end - acc[i - 1]) / (d - acc[i - 1])
                c = CGPoint(x: s[i - 1].x + (c.x - s[i - 1].x) * k, y: s[i - 1].y + (c.y - s[i - 1].y) * k)
                d = end
            }
            let a = s[max(i - 1, 0)], b = s[min(i + 1, s.count - 1)]
            let len = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            let u = d / total
            let r = width / 2 * (1.1 - 0.15 * smoothstep(u / 0.2)) * (1 - 0.45 * smoothstep((u - 0.75) / 0.25))
            left.append(CGPoint(x: c.x - (b.y - a.y) / len * r, y: c.y + (b.x - a.x) / len * r))
            right.append(CGPoint(x: c.x + (b.y - a.y) / len * r, y: c.y - (b.x - a.x) / len * r))
            if i == 0 || d >= end { caps.append((c, r)) }
            if d >= end { break }
        }
        var body = Path(), ends = Path()
        body.addLines(left + right.reversed())
        body.closeSubpath()
        for (c, r) in caps { ends.addPath(M.circle(r, c)) }
        return (body, ends, caps[caps.count - 1].0)
    }
}
