// MechEye.swift —— 遮罩上的机械眼球（参考 Lakr233/Sentry 的 EyeView，MIT）
//
// 结构从外到内：金属外壳（刻度 + 螺丝）→ 棘轮齿圈 → 眼窝 → 会转动的眼球
// （橙红虹膜 + 8 片光圈叶片 + 红色指示灯）→ 玻璃罩高光。
// 整只眼是时间 t 的纯函数，由 CurtainArtView 按帧调用 draw。
// 动作都是「机械」的：齿圈一格一格跳、眼球快速转到新位置再带一点过冲停住、
// 光圈跟着重新对焦，偶尔整个合上再打开（眨眼）。

import SwiftUI

enum MechEye {
    // MARK: - 动作

    /// 阻尼弹簧，0 → 1，带一点过冲。ω 越大越快
    static func spring(_ tau: Double, omega: Double = 26, zeta: Double = 0.42) -> Double {
        guard tau > 0 else { return 0 }
        let wd = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-zeta * omega * tau) * (cos(wd * tau) + zeta * omega / wd * sin(wd * tau))
    }

    /// 0..1 的伪随机数，只由 (i, salt) 决定
    static func rand(_ i: Int, _ salt: UInt64) -> Double {
        var z = UInt64(bitPattern: Int64(i)) &+ salt &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// 棘轮：每 period 秒跳一格 step（度），跳的时候带过冲
    static func ratchet(_ t: Double, period: Double, step: Double) -> Double {
        let n = (t / period).rounded(.down)
        let teeth = (360 / step).rounded()
        return (n.truncatingRemainder(dividingBy: teeth) + spring(t - n * period, omega: 55, zeta: 0.35)) * step
    }

    /// 每 slot 秒可能换一次注视点，换的时刻在 slot 开头 0.6 秒内随机
    static let slot = 1.7
    static let maxGaze = 15.0

    static func moveTime(_ i: Int) -> Double { Double(i) * slot + 0.6 * rand(i, 1) }

    static func gazeTarget(_ i: Int) -> CGPoint {
        if rand(i, 2) < 0.28 { return .zero }                 // 时不时回正
        let a = rand(i, 3) * 2 * .pi
        let r = maxGaze * (0.45 + 0.55 * rand(i, 4))
        return CGPoint(x: cos(a) * r, y: sin(a) * r * 0.7)    // 左右看得比上下多
    }

    struct Pose {
        var gaze: CGPoint      // 眼球偏移
        var pupil: Double      // 光圈开口内切圆半径
        var gear: Double       // 齿圈角度（度）
        var iris: Double       // 虹膜纹理角度（度）
        var glow: Double       // 指示灯亮度 0..1
    }

    static func pose(_ t: Double) -> Pose {
        var i = Int((t / slot).rounded(.down))
        if t < moveTime(i) { i -= 1 }
        let tau = t - moveTime(i)
        let k = spring(tau)
        let from = gazeTarget(i - 1), to = gazeTarget(i)
        // 停住时伺服电机的细微抖动
        let hum = CGPoint(x: sin(t * 37) * 0.18 + sin(t * 59) * 0.1, y: cos(t * 43) * 0.15)
        let gaze = CGPoint(x: from.x + (to.x - from.x) * k + hum.x, y: from.y + (to.y - from.y) * k + hum.y)

        // 转完眼再对焦：光圈晚 0.12 秒跟上
        let focusFrom = 10 + 12 * rand(i - 1, 5), focusTo = 10 + 12 * rand(i, 5)
        var pupil = focusFrom + (focusTo - focusFrom) * spring(tau - 0.12, omega: 18, zeta: 0.5)
        // 眨眼：约 1/5 的 slot 在转完后合上光圈再打开
        if rand(i, 6) < 0.2 {
            let b = tau - 0.85
            if b > 0, b < 0.1 { pupil *= 1 - b / 0.1 }
            else if b >= 0.1, b < 0.18 { pupil = 0 }
            else if b >= 0.18 { pupil *= min(1, spring(b - 0.18, omega: 20, zeta: 0.55)) }
        }

        return Pose(gaze: gaze, pupil: max(0, pupil),
                    gear: ratchet(t, period: 1.6, step: 7.5),
                    iris: -ratchet(t + 0.4, period: 0.8, step: 2.5),
                    glow: 0.72 + 0.28 * sin(t * 2 * .pi / 2.6))
    }

    // MARK: - 绘制

    /// 把画布换成中心为原点、半径 120 的坐标系；所有图案都在这个坐标系里画
    static func unitSpace(_ g: inout GraphicsContext, _ size: CGSize) {
        let s = min(size.width, size.height) / 240
        g.translateBy(x: size.width / 2, y: size.height / 2)
        g.scaleBy(x: s, y: s)
    }

    static func draw(_ g: inout GraphicsContext, size: CGSize, t: Double) {
        unitSpace(&g, size)
        let p = pose(t)

        drawHousing(&g)
        drawGear(&g, angle: p.gear)
        drawCavity(&g)
        drawEyeball(&g, p)
        drawGlass(&g)
    }

    static func circle(_ r: Double, _ c: CGPoint = .zero) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    static func ring(_ outer: Double, _ inner: Double) -> Path {
        var p = circle(outer)
        p.addPath(circle(inner))
        return p
    }

    static func polar(_ r: Double, _ deg: Double) -> CGPoint {
        CGPoint(x: r * cos(deg * .pi / 180), y: r * sin(deg * .pi / 180))
    }

    static func rgb(_ hex: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
              blue: Double(hex & 0xff) / 255, opacity: a)
    }

    /// 拉丝金属环的反光，锥形渐变用
    static let brushed = Gradient(colors: [0x8A8F98, 0xDCE0E6, 0x6B7079, 0xC4C9D1, 0x777C85, 0xE8EBEF, 0x70757E, 0xB8BDC5, 0x8A8F98].map { rgb($0) })

    /// 一字螺丝，slot 是槽口方向（弧度）
    static func screw(_ g: inout GraphicsContext, _ c: CGPoint, r: Double = 4.2, slot: Double) {
        let k = r / 4.2
        g.fill(circle(r, c), with: .radialGradient(Gradient(colors: [rgb(0xF2F4F7), rgb(0x8C919A), rgb(0x4A4E55)]),
                                                   center: CGPoint(x: c.x - 1.2 * k, y: c.y - 1.2 * k), startRadius: 0, endRadius: 4.6 * k))
        var p = Path()
        p.move(to: CGPoint(x: c.x + 2.8 * k * cos(slot), y: c.y + 2.8 * k * sin(slot)))
        p.addLine(to: CGPoint(x: c.x - 2.8 * k * cos(slot), y: c.y - 2.8 * k * sin(slot)))
        g.stroke(p, with: .color(.black.opacity(0.6)), lineWidth: k)
    }

    /// 外壳：拉丝金属环 + 刻度 + 6 颗螺丝 + 一圈橙色余光
    static func drawHousing(_ g: inout GraphicsContext) {
        g.stroke(circle(116), with: .color(rgb(0xFF8A3D, 0.22)), lineWidth: 5)

        var sh = g
        sh.addFilter(.shadow(color: .black.opacity(0.55), radius: 10, y: 6))
        sh.fill(circle(112), with: .color(rgb(0x6E737C)))

        g.fill(ring(112, 92), with: .conicGradient(brushed, center: .zero, angle: .degrees(-20)), style: FillStyle(eoFill: true))
        g.stroke(circle(111.3), with: .linearGradient(Gradient(colors: [.white.opacity(0.55), .black.opacity(0.35)]),
                                                     startPoint: CGPoint(x: -80, y: -80), endPoint: CGPoint(x: 80, y: 80)), lineWidth: 1.4)
        g.stroke(circle(92.5), with: .linearGradient(Gradient(colors: [.black.opacity(0.6), .white.opacity(0.4)]),
                                                    startPoint: CGPoint(x: -60, y: -60), endPoint: CGPoint(x: 60, y: 60)), lineWidth: 1.6)

        // 刻度：每 6° 一格，每 30° 长一格；螺丝所在位置留空
        for k in 0..<60 {
            let deg = Double(k) * 6
            if k % 10 == 5 { continue }
            let long = k % 5 == 0
            var tick = Path()
            tick.move(to: polar(95, deg))
            tick.addLine(to: polar(long ? 101 : 98.5, deg))
            g.stroke(tick, with: .color(.black.opacity(long ? 0.55 : 0.35)), lineWidth: long ? 1.4 : 0.9)
        }

        for k in 0..<6 {
            let deg = 30 + Double(k) * 60
            screw(&g, polar(105, deg), slot: deg * 1.7)
        }
    }

    /// 棘轮齿圈：48 齿，一格一格转
    static func drawGear(_ g: inout GraphicsContext, angle: Double) {
        g.fill(ring(92, 80), with: .color(rgb(0x2A2E35)), style: FillStyle(eoFill: true))
        var teeth = Path()
        for k in 0..<48 {
            let a = angle + Double(k) * 7.5
            teeth.move(to: polar(84, a - 2.2))
            teeth.addLine(to: polar(90.5, a - 1.3))
            teeth.addLine(to: polar(90.5, a + 1.3))
            teeth.addLine(to: polar(84, a + 2.2))
            teeth.closeSubpath()
        }
        g.fill(teeth, with: .linearGradient(Gradient(colors: [rgb(0x7A808B), rgb(0x3C4049)]),
                                            startPoint: CGPoint(x: -90, y: -90), endPoint: CGPoint(x: 90, y: 90)))
        g.stroke(circle(84), with: .color(.black.opacity(0.5)), lineWidth: 0.8)
    }

    static func drawCavity(_ g: inout GraphicsContext) {
        g.fill(circle(80), with: .radialGradient(Gradient(colors: [rgb(0x050506), rgb(0x16181C)]),
                                                 center: .zero, startRadius: 40, endRadius: 80))
        g.stroke(circle(79), with: .color(.black.opacity(0.85)), lineWidth: 3)
    }

    /// 眼球：深色金属球 + 随注视点平移、沿方向压扁的虹膜和光圈（假装是球面在转）
    static func drawEyeball(_ g: inout GraphicsContext, _ p: Pose) {
        var ball = g
        ball.clip(to: circle(77))
        let hl = CGPoint(x: -22 + p.gaze.x * 0.5, y: -26 + p.gaze.y * 0.5)
        ball.fill(circle(76), with: .radialGradient(Gradient(colors: [rgb(0x4A505A), rgb(0x1E2126), rgb(0x0A0B0D)]),
                                                    center: hl, startRadius: 0, endRadius: 95))

        let d = hypot(p.gaze.x, p.gaze.y)
        let dir = Angle.radians(atan2(p.gaze.y, p.gaze.x))
        var e = ball
        e.translateBy(x: p.gaze.x, y: p.gaze.y)
        e.rotate(by: dir)
        e.scaleBy(x: 1 - 0.22 * min(d / maxGaze, 1.2), y: 1)
        e.rotate(by: -dir)

        drawIris(&e, angle: p.iris)
        drawAperture(&e, pupil: p.pupil, glow: p.glow)
    }

    /// 橙红虹膜 + 放射纹理（沿用 Sentry 的配色），纹理圈反向一格一格转
    static func drawIris(_ g: inout GraphicsContext, angle: Double) {
        g.stroke(circle(60.5), with: .color(rgb(0xFF9A4A, 0.35)), lineWidth: 2)
        g.fill(circle(59), with: .radialGradient(Gradient(colors: [rgb(0xD81F12), rgb(0xFF7A1A), rgb(0xFF9B3D), rgb(0xC0140C)]),
                                                 center: .zero, startRadius: 34, endRadius: 59))
        var coarse = Path(), fine = Path()
        for k in 0..<36 {
            let a = angle + Double(k) * 10
            coarse.move(to: polar(40, a)); coarse.addLine(to: polar(58, a))
        }
        for k in 0..<24 {
            let a = -angle * 0.5 + Double(k) * 15 + 5
            fine.move(to: polar(40, a)); fine.addLine(to: polar(50, a))
        }
        g.stroke(coarse, with: .color(.black.opacity(0.32)), lineWidth: 1.1)
        g.stroke(fine, with: .color(rgb(0x7A0A05, 0.45)), lineWidth: 0.6)
        g.stroke(circle(59), with: .color(.black.opacity(0.6)), lineWidth: 1.6)
    }

    /// 8 片光圈叶片。开口是内切圆半径为 pupil 的正八边形，开得越大叶片转得越多
    static func drawAperture(_ g: inout GraphicsContext, pupil: Double, glow: Double) {
        let n = 8, outer = 39.0
        let twist = pupil * 0.035
        let circR = pupil / cos(.pi / Double(n))
        let v = (0..<n).map { k -> CGPoint in
            let a = twist + Double(k) * 2 * .pi / Double(n)
            return CGPoint(x: circR * cos(a), y: circR * sin(a))
        }
        func dirOf(_ k: Int) -> CGPoint {          // 第 k 条边的方向（正八边形按角度算，开口为 0 时也成立）
            let a = twist + (Double(k) + 0.5) * 2 * .pi / Double(n) + .pi / 2
            return CGPoint(x: cos(a), y: sin(a))
        }

        var blades = g
        blades.clip(to: circle(outer))

        // 开口里面：镜头 + 红色指示灯
        var hole = Path()
        hole.addLines(v); hole.closeSubpath()
        let lens = blades
        lens.fill(circle(outer), with: .color(.black))
        lens.fill(circle(pupil * 0.95 + 3), with: .radialGradient(
            Gradient(colors: [rgb(0xFF2A1A, 0.95 * glow), rgb(0xB00A05, 0.55 * glow), .clear]),
            center: .zero, startRadius: 0, endRadius: pupil * 0.95 + 3))
        lens.stroke(circle(pupil * 0.62), with: .color(.white.opacity(0.07)), lineWidth: 0.8)
        lens.fill(circle(2.4), with: .color(rgb(0xFFD0C0, 0.6 + 0.4 * glow)))

        // 叶片：顶点 v[k+1] 处，夹在第 k 条边的延长线和第 k+1 条边之间的楔形
        let far = outer * 3
        for k in 0..<n {
            let apex = v[(k + 1) % n]
            let d0 = dirOf(k), d1 = dirOf(k + 1)
            var blade = Path()
            blade.move(to: apex)
            blade.addLine(to: CGPoint(x: apex.x + d0.x * far, y: apex.y + d0.y * far))
            blade.addLine(to: CGPoint(x: apex.x + d1.x * far, y: apex.y + d1.y * far))
            blade.closeSubpath()
            let mid = CGPoint(x: apex.x + (d0.x + d1.x) * 20, y: apex.y + (d0.y + d1.y) * 20)
            let shade = k % 2 == 0 ? 0x5A616C : 0x4C525C
            blades.fill(blade, with: .linearGradient(Gradient(colors: [rgb(UInt32(shade)), rgb(0x1C1F24)]),
                                                     startPoint: apex, endPoint: mid))
            // 叶片边缘被虹膜照到的一线暖光
            var edge = Path()
            edge.move(to: apex)
            edge.addLine(to: CGPoint(x: apex.x + d0.x * far, y: apex.y + d0.y * far))
            blades.stroke(edge, with: .color(rgb(0xFFA060, 0.75)), lineWidth: 0.8)
        }
        blades.stroke(hole, with: .color(.black.opacity(0.8)), lineWidth: 0.8)
        // 指示灯的余光漫到叶片上
        var bloom = blades
        bloom.blendMode = .plusLighter
        bloom.fill(circle(pupil + 12), with: .radialGradient(Gradient(colors: [rgb(0xFF3020, 0.4 * glow), .clear]),
                                                           center: .zero, startRadius: pupil * 0.5, endRadius: pupil + 12))
        g.stroke(circle(outer), with: .color(.black.opacity(0.75)), lineWidth: 2)
        g.stroke(circle(outer + 1.2), with: .color(rgb(0xFFB070, 0.25)), lineWidth: 0.8)
    }

    /// 玻璃罩：左上一道弧形反光 + 一个小高光点，不跟着眼球动
    static func drawGlass(_ g: inout GraphicsContext) {
        var glass = g
        glass.clip(to: circle(79))
        var arc = Path()
        arc.addArc(center: .zero, radius: 66, startAngle: .degrees(200), endAngle: .degrees(255), clockwise: false)
        glass.stroke(arc, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
        var spot = glass
        spot.addFilter(.blur(radius: 3))
        spot.fill(circle(5, CGPoint(x: -36, y: -44)), with: .color(.white.opacity(0.35)))
        glass.fill(circle(79), with: .radialGradient(Gradient(colors: [.clear, .black.opacity(0.35)]),
                                                     center: .zero, startRadius: 55, endRadius: 80))
    }
}
