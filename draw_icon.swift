// 生成「窗口总览」的应用图标
// 设计：深蓝渐变底 + 三张错落叠放的窗口卡片，最前面那张带蓝色高亮行 → 表达"从一堆窗口里点中一个"
// 用法：xcrun swift draw_icon.swift [输出路径.png]

import Foundation
import CoreGraphics
import ImageIO

let S: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a)
}

guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("无法创建画布")
}
ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

// ---------- 背景：Big Sur 规格的圆角矩形（824×824 居中，圆角 185） ----------
let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let grad = CGGradient(colorsSpace: cs,
                      colors: [c(82, 150, 255), c(20, 56, 152)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 190, y: 900), end: CGPoint(x: 870, y: 150), options: [])
ctx.restoreGState()

// ---------- 窗口卡片 ----------
func drawCard(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, alpha: CGFloat, detail: Bool) {
    let rect = CGRect(x: x, y: y, width: w, height: h)
    let path = CGPath(roundedRect: rect, cornerWidth: 34, cornerHeight: 34, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: c(0, 16, 56, 0.30))
    ctx.setFillColor(c(255, 255, 255, alpha))
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()

    guard detail else { return }

    // 高亮标题条
    let bar = CGRect(x: x + 44, y: y + h - 88, width: w - 190, height: 28)
    ctx.setFillColor(c(59, 130, 246, 1))
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.fillPath()

    // 两行内容
    ctx.setFillColor(c(148, 163, 184, 0.85))
    for (idx, lw) in [w - 96, w - 170].enumerated() {
        let ly = y + h - 162 - CGFloat(idx) * 62
        let r = CGRect(x: x + 44, y: ly, width: lw, height: 18)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.fillPath()
    }
}

drawCard(x: 370, y: 305, w: 420, h: 285, alpha: 0.40, detail: false)
drawCard(x: 300, y: 365, w: 420, h: 285, alpha: 0.66, detail: false)
drawCard(x: 230, y: 425, w: 420, h: 285, alpha: 1.00, detail: true)

// ---------- 输出 ----------
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let out = URL(fileURLWithPath: outPath)

guard let img = ctx.makeImage() else { fatalError("makeImage 失败") }
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("无法创建输出文件")
}
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("写入失败") }
print("已生成：\(out.path)")
