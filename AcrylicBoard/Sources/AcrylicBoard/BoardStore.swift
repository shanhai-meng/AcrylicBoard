import AppKit
import os.log

// MARK: - 数据模型

/// 一条“板上内容”：文字 或 图片。
/// `frame` 存于 AppKit 全局坐标（左下原点，与 NSScreen.frame 同坐标系），即文字/图片最终贴在壁纸上的矩形。
struct BoardItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, image }

    var id: UUID
    var kind: Kind
    var frame: CGRect
    var zIndex: Int
    // text:
    var fontName: String?          // 基础字体的 PostScript 名；"System"/nil 表示系统字体
    var fontSize: CGFloat
    var colorHex: String           // "#RRGGBB"
    var isBold: Bool
    var text: String
    // image:
    var imageFile: String?         // images/ 下的文件名
    var cornerRadius: CGFloat

    init(id: UUID = UUID(),
         kind: Kind,
         frame: CGRect,
         zIndex: Int = 0,
         fontName: String? = AppDefaults.defaultFontName,
         fontSize: CGFloat = AppDefaults.defaultFontSize,
         colorHex: String = AppDefaults.defaultTextColor,
         isBold: Bool = AppDefaults.defaultBold,
         text: String = "",
         imageFile: String? = nil,
         cornerRadius: CGFloat = 10) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.zIndex = zIndex
        self.fontName = fontName
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.isBold = isBold
        self.text = text
        self.imageFile = imageFile
        self.cornerRadius = cornerRadius
    }

    static func makeText(_ string: String = "", frame: CGRect, zIndex: Int) -> BoardItem {
        BoardItem(kind: .text, frame: frame, zIndex: zIndex, text: string)
    }
}

enum AppDefaults {
    static let defaultFontName: String? = "System"   // 系统默认字体（苹方回退），最大兼容
    static let defaultFontSize: CGFloat = 22
    static let defaultTextColor = "#FFFFFF"
    static let defaultBold = true

    // MARK: 用户设置（UserDefaults）

    static let followAllSpacesKey = "followAllSpaces"
    /// 画布内容是否跟随全部桌面 Space（开启 = 继承到每个桌面；关闭 = 仅存在于当前 Space）
    static var followAllSpaces: Bool {
        get { UserDefaults.standard.object(forKey: followAllSpacesKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: followAllSpacesKey) }
    }
}

/// 根据设置构造窗口的 Space 行为（两种窗口共用同一规则，保证壁纸层与编辑层一致）
enum SpaceBehavior {
    static func collectionBehavior() -> NSWindow.CollectionBehavior {
        var b: NSWindow.CollectionBehavior = [.stationary, .ignoresCycle]
        if AppDefaults.followAllSpaces {
            b.insert(.canJoinAllSpaces)
        }
        return b
    }
}

// MARK: - 颜色工具

enum ColorHex {
    static func hex(from color: NSColor) -> String {
        let c = color.usingColorSpace(.deviceRGB) ?? NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1)
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    static func color(from hex: String) -> NSColor? {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1)
    }

    /// 相对亮度（0…1），用于自动选择编辑卡的深浅材质
    static func luminance(of color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.deviceRGB) ?? .white
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

// MARK: - 字体

enum AppFonts {
    static func font(name: String?, size: CGFloat, bold: Bool) -> NSFont {
        let sz = max(8, min(size, 300))
        var base: NSFont
        if let n = name, !n.isEmpty, n != "System", let f = NSFont(name: n, size: sz) {
            base = f
        } else {
            base = NSFont.systemFont(ofSize: sz, weight: .regular)
        }
        if bold {
            base = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        }
        return base
    }
}

// MARK: - 文本排版工具（壁纸层与编辑层共用同一测量算法，保证所见即所得）

enum TextLayout {
    /// 构建统一富文本：字体、颜色、自动换行、轻投影（仅展示用 shadow）
    static func styledText(_ string: String,
                           font: NSFont,
                           color: NSColor,
                           shadow: NSShadow? = nil) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 0
        p.paragraphSpacing = 0
        p.alignment = .left
        p.lineBreakMode = .byWordWrapping

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: p,
        ]
        if let shadow { attrs[.shadow] = shadow }
        return NSAttributedString(string: string, attributes: attrs)
    }

    /// 用 NSLayoutManager 精确测量换行后高度（与 NSTextView 渲染一致）。
    /// 底部附加安全余量，避免最后一行因字体行高/换行边界误差而被容器裁掉。
    static func height(text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let w = max(1, width)
        guard !text.isEmpty else { return ceil(lineHeight(font)) + 6 }
        let storage = NSTextStorage(attributedString: styledText(text, font: font, color: .white))
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: w, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        _ = manager.glyphRange(for: container)
        let used = manager.usedRect(for: container).height
        return ceil(max(used, lineHeight(font))) + 6
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: font)
    }

    /// 给纯展示文本加投影，壁纸上更可读
    static func readingShadow() -> NSShadow {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.45)
        s.shadowOffset = NSSize(width: 0, height: -1)
        s.shadowBlurRadius = 3
        return s
    }
}

// MARK: - 卡片几何：内容矩形(贴在壁纸上的可见矩形) ⇄ 编辑卡窗口矩形
// 卡片自上而下（y-up 从底部往上排）：内容 → 间距 → 格式条 → 拖动条 → 顶部边距
// 文本内容矩形 == item.frame（最终贴在壁纸上的文字区域）

enum BoardLayout {
    static let topPad: CGFloat = 10
    static let handleHeight: CGFloat = 22
    static let barHeight: CGFloat = 30
    static let barGap: CGFloat = 10

    static let textSidePad: CGFloat = 14
    static let textBottomPad: CGFloat = 14
    static var textTopExtra: CGFloat { topPad + handleHeight + barHeight + barGap } // 72

    static let imageSidePad: CGFloat = 12
    static let imageBottomPad: CGFloat = 12
    static var imageTopExtra: CGFloat { topPad + handleHeight + barHeight + barGap } // 与文字一致，72

    static func textCardRect(content: CGRect) -> CGRect {
        CGRect(x: content.minX - textSidePad,
               y: content.minY - textBottomPad,
               width: content.width + textSidePad * 2,
               height: content.height + textBottomPad + textTopExtra)
    }

    static func textContentRect(card: CGRect) -> CGRect {
        CGRect(x: card.minX + textSidePad,
               y: card.minY + textBottomPad,
               width: card.width - textSidePad * 2,
               height: card.height - textBottomPad - textTopExtra)
    }

    static func imageCardRect(content: CGRect) -> CGRect {
        CGRect(x: content.minX - imageSidePad,
               y: content.minY - imageBottomPad,
               width: content.width + imageSidePad * 2,
               height: content.height + imageBottomPad + imageTopExtra)
    }

    static func imageContentRect(card: CGRect) -> CGRect {
        CGRect(x: card.minX + imageSidePad,
               y: card.minY + imageBottomPad,
               width: card.width - imageSidePad * 2,
               height: card.height - imageBottomPad - imageTopExtra)
    }

    static func cardRect(forContent content: CGRect, kind: BoardItem.Kind) -> CGRect {
        kind == .text ? textCardRect(content: content) : imageCardRect(content: content)
    }

    static func contentRect(forCard card: CGRect, kind: BoardItem.Kind) -> CGRect {
        kind == .text ? textContentRect(card: card) : imageContentRect(card: card)
    }
}

// MARK: - Store（单一数据源 + 持久化）

final class BoardStore {
    static let didChange = Notification.Name("AcrylicBoard.didChange")

    private(set) var items: [BoardItem] = []
    private(set) var directory: URL
    private(set) var imagesDirectory: URL
    private let fileURL: URL
    private var saveTimer: Timer?
    private var imageCache: [String: NSImage] = [:]

    let logger = Logger(subsystem: "local.AcrylicBoard", category: "store")

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AcrylicBoard", isDirectory: true)
        directory = base
        imagesDirectory = base.appendingPathComponent("images", isDirectory: true)
        fileURL = base.appendingPathComponent("boards.json")
        try? fm.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: 读取

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let doc = try JSONDecoder().decode(BoardDocument.self, from: data)
            items = doc.items.sorted { $0.zIndex < $1.zIndex }
        } catch {
            logger.error("boards.json 解码失败: \(error.localizedDescription)")
        }
    }

    // MARK: 写入（防抖 + 原子替换）

    func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(BoardDocument(items: items))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("写入 boards.json 失败: \(error.localizedDescription)")
        }
    }

    // MARK: 变更

    func upsert(_ item: BoardItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i] = item
        } else {
            items.append(item)
            items.sort { $0.zIndex < $1.zIndex }
        }
        scheduleSave()
        NotificationCenter.default.post(name: BoardStore.didChange, object: self)
    }

    @discardableResult
    func addText(_ string: String = "", frame: CGRect, zIndex: Int? = nil) -> BoardItem {
        let item = BoardItem.makeText(string, frame: frame, zIndex: zIndex ?? items.count)
        upsert(item)
        return item
    }

    func remove(id: UUID) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            let removed = items.remove(at: idx)
            if let f = removed.imageFile {
                try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(f))
                imageCache.removeValue(forKey: f)
            }
            scheduleSave()
            NotificationCenter.default.post(name: BoardStore.didChange, object: self)
        }
    }

    func clearAll() {
        for item in items {
            if let f = item.imageFile {
                try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(f))
                imageCache.removeValue(forKey: f)
            }
        }
        items.removeAll()
        scheduleSave()
        NotificationCenter.default.post(name: BoardStore.didChange, object: self)
    }

    // MARK: 数据自检

    /// 对历史文字卡做“高度体检”：高度不足以容纳当前文字时，按文字实际排版补足（顶部锚定）。
    /// 旧数据可能存了偏小的 frame 高，导致桌面文字末行与编辑视图被容器截断。
    func healTextHeights() {
        var changed = false
        for i in items.indices where items[i].kind == .text && !items[i].text.isEmpty {
            let it = items[i]
            let font = AppFonts.font(name: it.fontName, size: it.fontSize, bold: it.isBold)
            let needed = TextLayout.height(text: it.text, font: font, width: max(60, it.frame.width))
            if it.frame.height < needed - 1 {
                var fixed = it
                let top = fixed.frame.maxY
                fixed.frame.size.height = needed
                fixed.frame.origin.y = top - needed
                items[i] = fixed
                changed = true
            }
        }
        if changed {
            saveNow()
            NotificationCenter.default.post(name: BoardStore.didChange, object: self)
        }
    }

    // MARK: 图片

    /// 将图片降采样存入本地，返回文件名
    func importImage(fromImage nsImage: NSImage) -> String? {
        guard let cg = nsImage.cgImageSafe else { return nil }
        guard let data = Self.downsampledPNG(cg) else { return nil }
        let name = UUID().uuidString + ".png"
        do {
            try data.write(to: imagesDirectory.appendingPathComponent(name), options: .atomic)
        } catch {
            return nil
        }
        imageCache[name] = NSImage(data: data)
        return name
    }

    func importImage(from url: URL) -> String? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        return importImage(fromImage: img)
    }

    func importImage(fromPasteboard pb: NSPasteboard) -> String? {
        if let items = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = items.first {
            return importImage(fromImage: img)
        }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let img = NSImage(data: data) {
            return importImage(fromImage: img)
        }
        return nil
    }

    func image(named file: String) -> NSImage? {
        if let cached = imageCache[file] { return cached }
        let url = imagesDirectory.appendingPathComponent(file)
        if let img = NSImage(contentsOf: url) {
            imageCache[file] = img
            return img
        }
        return nil
    }

    /// 图片初始摆放：按比例缩到“最长边 ≤ maxSide”
    func fitFrame(forImageNamed file: String, maxSide: CGFloat) -> CGRect? {
        guard let img = image(named: file) else { return nil }
        let w = max(8, img.size.width)
        let h = max(8, img.size.height)
        let scale = min(1, maxSide / max(w, h))
        return CGRect(x: 0, y: 0, width: (w * scale).rounded(), height: (h * scale).rounded())
    }

    private static func downsampledPNG(_ cg: CGImage, maxLongSide: CGFloat = 2560) -> Data? {
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, maxLongSide / max(w, h))
        let tw = max(1, Int((w * scale).rounded()))
        let th = max(1, Int((h * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let ctx = CGContext(data: nil,
                                  width: tw, height: th,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        return rep.representation(using: .png, properties: [:])
    }
}

private struct BoardDocument: Codable {
    var items: [BoardItem]
}

extension NSImage {
    /// 当前图像对应的 CGImage（含多表示的取第一帧）
    var cgImageSafe: CGImage? {
        var rect = NSRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
