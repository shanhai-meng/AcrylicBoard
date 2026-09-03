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

// MARK: - 用户设置 & 画布作用域

/// 一块画布的内容归属：要么是“跟随全部桌面的全局画布”，要么是“某个桌面(Space)的独立画布”。
enum BoardScope: Hashable {
    case global
    case space(SpaceManager.SpaceID)

    var fileName: String {
        switch self {
        case .global: return "boards.json"
        case .space(let id): return "boards.space-\(id).json"
        }
    }
}

enum AppDefaults {
    static let defaultFontName: String? = "System"   // 系统默认字体（苹方回退），最大兼容
    static let defaultFontSize: CGFloat = 22
    static let defaultTextColor = "#FFFFFF"
    static let defaultBold = true

    // MARK: 用户设置（UserDefaults）

    static let followAllSpacesKey = "followAllSpaces"
    /// 画布是否“在全部桌面 Space 显示”。
    /// - true：所有桌面看到同一块全局画布（继承）；
    /// - false：每个桌面各自独立画布，互不显示对方内容。
    static var followAllSpaces: Bool {
        get { UserDefaults.standard.object(forKey: followAllSpacesKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: followAllSpacesKey) }
    }
}

/// 根据设置/作用域构造窗口的 Space 行为。
/// - 全局画布：跟随全部桌面（加入所有 Space）；
/// - 某个 Space 的独立画布：仅停留在其创建时所在的 Space（天然如此，无需 canJoinAllSpaces）。
enum SpaceBehavior {
    static func collectionBehavior(joiningAllSpaces: Bool? = nil) -> NSWindow.CollectionBehavior {
        var b: NSWindow.CollectionBehavior = [.stationary, .ignoresCycle]
        if joiningAllSpaces ?? AppDefaults.followAllSpaces {
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

// MARK: - Store（单一数据源 + 按画布作用域持久化）

final class BoardStore {
    static let didChange = Notification.Name("AcrylicBoard.didChange")

    private(set) var directory: URL
    private(set) var imagesDirectory: URL

    /// 当前生效作用域：全局画布 或 当前桌面(Space)的独立画布
    private(set) var scope: BoardScope = .global

    /// 各作用域的内存数据（惰性加载；只在访问过/切换到的桌面才载入）
    private var boards: [BoardScope: [BoardItem]] = [:]

    private var saveTimer: Timer?
    /// 最近一次变更所属的作用域，防抖落盘用（避免切桌面后才触发的保存写错文件）
    private var pendingSaveScope: BoardScope?
    private var imageCache: [String: NSImage] = [:]

    let logger = Logger(subsystem: "local.AcrylicBoard", category: "store")

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AcrylicBoard", isDirectory: true)
        directory = base
        imagesDirectory = base.appendingPathComponent("images", isDirectory: true)
        try? fm.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        _ = loadBoardIfNeeded(.global)   // 预载全局画布（旧版 boards.json 数据）
    }

    // MARK: 作用域管理

    /// 当前作用域下的条目（兼容旧调用方）
    var items: [BoardItem] { items(for: scope) }

    /// 取某作用域的画布条目（惰性加载）
    func items(for key: BoardScope) -> [BoardItem] {
        loadBoardIfNeeded(key)
        return boards[key] ?? []
    }

    /// 切换到指定作用域：先落盘上一个作用域数据，再载入目标作用域并通知刷新。
    func setScope(_ key: BoardScope) {
        saveNow()
        guard scope != key else { return }
        scope = key
        _ = loadBoardIfNeeded(key)
        NotificationCenter.default.post(name: BoardStore.didChange, object: self)
    }

    func hasScopeFile(_ key: BoardScope) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: key).path)
    }

    /// 把 A 作用域的内容整块复制到 B 作用域（迁移用），并立即落盘 B。
    func assignContent(from fromKey: BoardScope, to toKey: BoardScope) {
        guard fromKey != toKey else { return }
        let source = items(for: fromKey)
        boards[toKey] = source
        save(board: toKey)
    }

    /// 从“跟随全局”首次切到某独立桌面时调用：若该桌面尚无数据文件，则把当前全局画布作为起点，
    /// 保证“我现在看到的板子”不会凭空消失；已有数据的桌面保持独立不受影响。
    func seedFromGlobalIfNeeded(into key: BoardScope) {
        guard case .space = key else { return }
        guard !hasScopeFile(key) else { return }
        let source = items(for: .global)
        guard !source.isEmpty else { return }
        boards[key] = source
        save(board: key)
    }

    /// 丢弃某桌面作用域：清掉其引用图片、内存缓存，并删除磁盘数据文件。
    /// 用于系统删除桌面(Space)后，让该桌面的画布内容随之消失。
    func discardScope(_ key: BoardScope) {
        saveNow()   // 先落盘待保存内容，避免后续写回已删除作用域
        let fm = FileManager.default
        if let arr = boards[key] {
            for item in arr {
                if let f = item.imageFile {
                    try? fm.removeItem(at: imagesDirectory.appendingPathComponent(f))
                    imageCache.removeValue(forKey: f)
                }
            }
        }
        boards.removeValue(forKey: key)
        try? fm.removeItem(at: fileURL(for: key))
        NotificationCenter.default.post(name: BoardStore.didChange, object: self)
    }

    @discardableResult
    private func loadBoardIfNeeded(_ key: BoardScope) -> [BoardItem]? {
        if boards[key] != nil { return boards[key] }
        var loaded: [BoardItem] = []
        let url = fileURL(for: key)
        if let data = try? Data(contentsOf: url) {
            do {
                let doc = try JSONDecoder().decode(BoardDocument.self, from: data)
                loaded = doc.items.sorted { $0.zIndex < $1.zIndex }
            } catch {
                logger.error("\(key.fileName) 解码失败: \(error.localizedDescription)")
            }
        }
        boards[key] = loaded
        return loaded
    }

    // MARK: 写入（防抖 + 原子替换）

    func scheduleSave() {
        let key = pendingSaveScope ?? scope
        saveTimer?.invalidate()
        pendingSaveScope = key
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        let key = pendingSaveScope ?? scope
        pendingSaveScope = nil
        save(board: key)
    }

    private func save(board key: BoardScope) {
        guard let data = boards[key] else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded = try encoder.encode(BoardDocument(items: data))
            try encoded.write(to: fileURL(for: key), options: .atomic)
        } catch {
            logger.error("写入 \(key.fileName) 失败: \(error.localizedDescription)")
        }
    }

    // MARK: 变更

    func upsert(_ item: BoardItem) {
        let key = boardScope(of: item.id) ?? scope
        var arr = boards[key] ?? (loadBoardIfNeeded(key) ?? [])
        if let i = arr.firstIndex(where: { $0.id == item.id }) {
            arr[i] = item
        } else {
            arr.append(item)
            arr.sort { $0.zIndex < $1.zIndex }
        }
        boards[key] = arr
        pendingSaveScope = key
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
        guard let key = boardScope(of: id) else { return }
        var arr = boards[key] ?? []
        if let idx = arr.firstIndex(where: { $0.id == id }) {
            let removed = arr.remove(at: idx)
            if let f = removed.imageFile {
                try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(f))
                imageCache.removeValue(forKey: f)
            }
            boards[key] = arr
            pendingSaveScope = key
            scheduleSave()
            NotificationCenter.default.post(name: BoardStore.didChange, object: self)
        }
    }

    func clearAll() {
        let key = scope
        let arr = boards[key] ?? (loadBoardIfNeeded(key) ?? [])
        for item in arr {
            if let f = item.imageFile {
                try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(f))
                imageCache.removeValue(forKey: f)
            }
        }
        boards[key] = []
        pendingSaveScope = key
        scheduleSave()
        NotificationCenter.default.post(name: BoardStore.didChange, object: self)
    }

    private func boardScope(of id: UUID) -> BoardScope? {
        for (key, arr) in boards where arr.contains(where: { $0.id == id }) {
            return key
        }
        return nil
    }

    // MARK: 数据自检

    /// 对“当前作用域”历史文字卡做高度体检：高度不足容纳当前文字时按实际排版补足（顶部锚定）。
    func healTextHeights() {
        let key = scope
        _ = loadBoardIfNeeded(key)
        guard var arr = boards[key] else { return }
        var changed = false
        for i in arr.indices where arr[i].kind == .text && !arr[i].text.isEmpty {
            let it = arr[i]
            let font = AppFonts.font(name: it.fontName, size: it.fontSize, bold: it.isBold)
            let needed = TextLayout.height(text: it.text, font: font, width: max(60, it.frame.width))
            if it.frame.height < needed - 1 {
                var fixed = it
                let top = fixed.frame.maxY
                fixed.frame.size.height = needed
                fixed.frame.origin.y = top - needed
                arr[i] = fixed
                changed = true
            }
        }
        if changed {
            boards[key] = arr
            pendingSaveScope = key
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

    private func fileURL(for key: BoardScope) -> URL {
        directory.appendingPathComponent(key.fileName)
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
