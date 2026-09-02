import AppKit
import os.log

/// 壁纸层展示窗口：
/// - 全屏透明、垫在 Finder 桌面图标之下（level = desktopIconWindow - 1）、所有普通应用窗口之下
/// - ignoresMouseEvents = true，完全点击穿透
/// - 只做“静态渲染”，一切写入都由浮层编辑窗口完成
final class WallpaperWindowController {
    private let store: BoardStore
    private let scope: BoardScope
    private let window: BoardWindow
    private var itemViews: [UUID: NSView] = [:]
    private var editing = false
    private var observers: [NSObjectProtocol] = []
    let logger = Logger(subsystem: "local.AcrylicBoard", category: "wallpaper")

    /// - Parameters:
    ///   - store: 数据源
    ///   - scope: 本窗口负责渲染的画布作用域（全局 或 某桌面 Space 的独立画布）。
    ///            窗口创建于“当前活跃 Space”，因此 space 作用域窗口会自然归属其桌面。
    init(store: BoardStore, scope: BoardScope = .global) {
        self.store = store
        self.scope = scope
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        window = BoardWindow(contentRect: frame, styleMask: .borderless)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.allowsBecomeKey = false
        window.allowsUnconstrainedFrame = true
        window.isMovable = false
        window.canHide = false
        window.isReleasedWhenClosed = false
        // 仅全局画布才加入所有 Space；独立桌面画布只停留其所在桌面
        window.collectionBehavior = SpaceBehavior.collectionBehavior(joiningAllSpaces: scope == .global)
        window.ignoresMouseEvents = true
        window.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        window.orderFrontRegardless()

        subscribe()
        rebuild()
    }

    /// 释放本窗口（切换模式/桌面后不再需要时调用）
    func tearDown() {
        window.orderOut(nil)
    }

    /// 用户切换“是否跟随全部桌面 Space”后调用，实时更新壁纸层窗口归属
    func applySpaceBehavior() {
        window.collectionBehavior = SpaceBehavior.collectionBehavior(joiningAllSpaces: scope == .global)
        // 从“加入所有 Space”切到“仅当前 Space”等情形下重新注册窗口归属
        window.orderFrontRegardless()
    }

    private func subscribe() {
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter

        observers.append(nc.addObserver(forName: BoardStore.didChange, object: store, queue: .main) { [weak self] _ in
            self?.rebuild()
        })
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            self?.refitToScreen()
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            self?.reassert()
        })
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            self?.reassert()
        })
    }

    // MARK: 对外

    func setEditing(_ editing: Bool) {
        self.editing = editing
        rebuild()
    }

    func refitToScreen() {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            window.setFrame(screen.frame, display: true)
            window.contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
        }
        reassert()
    }

    func reassert() {
        // 睡眠/换 Space/壁纸变化后重新把窗口放到正确层级（桌面层窗口不能被 activate）
        window.orderFrontRegardless()
    }

    // MARK: 渲染

    /// 依据当前 items 重建“双生视图”：编辑模式下整层隐藏，避免与浮层卡片重复。
    private func rebuild() {
        for view in itemViews.values { view.removeFromSuperview() }
        itemViews.removeAll()

        guard !editing else { return }
        guard let content = window.contentView, content.frame.width > 0 else { return }

        let origin = window.frame.origin   // 与 item.frame 同一全局坐标系
        let sorted = store.items(for: scope).sorted { $0.zIndex < $1.zIndex }
        for item in sorted {
            if item.kind == .text {
                if item.text.isEmpty { continue }
                guard let view = makeTextView(item, origin: origin) else { continue }
                itemViews[item.id] = view
                content.addSubview(view)
            } else {
                guard let view = makeImageView(item, origin: origin) else { continue }
                itemViews[item.id] = view
                content.addSubview(view)
            }
        }
    }

    private func localRect(_ global: CGRect, origin: CGPoint) -> CGRect {
        CGRect(x: global.minX - origin.x,
               y: global.minY - origin.y,
               width: global.width,
               height: global.height)
    }

    private func makeTextView(_ item: BoardItem, origin: CGPoint) -> NSView? {
        let color = ColorHex.color(from: item.colorHex) ?? .white
        let font = AppFonts.font(name: item.fontName, size: item.fontSize, bold: item.isBold)
        let attr = TextLayout.styledText(item.text, font: font, color: color,
                                         shadow: TextLayout.readingShadow())
        return TextItemView(frame: localRect(item.frame, origin: origin), text: attr)
    }

    private func makeImageView(_ item: BoardItem, origin: CGPoint) -> NSView? {
        guard let image = store.image(named: item.imageFile ?? "") else { return nil }
        let frame = localRect(item.frame, origin: origin)
        let radius = max(0, item.cornerRadius)

        // 阴影宿主
        let host = NSView(frame: frame)
        host.wantsLayer = true
        host.layer?.shadowColor = NSColor.black.cgColor
        host.layer?.shadowOpacity = 0.30
        host.layer?.shadowRadius = 5
        host.layer?.shadowOffset = NSSize(width: 0, height: -2)

        // 圆角裁切的内容
        let inner = NSImageView(frame: host.bounds)
        inner.imageScaling = .scaleProportionallyUpOrDown
        inner.image = image
        inner.wantsLayer = true
        inner.layer?.cornerRadius = radius
        inner.layer?.masksToBounds = true
        host.addSubview(inner)
        return host
    }
}

// MARK: - 壁纸层文字视图（自绘富文本，避免 NSTextView 静态渲染不生效）

private final class TextItemView: NSView {
    private let text: NSAttributedString

    init(frame frameRect: NSRect, text: NSAttributedString) {
        self.text = text
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        text.draw(in: bounds)
    }
}
