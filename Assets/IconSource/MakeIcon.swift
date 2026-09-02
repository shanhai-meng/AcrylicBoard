import Cocoa

// 亚克力记录板 App 图标生成器
//
// 图标规范（本次按标准修正）：
//   - 输出 1024×1024 源 PNG；
//   - 图标主体（圆角底 + 板 + 装饰，即全部图形内容）居中，整体仅占画布 80%；
//   - 四周各预留 10%（合计 20%）纯透明安全留白；
//   - 禁止任何图形顶到画布四边。
//
// 用法: swift MakeIcon.swift <output.png>

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("Usage: swift MakeIcon.swift <output.png>")
    exit(1)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let size: CGFloat = 1024
let cornerRadius: CGFloat = 230        // 圆角底随 0.8 缩放后 ≈ 184

// ---- 内容安全区：主体只占画布 80%，四周 20%（每边 10%）透明留白 ----
let contentFraction: CGFloat = 0.8     // 主体占画布比例
let inset: CGFloat = size * (1 - contentFraction) / 2   // = 102.4

let icon = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    // 透明背景
    NSColor.clear.setFill()
    rect.fill()

    guard let ctx = NSGraphicsContext.current?.cgContext else { return true }

    // 整体居中缩小到 80%：此后所有绘制（背景、板、文字、点缀）都在中央方块内，
    // 四周自动留出 20% 透明安全边，绝不出界。
    ctx.saveGState()
    ctx.translateBy(x: inset, y: inset)
    ctx.scaleBy(x: contentFraction, y: contentFraction)

    // ---- 圆角背景 ----
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    bgPath.setClip()

    // 蓝紫对角渐变
    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: [
                                        NSColor(calibratedRed: 0.30, green: 0.55, blue: 0.95, alpha: 1).cgColor,
                                        NSColor(calibratedRed: 0.50, green: 0.35, blue: 0.80, alpha: 1).cgColor,
                                        NSColor(calibratedRed: 0.30, green: 0.25, blue: 0.55, alpha: 1).cgColor
                                    ] as CFArray,
                                    locations: [0.0, 0.5, 1.0]) else {
        ctx.restoreGState()
        return true
    }
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

    // ---- 毛玻璃/亚克力板（视觉主体，居中，占内容区中央 ~75%） ----
    let boardW: CGFloat = 470
    let boardH: CGFloat = 555
    let boardRect = NSRect(x: (size - boardW) / 2, y: (size - boardH) / 2,
                           width: boardW, height: boardH)

    ctx.saveGState()
    // 以板中心为锚点旋转约 5 度，让画面更灵动
    ctx.translateBy(x: boardRect.midX, y: boardRect.midY)
    ctx.rotate(by: -5 * .pi / 180)
    ctx.translateBy(x: -boardRect.midX, y: -boardRect.midY)

    // 阴影
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 26,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    let boardPath = NSBezierPath(roundedRect: boardRect, xRadius: 36, yRadius: 36)
    NSColor.white.withAlphaComponent(0.24).setFill()
    boardPath.fill()
    ctx.setShadow(offset: .zero, blur: 0, color: nil) // 关闭阴影

    // 边缘高光
    NSColor.white.withAlphaComponent(0.55).setStroke()
    boardPath.lineWidth = 3
    boardPath.stroke()

    // 顶部反光带（贴板顶部偏下一点，表现亚克力材质）
    let highlightRect = NSRect(x: boardRect.minX + 16, y: boardRect.maxY - 92,
                               width: boardRect.width - 32, height: 26)
    let highlight = NSBezierPath(roundedRect: highlightRect, xRadius: 12, yRadius: 12)
    NSColor.white.withAlphaComponent(0.15).setFill()
    highlight.fill()

    // ---- 手写内容（白色线条，控制在板内留白区域） ----
    NSColor.white.withAlphaComponent(0.95).setStroke()
    let lineWidth: CGFloat = 5

    func drawSquiggle(_ pts: [NSPoint]) {
        let path = NSBezierPath()
        path.move(to: pts[0])
        for i in 1..<pts.count {
            path.line(to: pts[i])
        }
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    let cx = boardRect.midX
    let cy = boardRect.midY
    // 三条“书写痕迹”
    drawSquiggle([
        NSPoint(x: cx - 140, y: cy + 120),
        NSPoint(x: cx - 60, y: cy + 100),
        NSPoint(x: cx + 40, y: cy + 140),
        NSPoint(x: cx + 140, y: cy + 110)
    ])
    drawSquiggle([
        NSPoint(x: cx - 150, y: cy + 20),
        NSPoint(x: cx - 40, y: cy),
        NSPoint(x: cx + 70, y: cy + 30),
        NSPoint(x: cx + 150, y: cy + 10)
    ])
    drawSquiggle([
        NSPoint(x: cx - 130, y: cy - 85),
        NSPoint(x: cx - 30, y: cy - 105),
        NSPoint(x: cx + 70, y: cy - 75)
    ])
    // 闪烁/重点符号
    drawSquiggle([
        NSPoint(x: cx - 110, y: cy + 190),
        NSPoint(x: cx - 90, y: cy + 222),
        NSPoint(x: cx - 70, y: cy + 190),
        NSPoint(x: cx - 90, y: cy + 158),
        NSPoint(x: cx - 110, y: cy + 190)
    ])

    // ---- 右下角小铅笔 ----
    let pencilRect = NSRect(x: boardRect.maxX - 96, y: boardRect.minY + 46,
                            width: 96, height: 20)
    let pencilPath = NSBezierPath(roundedRect: pencilRect, xRadius: 4, yRadius: 4)
    NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.22, alpha: 1).setFill()
    pencilPath.fill()
    // 笔尖
    let tip = NSBezierPath()
    tip.move(to: NSPoint(x: pencilRect.minX, y: pencilRect.minY))
    tip.line(to: NSPoint(x: pencilRect.minX, y: pencilRect.maxY))
    tip.line(to: NSPoint(x: pencilRect.minX - 16, y: pencilRect.midY))
    tip.close()
    NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.90, alpha: 1).setFill()
    tip.fill()

    ctx.restoreGState()

    // ---- 散落小方块（点缀在板四周空隙；随整体缩至 80%，且都远在安全区内不触边） ----
    func confetti(_ r: NSRect, color: NSColor) {
        color.setFill()
        let p = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        p.fill()
    }
    // 左右两侧各一、上方两颗，左右成镜像对称（AppKit 坐标：y 向上）
    // 左侧靠板、右侧靠板（镜像），均收在中央 80% 内容区内
    let leftRed = NSRect(x: 153, y: 482, width: 34, height: 34)          // 红
    let leftBlue = NSRect(x: 199, y: 886, width: 40, height: 40)         // 青
    confetti(leftRed, color: NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.55, alpha: 0.9))
    confetti(leftBlue, color: NSColor(calibratedRed: 0.45, green: 0.85, blue: 1.00, alpha: 0.9))
    // 右侧镜像：x = 1024 - (左侧 minX + width)
    confetti(NSRect(x: 1024 - leftRed.maxX, y: leftRed.minY, width: leftRed.width, height: leftRed.height),
             color: NSColor(calibratedRed: 1.00, green: 0.85, blue: 0.40, alpha: 0.9))
    confetti(NSRect(x: 1024 - leftBlue.maxX, y: leftBlue.minY, width: leftBlue.width, height: leftBlue.height),
             color: NSColor(calibratedRed: 0.55, green: 1.00, blue: 0.55, alpha: 0.85))

    ctx.restoreGState()
    return true
}

guard let tiff = icon.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let data = rep.representation(using: .png, properties: [:]) else {
    print("生成 PNG 失败")
    exit(1)
}

try data.write(to: outputURL)
print("已生成程序化图标(主体80%、四周20%留白): \(outputURL.path)")
