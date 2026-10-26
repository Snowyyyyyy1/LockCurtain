// EyePreview.swift —— 离线渲染遮罩动画图案：一张多帧拼图 + 一段 GIF，不用开遮罩就能看效果
//
//   D=$TMPDIR/eye; rm -rf $D && mkdir -p $D
//   cp Tools/EyePreview.swift $D/main.swift
//   xcrun swiftc -o $D/eyepreview $D/main.swift Sources/CurtainArt.swift Sources/MechEye.swift
//   $D/eyepreview $D mechEye        # 图案名见 CurtainArt；输出 $D/eye-sheet.png、$D/eye.gif

import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let t0 = 1000.0     // 任取一个起点；整个图案只由 t 决定
let art = CommandLine.arguments.count > 2 ? CurtainArt(rawValue: CommandLine.arguments[2]) : .mechEye
guard let draw = art?.draw else { fatalError("只能预览动画图案：" + CurtainArt.allCases.filter { $0.draw != nil }.map(\.rawValue).joined(separator: " / ")) }

func render(_ t: Double, _ size: Double) -> CGImage {
    MainActor.assumeIsolated {
        let view = Canvas { g, s in draw(&g, s, t) }
            .frame(width: size, height: size)
            .background(Color(red: 0.10, green: 0.11, blue: 0.17))
        let r = ImageRenderer(content: view)
        r.scale = 1
        return r.cgImage!
    }
}

// 拼图：4×2，每帧间隔 0.9 秒
let cell = 300.0, cols = 4, rows = 2
let ctx = CGContext(data: nil, width: Int(cell) * cols, height: Int(cell) * rows, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
for k in 0..<(cols * rows) {
    let x = Double(k % cols) * cell, y = Double(rows - 1 - k / cols) * cell
    ctx.draw(render(t0 + Double(k) * 0.9, cell), in: CGRect(x: x, y: y, width: cell, height: cell))
}
let sheet = CGImageDestinationCreateWithURL(out.appendingPathComponent("eye-sheet.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(sheet, ctx.makeImage()!, nil)
CGImageDestinationFinalize(sheet)

// GIF：10 秒，25 帧/秒
let fps = 25.0, seconds = 10.0
let frames = Int(fps * seconds)
let gif = CGImageDestinationCreateWithURL(out.appendingPathComponent("eye.gif") as CFURL, UTType.gif.identifier as CFString, frames, nil)!
CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
for f in 0..<frames {
    CGImageDestinationAddImage(gif, render(t0 + Double(f) / fps, 320), delay)
}
CGImageDestinationFinalize(gif)
print("wrote \(out.path)/eye-sheet.png, eye.gif")
