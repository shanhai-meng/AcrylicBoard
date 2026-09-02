import Cocoa

let arguments = CommandLine.arguments
 guard arguments.count >= 2 else {
     print("Usage: swift MakeIcon.swift <output.png>")
     exit(1)
 }

 let outputURL = URL(fileURLWithPath: arguments[1])
 let size: CGFloat = 1024
 let cornerRadius: CGFloat = 230

 let icon = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
     // 透明背景
     NSColor.clear.setFill()
     rect.fill()

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
         return true
     }
     let ctx = NSGraphicsContext.current!.cgContext
     ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

     // ---- 毛玻璃/亚克力板 ----
     let boardW: CGFloat = 560
     let boardH: CGFloat = 660
     let boardRect = NSRect(x: (size - boardW) / 2, y: (size - boardH) / 2, width: boardW, height: boardH)

     ctx.saveGState()
     // 以板中心为锚点旋转约 6 度
     ctx.translateBy(x: boardRect.midX, y: boardRect.midY)
     ctx.rotate(by: -6 * .pi / 180)
     ctx.translateBy(x: -boardRect.midX, y: -boardRect.midY)

     // 阴影
     ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
     let boardPath = NSBezierPath(roundedRect: boardRect.insetBy(dx: 0, dy: 0), xRadius: 42, yRadius: 42)
     NSColor.white.withAlphaComponent(0.22).setFill()
     boardPath.fill()
     ctx.setShadow(offset: .zero, blur: 0, color: nil) // 关闭阴影

     // 边缘高光
     NSColor.white.withAlphaComponent(0.55).setStroke()
     boardPath.lineWidth = 3
     boardPath.stroke()

     // 顶部反光
     let highlight = NSBezierPath(roundedRect: boardRect.insetBy(dx: 8, dy: boardH / 2 - 12), xRadius: 32, yRadius: 24)
     NSColor.white.withAlphaComponent(0.14).setFill()
     highlight.fill()

     // ---- 手写内容（白色线条） ----
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
     drawSquiggle([
         NSPoint(x: cx - 160, y: cy + 170),
         NSPoint(x: cx - 80, y: cy + 150),
         NSPoint(x: cx + 20, y: cy + 190),
         NSPoint(x: cx + 120, y: cy + 160)
     ])
     drawSquiggle([
         NSPoint(x: cx - 170, y: cy + 60),
         NSPoint(x: cx - 60, y: cy + 40),
         NSPoint(x: cx + 40, y: cy + 70),
         NSPoint(x: cx + 150, y: cy + 50)
     ])
     drawSquiggle([
         NSPoint(x: cx - 150, y: cy - 50),
         NSPoint(x: cx - 40, y: cy - 70),
         NSPoint(x: cx + 80, y: cy - 40)
     ])
     // 闪烁/重点符号
     drawSquiggle([
         NSPoint(x: cx - 130, y: cy + 230),
         NSPoint(x: cx - 110, y: cy + 260),
         NSPoint(x: cx - 90, y: cy + 230),
         NSPoint(x: cx - 110, y: cy + 200),
         NSPoint(x: cx - 130, y: cy + 230)
     ])

     // ---- 右下角小铅笔 ----
     let pencilRect = NSRect(x: boardRect.maxX - 90, y: boardRect.minY + 50, width: 110, height: 22)
     let pencilPath = NSBezierPath(roundedRect: pencilRect, xRadius: 4, yRadius: 4)
     NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.22, alpha: 1).setFill()
     pencilPath.fill()
     // 笔尖
     let tip = NSBezierPath()
     tip.move(to: NSPoint(x: pencilRect.minX, y: pencilRect.minY))
     tip.line(to: NSPoint(x: pencilRect.minX, y: pencilRect.maxY))
     tip.line(to: NSPoint(x: pencilRect.minX - 18, y: pencilRect.midY))
     tip.close()
     NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.90, alpha: 1).setFill()
     tip.fill()

     ctx.restoreGState()

     // ---- 散落小方块（增加辨识度） ----
     func confetti(_ rect: NSRect, color: NSColor) {
         color.setFill()
         let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
         path.fill()
     }
     confetti(NSRect(x: 110, y: 210, width: 36, height: 36), color: NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.55, alpha: 0.85))
     confetti(NSRect(x: 170, y: 760, width: 42, height: 42), color: NSColor(calibratedRed: 0.45, green: 0.85, blue: 1.00, alpha: 0.85))
     confetti(NSRect(x: 800, y: 190, width: 32, height: 32), color: NSColor(calibratedRed: 1.00, green: 0.85, blue: 0.40, alpha: 0.85))
     confetti(NSRect(x: 860, y: 800, width: 38, height: 38), color: NSColor(calibratedRed: 0.55, green: 1.00, blue: 0.55, alpha: 0.80))

     return true
 }

 guard let tiff = icon.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let data = rep.representation(using: .png, properties: [:]) else {
     print("生成 PNG 失败")
     exit(1)
 }

try data.write(to: outputURL)
 print("已生成程序化图标: \(outputURL.path)")
