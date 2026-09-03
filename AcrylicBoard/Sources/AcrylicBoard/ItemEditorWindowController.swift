import AppKit

// MARK: - 顶部拖拽条（视觉提示 + 拖动事件源）
// 采用「锚点跟随」而非增量累加：每次拖动都按“按下时的偏移 + 鼠标当前位置”直接对齐窗口，
// 快速拖动时即使事件被合并/丢帧，窗口也始终与鼠标 1:1 同步，不会越拖越滞后。

final class DragHandleView: NSView {
    /// 按下瞬间（窗口将开始跟随鼠标）
    var onGrab: (() -> Void)?
    /// 拖动中：参数为当前全局鼠标位置
    var onDragTo: ((CGPoint) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onGrab?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDragTo?(NSEvent.mouseLocation)
    }


    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dot = NSColor.secondaryLabelColor.withAlphaComponent(0.55)
        dot.setFill()
        let r: CGFloat = 1.6
        let gapX: CGFloat = 10
        let gapY: CGFloat = 6
        let rows = 2, cols = 3
        let totalW = CGFloat(cols - 1) * gapX
        let totalH = CGFloat(rows - 1) * gapY
        let ox = bounds.midX - totalW / 2
        let oy = bounds.midY - totalH / 2
        for row in 0..<rows {
            for col in 0..<cols {
                let x = ox + CGFloat(col) * gapX
                let y = oy + CGFloat(row) * gapY
                NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
            }
        }
    }
}

// MARK: - 右下角缩放手柄

final class ResizeHandleView: NSView {
    /// 按下瞬间（记录起始几何）
    var onGrab: (() -> Void)?
    /// 拖动中：参数为当前全局鼠标位置
    var onDragTo: ((CGPoint) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onGrab?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDragTo?(NSEvent.mouseLocation)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color = NSColor.secondaryLabelColor.withAlphaComponent(0.8)
        color.setStroke()
        let w = bounds.width
        for i in 0..<3 {
            let x = w - 5 - CGFloat(i) * 5
            let y = 5 + CGFloat(i) * 5
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: y))
            path.line(to: NSPoint(x: x + 3, y: y))
            path.line(to: NSPoint(x: x, y: y + 3))
            path.lineWidth = 1.2
            path.stroke()
        }
    }
}

// MARK: - 拖放接收视图（整卡接收 Finder 图片拖入）

final class EditorDropView: NSView {
    var onFileDrop: ((URL, NSPoint) -> Void)?  // URL + 落点(窗口本地坐标)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let hasImage = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                             options: [.urlReadingFileURLsOnly: true])?.contains { ($0 as? URL)?.isImageFile == true } == true
        return hasImage ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let url = urls.first(where: { $0.isImageFile }) else { return false }
        let local = convert(sender.draggingLocation, from: nil)
        onFileDrop?(url, local)
        return true
    }
}

extension URL {
    var isImageFile: Bool {
        let exts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp"]
        return exts.contains(pathExtension.lowercased())
    }
}

// MARK: - 编辑浮层窗口控制器

/// 每条 item 对应一个浮层编辑窗：
/// 拖动位置 / 缩放 / 输入文字(中文 IME) / 改样式 / 擦除，改动实时写回 BoardStore 与壁纸层。
final class ItemEditorWindowController: NSObject {
    private let store: BoardStore
    let itemID: UUID
    private(set) var kind: BoardItem.Kind
    private var current: BoardItem

    private let window: BoardWindow
    private let root = EditorDropView(frame: .zero)
    private let effect = NSVisualEffectView()
    private let tintView = NSView()
    private let handle = DragHandleView()
    private let resize = ResizeHandleView()
    private let bar = FormatBarView()
    private let textView = NSTextView(frame: .zero)
    private let imageView = NSImageView()
    private let placeholder = NSTextField(labelWithString: "在这里书写…")

    var onDelete: ((UUID) -> Void)?
    var onRequestExitEdit: (() -> Void)?

    /// 供外部（AppDelegate 键盘监视）识别当前窗口
    var editorWindow: BoardWindow { window }

    private var currentImageAspect: CGFloat = 1

    /// 文字卡被用户纵向拖高后的固定高度（仅当大于文字自然高度时有意义）；
    /// nil = 高度始终跟随文字自动伸缩
    private var pinnedTextHeight: CGFloat?

    // 拖动/缩放的手势状态（锚点跟随法：按下记录基准，拖动按鼠标当前位置一次性对齐，保证不滞后）
    private var dragGrabOffset = CGPoint.zero
    private var resizeStartMouse = CGPoint.zero
    private var resizeStartContent: CGRect = .zero
    private var resizeStartPinned: CGFloat?

    init?(store: BoardStore, item: BoardItem) {
        guard item.kind == .text || item.kind == .image else { return nil }
        self.store = store
        self.itemID = item.id
        self.current = item
        self.kind = item.kind

        let rect = BoardLayout.cardRect(forContent: item.frame, kind: item.kind)
        let w = BoardWindow(contentRect: rect, styleMask: .borderless)
        self.window = w
        super.init()
        configureWindow()
        buildUI()
        syncFromModel()
    }

    // MARK: 配置

    private func configureWindow() {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.allowsBecomeKey = true
        window.allowsUnconstrainedFrame = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = SpaceBehavior.collectionBehavior()
        window.hidesOnDeactivate = false
        window.delegate = self
        window.contentView = root
    }

    /// 用户切换“是否跟随全部桌面 Space”后调用，实时更新本编辑浮层归属
    func applySpaceBehavior() {
        window.collectionBehavior = SpaceBehavior.collectionBehavior()
    }

    private func buildUI() {
        root.wantsLayer = false

        // 亚克力底
        effect.frame = root.bounds
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        tintView.frame = effect.bounds
        tintView.wantsLayer = true
        tintView.autoresizingMask = [.width, .height]

        // 文本
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.font = .systemFont(ofSize: 22)
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false

        // 图片
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true

        // 占位符
        placeholder.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.7)
        placeholder.font = .systemFont(ofSize: 15)
        placeholder.isSelectable = false
        placeholder.isEditable = false
        placeholder.drawsBackground = false
        placeholder.isBezeled = false
        placeholder.isBordered = false
        let click = NSClickGestureRecognizer(target: self, action: #selector(focusText))
        placeholder.addGestureRecognizer(click)

        // 顶部拖动条 + 右下角缩放（锚点跟随：按下记录偏移/起点，拖动按鼠标当前位置一次性对齐）
        handle.onGrab = { [weak self] in
            guard let self else { return }
            let m = NSEvent.mouseLocation
            self.dragGrabOffset = CGPoint(x: self.window.frame.origin.x - m.x,
                                          y: self.window.frame.origin.y - m.y)
        }
        handle.onDragTo = { [weak self] mouse in
            guard let self else { return }
            var f = self.window.frame
            f.origin = CGPoint(x: mouse.x + self.dragGrabOffset.x,
                               y: mouse.y + self.dragGrabOffset.y)
            // 只移动不改尺寸：几何写回交给 windowDidMove，拖动中不重排子视图
            self.window.setFrame(f, display: false)
        }
        resize.onGrab = { [weak self] in
            guard let self else { return }
            self.resizeStartMouse = NSEvent.mouseLocation
            self.resizeStartContent = self.current.frame
            self.resizeStartPinned = self.pinnedTextHeight
        }
        resize.onDragTo = { [weak self] mouse in
            guard let self else { return }
            let dx = mouse.x - self.resizeStartMouse.x
            let dy = mouse.y - self.resizeStartMouse.y
            self.applyResize(totalX: dx, totalY: dy)
        }

        // 格式条
        bar.onFontChange = { [weak self] name in
            guard let self, self.kind == .text else { return }
            self.current.fontName = name
            self.applyTextStyle()
            self.focusText()
        }
        bar.onSizeChange = { [weak self] size in
            guard let self, self.kind == .text else { return }
            self.current.fontSize = size
            self.applyTextStyle()
            self.focusText()
        }
        bar.onBoldChange = { [weak self] bold in
            guard let self, self.kind == .text else { return }
            self.current.isBold = bold
            self.applyTextStyle()
            self.focusText()
        }
        bar.onColorChange = { [weak self] color in
            guard let self, self.kind == .text else { return }
            self.current.colorHex = ColorHex.hex(from: color)
            self.applyTextStyle()
            self.focusText()
        }
        bar.onDelete = { [weak self] in
            guard let self else { return }
            self.onDelete?(self.itemID)
        }

        bar.setImageMode(kind == .image)

        // 组装
        effect.addSubview(tintView)
        root.addSubview(effect)
        root.addSubview(bar)
        root.addSubview(handle)
        root.addSubview(textView)
        root.addSubview(imageView)
        root.addSubview(placeholder)
        root.addSubview(resize)

        root.onFileDrop = { [weak self] url, _ in
            guard let self else { return }
            // 以卡中心附近落点：drop 本地坐标 → 全局坐标
            let local = self.window.frame.origin
            let globalPoint = CGPoint(x: local.x + self.window.frame.midX,
                                      y: local.y + self.window.frame.midY)
            self.addImageItem(from: url, center: globalPoint)
        }
    }

    // MARK: 显示 / 聚焦

    func show(focus: Bool = false) {
        window.orderFrontRegardless()
        if focus {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
            focusText()
        }
    }

    @objc func focusText() {
        guard kind == .text else { return }
        window.makeKey()
        window.makeFirstResponder(textView)
    }

    func close() {
        window.orderOut(nil)
    }

    // MARK: 从模型同步 UI

    private func syncFromModel() {
        if kind == .text {
            placeholder.isHidden = !current.text.isEmpty
            textView.string = current.text
            restyleTextStorage()
            // 格式条同步当前真实样式（否则下拉永远停在默认“12”）
            bar.setCurrent(fontName: current.fontName,
                           size: current.fontSize,
                           bold: current.isBold,
                           color: ColorHex.color(from: current.colorHex) ?? .white)
            if current.text.isEmpty {
                layoutCard()
                DispatchQueue.main.async { [weak self] in self?.focusText() }
            } else {
                // 初次打开就按实际文本把高度校正到能完整容纳，
                // 解决旧数据里 frame 高度不足导致的“文字被卡 / 末行消失”
                let font = AppFonts.font(name: current.fontName, size: current.fontSize, bold: current.isBold)
                let autoH = TextLayout.height(text: current.text, font: font,
                                              width: max(60, current.frame.width))
                if current.frame.height > autoH + 2 {
                    pinnedTextHeight = current.frame.height   // 原就比文字高的空间视为手动留白，保留
                }
                autosizeTextAndPersist()
            }
        } else {
            placeholder.isHidden = true
            if let img = store.image(named: current.imageFile ?? "") {
                imageView.image = img
                let size = img.size
                currentImageAspect = (size.height > 0 && size.width > 0) ? size.height / size.width : 1
            }
            bar.setCurrent(fontName: nil, size: 22, bold: false, color: .white)
            layoutCard()
        }
        refreshMaterial()
        bar.setImageMode(kind == .image)
    }

    private func refreshMaterial() {
        var light = true
        if kind == .text, let c = ColorHex.color(from: current.colorHex) {
            light = ColorHex.luminance(of: c) < 0.5   // 深色字 → 浅色卡；浅色字 → 深色卡
        }
        if light {
            effect.material = .popover
            tintView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        } else {
            effect.material = .hudWindow
            tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        }
        effect.needsDisplay = true
    }

    // MARK: 几何

    private func layoutCard() {
        guard let content = window.contentView else { return }
        let b = content.bounds
        effect.frame = b
        tintView.frame = b

        if kind == .text {
            let contentRect = BoardLayout.textContentRect(card: b)
            textView.frame = contentRect
            placeholder.frame = contentRect.insetBy(dx: 4, dy: 0)
            imageView.isHidden = true
            textView.isHidden = false
            bar.isHidden = false
        } else {
            let contentRect = BoardLayout.imageContentRect(card: b)
            imageView.frame = contentRect
            textView.isHidden = true
            imageView.isHidden = false
            bar.isHidden = false
        }

        // bar 位于内容之上、handle 之下
        let contentTop = kind == .text ? BoardLayout.textContentRect(card: b).maxY
                                       : BoardLayout.imageContentRect(card: b).maxY
        bar.frame = NSRect(x: 6, y: contentTop + BoardLayout.barGap,
                           width: b.width - 12, height: BoardLayout.barHeight)
        handle.frame = NSRect(x: 0, y: bar.frame.maxY,
                              width: b.width, height: BoardLayout.handleHeight)

        let rs: CGFloat = 22
        resize.frame = NSRect(x: b.width - rs - 3, y: 3, width: rs, height: rs)

        placeholder.isHidden = !(kind == .text && textView.string.isEmpty)
    }

    /// 重新计算文字高度并调整窗口（顶部锚定），然后写回模型
    private func autosizeTextAndPersist() {
        guard kind == .text else { return }
        current.text = textView.string

        let font = AppFonts.font(name: current.fontName, size: current.fontSize, bold: current.isBold)
        let width = max(60, current.frame.width)
        let autoH = TextLayout.height(text: current.text, font: font, width: width)

        let top = current.frame.maxY
        var content = current.frame
        content.size.width = width
        content.size.height = resolveTextHeight(autoH: autoH)
        content.origin.y = top - content.size.height
        current.frame = content
        store.upsert(current)
        applyWindowFrameFromContent()
        placeholder.isHidden = !current.text.isEmpty
    }

    /// 编辑框实际高度：有手动留白(pin)时不低于 pin 与文字自然高的较大值；否则跟随文字自动伸缩
    private func resolveTextHeight(autoH: CGFloat) -> CGFloat {
        let h: CGFloat
        if let p = pinnedTextHeight {
            h = max(autoH, p)
            if h <= autoH + 0.5 {
                pinnedTextHeight = nil   // 文字长高已超过手动高度，回到纯自动
            }
        } else {
            h = autoH
        }
        return max(20, h)
    }

    private func applyTextStyle() {
        restyleTextStorage()
        autosizeTextAndPersist()
        refreshMaterial()
    }

    private func restyleTextStorage() {
        let font = AppFonts.font(name: current.fontName, size: current.fontSize, bold: current.isBold)
        let color = ColorHex.color(from: current.colorHex) ?? .white
        let attr = TextLayout.styledText(textView.string, font: font, color: color)
        textView.textStorage?.setAttributedString(attr)
        textView.typingAttributes = [.font: font, .foregroundColor: color]
    }

    /// 用当前 content.frame 重设窗口 frame 与内部布局
    private func applyWindowFrameFromContent() {
        let card = BoardLayout.cardRect(forContent: current.frame, kind: kind)
        window.setFrame(card, display: true)
        window.contentView?.setFrameSize(card.size)
        layoutCard()
    }

    /// 拖动/挪动窗口后，把窗口几何同步回模型（仅移动时调用，不重排子视图）
    private func syncContentFromCard() {
        let content = BoardLayout.contentRect(forCard: window.frame, kind: kind)
        current.frame = content
        store.upsert(current)
    }

    /// 缩放：以「按下瞬间」的几何为基准，按鼠标相对起点的总位移一次性计算目标几何，
    /// 避免快速拖动时增量累加产生偏差/滞后。
    private func applyResize(totalX: CGFloat, totalY: CGFloat) {
        guard kind == .text || kind == .image else { return }
        let minW: CGFloat = kind == .text ? 90 : 60
        var content = resizeStartContent
        let top = resizeStartContent.maxY   // 顶部锚定：缩放全程保持顶边不动

        if kind == .image {
            // 右下角手柄：屏幕坐标 y 向上，向下拖为负。取“位移主方向”作为宽度增量：
            // 斜向拖 / 纯横向拖 → 用 totalX；纯纵向拖（|dy|>|dx|）→ 用 -totalY，向下 = 放大。
            let dw: CGFloat = abs(totalX) >= abs(totalY) ? totalX : -totalY
            content.size.width = max(minW, content.width + dw)
            content.size.height = content.width * currentImageAspect
            content.origin.y = top - content.size.height   // 放大时向下延展
            current.frame = content
            store.upsert(current)
            applyWindowFrameFromContent()
            return
        }

        // 文字：宽度随之变化并自动重排；纵向拖动以起点高度为基准增减（不低于文字自然高度）
        current.text = textView.string
        let width = max(minW, content.width + totalX)
        let font = AppFonts.font(name: current.fontName, size: current.fontSize, bold: current.isBold)
        let autoH = TextLayout.height(text: current.text, font: font, width: width)

        var targetH: CGFloat
        if abs(totalY) >= 0.5 {
            // 纵向拖动：屏幕坐标 y 向上，向下拖为负 → “向下 = 加高并向下延伸”
            targetH = max(autoH, content.height - totalY)
        } else if let p = resizeStartPinned, p > autoH + 0.5 {
            targetH = max(autoH, p)   // 纯横向拖动：保留原有手动留白
        } else {
            targetH = autoH
        }
        pinnedTextHeight = targetH > autoH + 0.5 ? targetH : nil

        content.size.width = width
        content.size.height = max(autoH, targetH)
        content.origin.y = top - content.size.height
        current.frame = content
        store.upsert(current)
        applyWindowFrameFromContent()
        placeholder.isHidden = !current.text.isEmpty
    }

    /// 把图片文件加入为新的图片条目
    private func addImageItem(from url: URL, center: CGPoint) {
        guard let fileName = store.importImage(from: url) else { return }
        let size = store.image(named: fileName)?.size ?? NSSize(width: 300, height: 200)
        let scale = min(1, 520 / max(size.width, size.height))
        let w = max(80, size.width * scale)
        let h = max(60, size.height * scale)
        var item = BoardItem(kind: .image,
                             frame: CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h),
                             zIndex: store.items.count,
                             imageFile: fileName)
        item.colorHex = AppDefaults.defaultTextColor
        item.cornerRadius = 10
        store.upsert(item)
        // 立即为它创建一个新的编辑窗（由 AppDelegate 监听做）——通过通知
        NotificationCenter.default.post(name: .acrylicBoardShouldEditNew, object: item)
    }
}

// MARK: - 文本变化 / 窗口移动同步

extension ItemEditorWindowController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard kind == .text else { return }
        autosizeTextAndPersist()
    }
}

extension ItemEditorWindowController: NSWindowDelegate {
    /// 用户拖动窗口（含 isMovableByWindowBackground）后把几何写回模型
    func windowDidMove(_ notification: Notification) {
        syncContentFromCard()
    }
}

extension Notification.Name {
    static let acrylicBoardShouldEditNew = Notification.Name("AcrylicBoard.shouldEditNew")
}
