// EyePreview.swift —— 离线渲染遮罩动画图案：一张多帧拼图 + 一段 GIF，不用开遮罩就能看效果
//
//   D=$TMPDIR/eye; rm -rf $D && mkdir -p $D
//   cp Tools/EyePreview.swift $D/main.swift
//   xcrun swiftc -o $D/eyepreview $D/main.swift Sources/CurtainArt.swift Sources/MechEye.swift Sources/ArtPresets.swift Sources/Preferences.swift Sources/CurtainBackground.swift
//   $D/eyepreview $D mechEye        # 图案名见 CurtainArt；输出 $D/eye-sheet.png、$D/eye.gif
//   $D/eyepreview $D mechEye stare  # 用一条假光标轨迹看「盯光标」，画面里的绿点是光标方向

import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let t0 = 1000.0     // 任取一个起点；整个图案只由 t（和盯光标的状态）决定
let art = CommandLine.arguments.count > 2 ? CurtainArt(rawValue: CommandLine.arguments[2]) : .mechEye
guard let draw = art?.draw else { fatalError("只能预览动画图案：" + CurtainArt.allCases.filter { $0.draw != nil }.map(\.rawValue).joined(separator: " / ")) }
let stare = CommandLine.arguments.contains("stare") ? MechEye.Stare() : nil

/// 假光标：相对图案中心，单位 pt，y 朝上（和屏幕坐标一样）；s 是 GIF 里的第几秒
func cursor(_ s: Double) -> CGPoint {
    func move(_ a: CGPoint, _ b: CGPoint, _ from: Double, _ d: Double) -> CGPoint {
        MechEye.lerp(a, b, smoothstep((s - from) / d))
    }
    let a = CGPoint(x: 420, y: -260), b = CGPoint(x: -380, y: 180), c = CGPoint(x: 20, y: -10), d = CGPoint(x: 700, y: 520)
    switch s {
    case ..<2: return a                                            // 光标不动：照常东张西望
    case ..<4.5:                                                   // 从右下绕过眼睛下方划到左上：一小跳一小跳地跟
        let p = move(a, b, 2, 2.5)
        return CGPoint(x: p.x, y: p.y - 300 * sin(.pi * smoothstep((s - 2) / 2.5)))
    case ..<5.3: return b
    case ..<6.8: return move(b, c, 5.3, 0.5)                       // 快速挪到眼睛跟前：直视
    default: return move(c, d, 6.8, 0.2)                           // 甩到右上很远（像在另一块屏上），停下 3 秒后回去东张西望
    }
}

func render(_ t: Double, _ size: Double, mark: CGPoint? = nil) -> CGImage {
    MainActor.assumeIsolated {
        let view = Canvas { g, s in
            var a = g                   // 图案会把坐标系挪到中心并缩放，画在副本上，下面的标记还用原坐标
            draw(&a, s, t, stare)
            // 光标方向：图案在遮罩上是 art.size pt 见方，按这个比例换到画布上，出了画布就贴边画一个空心圈
            guard let m = mark else { return }
            let k = s.width / art!.size, v = CGPoint(x: m.x * k, y: -m.y * k)
            let d = hypot(v.x, v.y), edge = s.width / 2 - 8
            let p = d > edge ? CGPoint(x: v.x / d * edge, y: v.y / d * edge) : v
            let dot = Path(ellipseIn: CGRect(x: s.width / 2 + p.x - 5, y: s.height / 2 + p.y - 5, width: 10, height: 10))
            // 贴边时压在金属外壳上，白色看不出来，用亮绿 + 黑边
            let green = Color(red: 0.2, green: 1, blue: 0.3)
            g.stroke(dot, with: .color(.black), lineWidth: 4)
            if d > edge { g.stroke(dot, with: .color(green), lineWidth: 2) } else { g.fill(dot, with: .color(green)) }
        }
            .frame(width: size, height: size)
            .background(Color(red: 0.10, green: 0.11, blue: 0.17))
        let r = ImageRenderer(content: view)
        r.scale = 1
        return r.cgImage!
    }
}

// 拼图 4×2：平时每 0.9 秒取一帧；盯光标时取轨迹上的几个关键时刻
let picks = stare == nil ? (0..<8).map { Double($0) * 0.9 } : [1, 3, 3.8, 5, 6.3, 7.5, 10.3, 11.5]
let cell = 300.0, cols = 4, rows = 2
let ctx = CGContext(data: nil, width: Int(cell) * cols, height: Int(cell) * rows, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// GIF：25 帧/秒，平时 10 秒，盯光标 12 秒。盯光标的状态要一帧一帧往前喂，所以拼图也在这个循环里取
let fps = 25.0, seconds = stare == nil ? 10.0 : 12.0
let frames = Int(fps * seconds)
let gif = CGImageDestinationCreateWithURL(out.appendingPathComponent("eye.gif") as CFURL, UTType.gif.identifier as CFString, frames, nil)!
CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
for f in 0..<frames {
    let s = Double(f) / fps, t = t0 + s
    let mark = stare.map { _ in cursor(s) }
    if let mark { stare!.feed(t, cursor: mark, eye: .zero) }
    CGImageDestinationAddImage(gif, render(t, 320, mark: mark), delay)
    if let k = picks.firstIndex(where: { Int(($0 * fps).rounded()) == f }) {
        let x = Double(k % cols) * cell, y = Double(rows - 1 - k / cols) * cell
        ctx.draw(render(t, cell, mark: mark), in: CGRect(x: x, y: y, width: cell, height: cell))
    }
}
CGImageDestinationFinalize(gif)
let sheet = CGImageDestinationCreateWithURL(out.appendingPathComponent("eye-sheet.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(sheet, ctx.makeImage()!, nil)
CGImageDestinationFinalize(sheet)
print("wrote \(out.path)/eye-sheet.png, eye.gif")
