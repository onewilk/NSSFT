// 生成 NSSFT 应用图标（macOS 自带 swift 即可运行，不依赖第三方库）：
//   swift tools/make_icon.swift <输出目录>
// 输出：
//   foreground.png / background.png  1024×1024，鸿蒙分层图标的前景层和背景层
//   icon_1024.png / icon_512.png / start_256.png  合成后的平面图标（应用市场上传、启动页等）
// 造型：青绿渐变底 + 白色取景框四角 + 居中的播放三角，表示“从画面里取帧、播放出来”；不用任何手柄或游戏机外形。
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let white = color(0xFFFFFF)

// opaque：不透明的图（背景层、平面图标）不带 alpha 通道，PNG 小得多
func makeContext(_ px: Int, opaque: Bool = false) -> CGContext {
    let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: alpha.rawValue)!
    // 以左上角为原点、1024 为单位坐标绘制
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: CGFloat(px) / CGFloat(size), y: -CGFloat(px) / CGFloat(size))
    ctx.setShouldAntialias(true)
    return ctx
}

func save(_ ctx: CGContext, _ name: String) {
    let image = ctx.makeImage()!
    let url = URL(fileURLWithPath: "\(outDir)/\(name)") as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(outDir)/\(name)")
}

// 背景渐变逐像素算出来再画上去：系统渐变带抖动噪点，PNG 压不下去（近 1 MB）；逐像素的平滑渐变只有几十 KB
let backgroundImage: CGImage = {
    let from: [Double] = [0x1D, 0xB5, 0xA3], to: [Double] = [0x00, 0x69, 0x5C]
    var pixels = [UInt8](repeating: 255, count: size * size * 4)
    for y in 0..<size {
        for x in 0..<size {
            // 左上亮、右下暗的斜向渐变
            let t = Double(x + y) / Double(2 * (size - 1))
            let i = (y * size + x) * 4
            for c in 0..<3 { pixels[i + c] = UInt8((from[c] + (to[c] - from[c]) * t).rounded()) }
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}()

func drawBackground(_ ctx: CGContext) {
    // 上下翻转回图片自己的坐标系再画（makeContext 把原点放在了左上角）
    ctx.saveGState()
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.draw(backgroundImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    ctx.restoreGState()
}

func drawForeground(_ ctx: CGContext) {
    // 取景框：16:10 的框只画四个角，留在分层图标的安全区内
    let left: CGFloat = 252, right: CGFloat = 772, top: CGFloat = 322, bottom: CGFloat = 702
    let arm: CGFloat = 112
    ctx.setStrokeColor(white)
    ctx.setLineWidth(52)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: left, y: top), 1, 1), (CGPoint(x: right, y: top), -1, 1),
        (CGPoint(x: left, y: bottom), 1, -1), (CGPoint(x: right, y: bottom), -1, -1)
    ]
    for (p, dx, dy) in corners {
        ctx.move(to: CGPoint(x: p.x, y: p.y + dy * arm))
        ctx.addLine(to: p)
        ctx.addLine(to: CGPoint(x: p.x + dx * arm, y: p.y))
    }
    ctx.strokePath()

    // 播放三角：视觉重心略向右，带一点圆角
    let cx: CGFloat = 528, cy: CGFloat = 512, h: CGFloat = 196, w: CGFloat = 172
    let path = CGMutablePath()
    path.move(to: CGPoint(x: cx - w / 2, y: cy - h / 2))
    path.addLine(to: CGPoint(x: cx + w / 2, y: cy))
    path.addLine(to: CGPoint(x: cx - w / 2, y: cy + h / 2))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(white)
    ctx.setStrokeColor(white)
    ctx.setLineWidth(28)
    ctx.drawPath(using: .fillStroke)
}

// 分层图标的两层
let fg = makeContext(size)
drawForeground(fg)
save(fg, "foreground.png")
let bg = makeContext(size, opaque: true)
drawBackground(bg)
save(bg, "background.png")

// 平面图标（应用市场上传用方形，系统会自己裁圆角）
for (px, name) in [(1024, "icon_1024.png"), (512, "icon_512.png")] {
    let ctx = makeContext(px, opaque: true)
    drawBackground(ctx)
    drawForeground(ctx)
    save(ctx, name)
}
// 启动页图标：自己裁成圆角，放在浅色/深色启动背景上都不会显出方块
let start = makeContext(256)
start.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size), cornerWidth: 230, cornerHeight: 230,
                     transform: nil))
start.clip()
drawBackground(start)
drawForeground(start)
save(start, "start_256.png")
