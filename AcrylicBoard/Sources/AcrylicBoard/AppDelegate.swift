import AppKit
import ServiceManagement
import Carbon.HIToolbox
import UniformTypeIdentifiers
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = BoardStore()
    private var wallpaper: WallpaperWindowController!
    private var controllers: [UUID: ItemEditorWindowController] = [:]
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem?
    private var launchItem: NSMenuItem?
    private var localMonitors: [Any] = []
    private var newImageObserver: NSObjectProtocol?
    private(set) var isEditing = false

    let logger = Logger(subsystem: "local.AcrylicBoard", category: "app")

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 启动先修正历史数据里高度不足的文字卡，避免文字末行/换行被容器截断
        store.healTextHeights()
        wallpaper = WallpaperWindowController(store: store)
        buildMainMenu()
        buildStatusItem()
        registerGlobalHotkeys()

        newImageObserver = NotificationCenter.default.addObserver(
            forName: .acrylicBoardShouldEditNew, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.isEditing, let item = note.object as? BoardItem else { return }
            self.spawnEditor(for: item, focus: false)
        }

        // 调试用：启动即进入编辑模式（./AcrylicBoard --edit）
        if ProcessInfo.processInfo.arguments.contains("--edit") {
            DispatchQueue.main.async { [weak self] in self?.enterEditing() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
        HotKeyController.shared.unregisterAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - 主菜单（保证编辑浮层里 ⌘C/⌘V/撤销等可用）

    private func buildMainMenu() {
        let main = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 亚克力记录板", action: #selector(quit), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        main.addItem(editMenuItem)

        NSApp.mainMenu = main
    }

    // MARK: - 状态栏菜单

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let names = ["note.text", "square.and.pencil", "pencil.and.scribble"]
            var image: NSImage?
            for n in names {
                if let img = NSImage(systemSymbolName: n, accessibilityDescription: "亚克力记录板") {
                    image = img
                    break
                }
            }
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "亚克力记录板"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let toggle = NSMenuItem(title: "编辑模式", action: #selector(toggleEditing(_:)), keyEquivalent: "B")
        toggle.keyEquivalentModifierMask = [.command, .shift]
        toggle.target = self
        toggleItem = toggle
        menu.addItem(toggle)

        menu.addItem(.separator())

        let newText = NSMenuItem(title: "新建文字记录", action: #selector(addText(_:)), keyEquivalent: "N")
        newText.keyEquivalentModifierMask = [.command, .shift]
        newText.target = self
        menu.addItem(newText)

        let importImg = NSMenuItem(title: "导入图片…", action: #selector(importImage(_:)), keyEquivalent: "")
        importImg.target = self
        menu.addItem(importImg)

        let pasteImg = NSMenuItem(title: "粘贴图片", action: #selector(pasteImage(_:)), keyEquivalent: "V")
        pasteImg.keyEquivalentModifierMask = [.command, .shift]
        pasteImg.target = self
        menu.addItem(pasteImg)

        menu.addItem(.separator())

        let openDir = NSMenuItem(title: "打开数据文件夹", action: #selector(revealDataFolder(_:)), keyEquivalent: "")
        openDir.target = self
        menu.addItem(openDir)

        let launch = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launch.target = self
        launchItem = launch
        menu.addItem(launch)

        let clear = NSMenuItem(title: "清空画布…", action: #selector(clearAll(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "关于 亚克力记录板", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        refreshMenuState()
    }

    private func refreshMenuState() {
        toggleItem?.state = isEditing ? .on : .off
        toggleItem?.title = isEditing ? "退出编辑模式" : "进入编辑模式"
        let enabled = SMAppService.mainApp.status == .enabled
        launchItem?.state = enabled ? .on : .off
    }

    // MARK: - 全局快捷键

    private func registerGlobalHotkeys() {
        let hk = HotKeyController.shared
        let cmdShift = UInt32(cmdKey | shiftKey)

        hk.register(id: HotKeys.toggleEdit, keyCode: HotKeys.kVK_ANSI_B, modifiers: cmdShift) { [weak self] in
            self?.toggleEditing(nil)
        }
        hk.register(id: HotKeys.newText, keyCode: HotKeys.kVK_ANSI_N, modifiers: cmdShift) { [weak self] in
            self?.addText(nil)
        }
        hk.register(id: HotKeys.pasteImage, keyCode: HotKeys.kVK_ANSI_V, modifiers: cmdShift) { [weak self] in
            self?.pasteImage(nil)
        }
    }

    // MARK: - 编辑模式

    @objc func toggleEditing(_ sender: Any?) {
        isEditing ? exitEditing() : enterEditing()
    }

    private func enterEditing() {
        guard !isEditing else { return }
        isEditing = true
        wallpaper.setEditing(true)
        for item in store.items {
            spawnEditor(for: item, focus: false)
        }
        installLocalMonitors()
        refreshMenuState()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func exitEditing() {
        guard isEditing else { return }
        isEditing = false
        removeLocalMonitors()
        for (_, c) in controllers { c.close() }
        controllers.removeAll()
        wallpaper.setEditing(false)
        store.saveNow()
        refreshMenuState()
    }

    @discardableResult
    private func spawnEditor(for item: BoardItem, focus: Bool) -> ItemEditorWindowController? {
        guard isEditing else { return nil }
        guard let c = ItemEditorWindowController(store: store, item: item) else { return nil }
        controllers[item.id] = c
        c.onDelete = { [weak self] id in self?.deleteItem(id) }
        c.show(focus: focus)
        return c
    }

    private func deleteItem(_ id: UUID) {
        controllers[id]?.close()
        controllers.removeValue(forKey: id)
        store.remove(id: id)
    }

    // MARK: - 本地键盘监视（编辑期间 Esc / ⌘⌫）

    private func installLocalMonitors() {
        guard localMonitors.isEmpty else { return }
        let tap = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event)
        }
        if let tap { localMonitors.append(tap) }
    }

    private func removeLocalMonitors() {
        for m in localMonitors {
            NSEvent.removeMonitor(m)
        }
        localMonitors.removeAll()
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // 焦点不在我们的编辑窗时原样放行（例如正在用颜色面板）
        guard let keyWindow = NSApp.keyWindow,
              controllers.values.contains(where: { $0.editorWindow === keyWindow }) else {
            return event
        }

        // Esc：若有输入法组字中则放行，否则退出编辑模式
        if event.keyCode == 53 {
            let hasMarked: Bool
            if let tv = keyWindow.firstResponder as? NSTextView {
                hasMarked = tv.hasMarkedText()
            } else {
                hasMarked = false
            }
            if hasMarked { return event }
            DispatchQueue.main.async { [weak self] in self?.exitEditing() }
            return nil
        }
        // ⌘⌫：擦除当前卡片
        if event.keyCode == 51, event.modifierFlags.contains(.command) {
            if let ctrl = controllers.values.first(where: { $0.editorWindow === keyWindow }) {
                DispatchQueue.main.async { [weak self] in self?.deleteItem(ctrl.itemID) }
            }
            return nil
        }
        return event
    }

    // MARK: - 新建/导入

    private func defaultContentRect(width: CGFloat, height: CGFloat) -> CGRect {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        return CGRect(x: screen.frame.midX - width / 2,
                      y: screen.frame.midY - height / 2,
                      width: width,
                      height: height)
    }

    @objc func addText(_ sender: Any?) {
        let rect = defaultContentRect(width: 320, height: 44)
        let item = store.addText("", frame: rect, zIndex: store.items.count)
        if !isEditing { enterEditing() }
        spawnEditor(for: item, focus: true)
    }

    @objc func importImage(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.level = .floating
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.addImageItem(from: url)
        }
    }

    @objc func pasteImage(_ sender: Any?) {
        if let file = NSPasteboard.general.string(forType: .fileURL),
           let url = URL(string: file), url.isImageFile {
            addImageItem(from: url)
        } else if let fileName = store.importImage(fromPasteboard: .general) {
            addImageItem(fileName: fileName)
        } else {
            beep("剪贴板中没有图片")
        }
    }

    private func addImageItem(from url: URL) {
        guard let fileName = store.importImage(from: url) else {
            beep("无法读取该图片")
            return
        }
        addImageItem(fileName: fileName)
    }

    private func addImageItem(fileName: String) {
        guard let fit = store.fitFrame(forImageNamed: fileName, maxSide: 560) else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let centered = CGRect(x: screen.frame.midX - fit.width / 2,
                              y: screen.frame.midY - fit.height / 2,
                              width: fit.width,
                              height: fit.height)
        var item = BoardItem(kind: .image, frame: centered, zIndex: store.items.count, imageFile: fileName)
        item.cornerRadius = 10
        store.upsert(item)
        if isEditing {
            spawnEditor(for: item, focus: false)
        }
    }

    // MARK: - 其它菜单动作

    @objc func toggleLaunchAtLogin(_ sender: Any?) {
        let main = SMAppService.mainApp
        if main.status == .enabled {
            do { try main.unregister() }
            catch { beep("关闭开机自启失败：\(error.localizedDescription)") }
        } else {
            do { try main.register() }
            catch { beep("开启开机自启失败，请把应用放入「应用程序」文件夹后重试。") }
        }
        refreshMenuState()
    }

    @objc func revealDataFolder(_ sender: Any?) {
        NSWorkspace.shared.open(store.directory)
    }

    @objc func clearAll(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "确定要清空整块记录板吗？"
        alert.informativeText = "板上的所有文字与图片都会被擦除，且无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            exitEditing()
            store.clearAll()
        }
    }

    @objc func showAbout(_ sender: Any?) {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let alert = NSAlert()
        alert.messageText = "亚克力记录板 v\(v)"
        alert.informativeText = "一块透明的桌面记录板：文字与图片垫在桌面图标之下、所有窗口之下，平时点击穿透；⌘⇧B 进入编辑模式书写与擦除。"
        alert.runModal()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    private func beep(_ message: String? = nil) {
        if let message { logger.notice("\(message)") }
        NSSound.beep()
    }
}
