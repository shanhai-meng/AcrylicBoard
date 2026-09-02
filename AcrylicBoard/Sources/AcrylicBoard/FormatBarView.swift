import AppKit

/// 编辑卡内嵌的紧凑格式条：字体 / 字号 / 加粗 / 颜色 / 删除
final class FormatBarView: NSView {
    var onFontChange: ((String?) -> Void)?   // nil = 系统默认
    var onSizeChange: ((CGFloat) -> Void)?
    var onBoldChange: ((Bool) -> Void)?
    var onColorChange: ((NSColor) -> Void)?
    var onDelete: (() -> Void)?

    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let boldButton = NSButton()
    private let colorWell = NSColorWell()
    private let deleteButton = NSButton()
    private let styleButton = NSButton()

    static let fontCatalog: [(title: String, psName: String?)] = [
        ("系统默认", nil),
        ("苹方 · 常规", "PingFangSC-Regular"),
        ("苹方 · 中黑", "PingFangSC-Medium"),
        ("苹方 · 粗体", "PingFangSC-Semibold"),
        ("苹方 · 极细", "PingFangSC-Ultralight"),
        ("楷体", "KaitiSC-Regular"),
        ("宋体", "SongtiSC-Regular"),
        ("黑体-简", "STHeitiSC-Medium"),
        ("Helvetica Neue", "HelveticaNeue"),
        ("Avenir Next", "AvenirNext-Regular"),
        ("Futura", "Futura-Medium"),
        ("Menlo", "Menlo-Regular"),
        ("Georgia", "Georgia"),
        ("Times New Roman", "TimesNewRomanPSMT"),
    ]

    static let sizeCatalog: [CGFloat] = [12, 14, 16, 18, 20, 22, 24, 28, 32, 36, 44, 52, 64, 80, 96]

    /// 当前实际字号不在目录档位时，临时插入到下拉框的这一项（让显示值 = 真实值）
    private var dynamicSizeItem: NSMenuItem?

    init() {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func makeMenu<T>(options: [(String, T)], represented: @escaping (T) -> Any?) -> NSMenu {
        let menu = NSMenu()
        for (title, value) in options {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let rep = represented(value) { item.representedObject = rep }
            menu.addItem(item)
        }
        return menu
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        // 字体
        fontPopup.menu = makeMenu(options: Self.fontCatalog.map { ($0.title, $0.psName) }) { $0 as Any? }
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)
        fontPopup.controlSize = .small
        fontPopup.font = .systemFont(ofSize: 11)

        // 字号
        sizePopup.menu = makeMenu(options: Self.sizeCatalog.map { ("\(Int($0))", $0) }) { $0 as Any? }
        sizePopup.target = self
        sizePopup.action = #selector(sizeChanged)
        sizePopup.controlSize = .small
        sizePopup.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        // 加粗
        let boldTitle = NSMutableAttributedString(string: "B")
        boldTitle.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .heavy),
                               range: NSRange(location: 0, length: 1))
        boldButton.attributedTitle = boldTitle
        boldButton.setButtonType(.pushOnPushOff)
        boldButton.bezelStyle = .texturedRounded
        boldButton.controlSize = .small
        boldButton.target = self
        boldButton.action = #selector(boldChanged)
        boldButton.toolTip = "加粗"

        // 颜色
        colorWell.colorWellStyle = .minimal
        colorWell.isBordered = false
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.toolTip = "文字颜色"

        // 删除（擦除本条）
        deleteButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "删除")
        deleteButton.isBordered = false
        deleteButton.bezelStyle = .regularSquare
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.toolTip = "擦除这条（⌘⌫）"

        // 注意：绝不能在 bar 上挂 NSClickGestureRecognizer 做"点空白聚焦"，
        // 它会拦截/延迟鼠标事件，导致下面所有子控件（下拉/按钮/取色器）点击全部失效。

        for v: NSView in [fontPopup, sizePopup, boldButton, colorWell, deleteButton] {
            addSubview(v)
        }
    }

    // MARK: 布局（手动 frame：frame 一旦变化立即重排子控件，不依赖 Autolayout 时机）

    override func layout() {
        super.layout()
        relayoutSubviews()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayoutSubviews()
    }

    private func relayoutSubviews() {
        let h = bounds.height
        let pad: CGFloat = 8
        let gap: CGFloat = 6
        let x0 = pad

        let smallH: CGFloat = 20
        let y = (h - smallH) / 2

        let fontW = min(124, bounds.width - pad * 2)
        let sizeW: CGFloat = 58
        let boldW: CGFloat = 26
        let wellW: CGFloat = 26
        let delW: CGFloat = 22

        fontPopup.frame = NSRect(x: x0, y: y, width: fontW, height: smallH)
        var cx = fontPopup.frame.maxX + gap
        sizePopup.frame = NSRect(x: cx, y: y, width: sizeW, height: smallH)
        cx = sizePopup.frame.maxX + gap
        boldButton.frame = NSRect(x: cx, y: y, width: boldW, height: smallH)
        cx = boldButton.frame.maxX + gap
        colorWell.frame = NSRect(x: cx, y: y, width: wellW, height: smallH)

        deleteButton.frame = NSRect(x: bounds.width - pad - delW, y: y, width: delW, height: smallH)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 底部细分割线
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0.5))
        path.line(to: NSPoint(x: bounds.width, y: 0.5))
        path.lineWidth = 0.5
        NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
        path.stroke()
    }

    // MARK: 同步外部状态

    /// 图片模式：只保留“删除”，隐藏样式控件
    func setImageMode(_ isImage: Bool) {
        fontPopup.isHidden = isImage
        sizePopup.isHidden = isImage
        boldButton.isHidden = isImage
        colorWell.isHidden = isImage
        needsLayout = true
    }

    func setCurrent(fontName: String?, size: CGFloat, bold: Bool, color: NSColor) {
        if let idx = Self.fontCatalog.firstIndex(where: { $0.psName == fontName }) {
            fontPopup.selectItem(at: idx)
        } else if fontName == nil || fontName == "System" {
            fontPopup.selectItem(at: 0)
        } else {
            fontPopup.selectItem(at: 0)
        }

        // 字号：目录里没有的真实字号，按顺序插入一项动态显示，让下拉框始终等于真实字号
        removeDynamicSizeItem()
        if let szIdx = Self.sizeCatalog.firstIndex(where: { abs($0 - size) < 0.5 }) {
            sizePopup.selectItem(at: szIdx)
        } else {
            let item = NSMenuItem(title: "\(Int(size.rounded()))", action: nil, keyEquivalent: "")
            item.representedObject = size
            var insertAt = Self.sizeCatalog.count
            for (i, v) in Self.sizeCatalog.enumerated() where size < v {
                insertAt = i
                break
            }
            sizePopup.menu?.insertItem(item, at: insertAt)
            sizePopup.select(item)
            dynamicSizeItem = item
        }

        boldButton.state = bold ? .on : .off
        colorWell.color = color
    }

    private func removeDynamicSizeItem() {
        if let dyn = dynamicSizeItem {
            sizePopup.menu?.removeItem(dyn)
            dynamicSizeItem = nil
        }
    }

    // MARK: Actions

    @objc private func fontChanged() {
        guard let item = fontPopup.selectedItem else { return }
        let psName = item.representedObject as? String
        onFontChange?(psName)
    }

    @objc private func sizeChanged() {
        guard let item = sizePopup.selectedItem,
              let size = item.representedObject as? CGFloat else { return }
        // 用户改选目录档位后，清掉上一回动态插入的临时项
        if item !== dynamicSizeItem {
            removeDynamicSizeItem()
        }
        onSizeChange?(size)
    }

    @objc private func boldChanged() {
        onBoldChange?(boldButton.state == .on)
    }

    @objc private func colorChanged() {
        onColorChange?(colorWell.color)
    }

    @objc private func deleteTapped() {
        onDelete?()
    }
}
