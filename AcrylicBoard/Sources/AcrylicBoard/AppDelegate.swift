import AppKit
import ServiceManagement
import Carbon.HIToolbox
import UniformTypeIdentifiers
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = BoardStore()
    private var wallpaper: WallpaperWindowController!
    /// “各桌面独立”模式下，按桌面(Space ID)持有各自的壁纸窗口
    private var spaceWallpapers: [SpaceManager.SpaceID: WallpaperWindowController] = [:]
    private var lastActiveSpaceID: SpaceManager.SpaceID = 0
    private var activeSpaceObserver: NSObjectProtocol?
    /// 独立模式下的自愈轮询：偶尔系统不派发 activeSpaceDidChange（或通知过早、值还是旧桌面），
    /// 轮询可在切桌面的下一秒把作用域纠正到正确桌面。
    private var spacePoller: Timer?
    private var controllers: [UUID: ItemEditorWindowController] = [:]
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem?
    private var launchItem: NSMenuItem?
    private var spaceItem: NSMenuItem?
    private var updateItem: NSMenuItem?
    private var localMonitors: [Any] = []
    private var newImageObserver: NSObjectProtocol?
    private(set) var isEditing = false

    let logger = Logger(subsystem: "local.AcrylicBoard", category: "app")

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 依据设置建立画布模式（全局 / 当前桌面独立），并按作用域创建壁纸窗口
        configureSpaceMode()
        // 启动先修正历史数据里高度不足的文字卡，避免文字末行/换行被容器截断
        store.healTextHeights()
        buildMainMenu()
        buildStatusItem()
        registerGlobalHotkeys()
        observeSpaceChanges()

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

        let space = NSMenuItem(title: "在全部桌面 Space 显示画布", action: #selector(toggleFollowAllSpaces(_:)), keyEquivalent: "")
        space.target = self
        spaceItem = space
        menu.addItem(space)

        let clear = NSMenuItem(title: "清空画布…", action: #selector(clearAll(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "关于 亚克力记录板", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let update = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        update.target = self
        updateItem = update
        menu.addItem(update)

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
        spaceItem?.state = AppDefaults.followAllSpaces ? .on : .off
    }

    // MARK: - 设置：画布是否跟随全部桌面 Space（继承/不继承）
    // 开 = 所有桌面共享同一块全局画布；关 = 每个桌面各自独立画布（互不显示对方内容），即时生效。

    @objc func toggleFollowAllSpaces(_ sender: Any?) {
        if isEditing { exitEditing() }   // 先收起并保存当前编辑，避免浮层归属错乱
        if AppDefaults.followAllSpaces {
            enterIndependentMode()
        } else {
            enterFollowMode(promoteCurrentSpace: true)
        }
        store.healTextHeights()
        refreshMenuState()
    }

    private func configureSpaceMode() {
        if AppDefaults.followAllSpaces {
            enterFollowMode(promoteCurrentSpace: false)
        } else {
            enterIndependentMode()
        }
    }

    /// 进入“跟随全部桌面”：单一全局画布，窗口加入所有 Space。
    private func enterFollowMode(promoteCurrentSpace: Bool) {
        AppDefaults.followAllSpaces = true
        stopSpacePoller()
        let sid = SpaceManager.activeSpaceID()
        // 由“独立桌面”切回时：把当前所在桌面的独立画布升级为全局画布（用户正看的那块板）
        if promoteCurrentSpace, store.hasScopeFile(.space(sid)) {
            store.assignContent(from: .space(sid), to: .global)
        }
        store.setScope(.global)
        teardownAllWallpapers()
        wallpaper = WallpaperWindowController(store: store, scope: .global)
        lastActiveSpaceID = sid
    }

    /// 进入“各桌面独立”：当前桌面获得独立画布；此后切到哪个桌面就显示哪块的独立内容。
    private func enterIndependentMode() {
        AppDefaults.followAllSpaces = false
        let sid = SpaceManager.activeSpaceID()
        SpaceTrace.log("进入独立模式，当前桌面 space=\(sid)")
        // 若当前桌面还没有独立数据（首次从全局切分），把现全局画布作为该桌面起点
        store.seedFromGlobalIfNeeded(into: .space(sid))
        store.setScope(.space(sid))
        teardownAllWallpapers()
        let w = WallpaperWindowController(store: store, scope: .space(sid))
        spaceWallpapers[sid] = w
        wallpaper = w
        lastActiveSpaceID = sid
        startSpacePoller()
    }

    private func teardownAllWallpapers() {
        wallpaper?.tearDown()
        wallpaper = nil
        for w in spaceWallpapers.values { w.tearDown() }
        spaceWallpapers.removeAll()
    }

    private func observeSpaceChanges() {
        let ws = NSWorkspace.shared.notificationCenter
        activeSpaceObserver = ws.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleActiveSpaceChange()
        }
    }

    /// 独立模式下切换桌面：等 Space 状态稳定后再采样同步（动画期间可能还读到旧桌面）。
    private func handleActiveSpaceChange() {
        guard !AppDefaults.followAllSpaces else { return }   // 跟随模式整板跨桌面可见，无需换板
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.syncToCurrentSpace(reason: "activeSpaceDidChange")
        }
    }

    /// 连续采样到 activeSpaceID=0 的次数；≥3 次判定为探测不可用，自动退化为全局画布
    private var consecutiveZero = 0
    /// 上一次采样到的非零桌面 ID（用于日志，判断桌面间是否确实不同）
    private var lastSampledSpaceID: SpaceManager.SpaceID = 0

    /// 独立模式下的自愈轮询（跟随模式不启用）
    private func startSpacePoller() {
        guard AppDefaults.followAllSpaces == false else { return }
        spacePoller?.invalidate()
        let poller = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.cleanupDeletedSpaces()
            self.syncToCurrentSpace(reason: "poller")
        }
        RunLoop.main.add(poller, forMode: .common)
        spacePoller = poller
        SpaceTrace.log("独立模式：启动空间轮询")
    }

    private func stopSpacePoller() {
        spacePoller?.invalidate()
        spacePoller = nil
    }

    /// 独立模式：若系统已删除某个我们缓存了画布的桌面(Space)，其窗口会被系统挪到相邻桌面，
    /// 导致“桌面 2 的内容跑到桌面 1”。此处定期比对缓存桌面与系统现存桌面：
    /// 不存在的桌面 → 关掉壁纸窗口并清除其画布数据，内容随之消失。
    private func cleanupDeletedSpaces() {
        guard !AppDefaults.followAllSpaces, !spaceWallpapers.isEmpty else { return }
        guard let existing = SpaceManager.existingUserSpaceIDs() else { return }
        let deleted = spaceWallpapers.keys.filter { sid in
            sid != lastActiveSpaceID && !existing.contains(sid)
        }
        guard !deleted.isEmpty else { return }
        for sid in deleted {
            SpaceTrace.log("检测到桌面 space=\(sid) 已删除，清除其画布内容")
            let w = spaceWallpapers[sid]
            w?.tearDown()
            if wallpaper === w { wallpaper = nil }
            spaceWallpapers.removeValue(forKey: sid)
            store.discardScope(.space(sid))
            if store.scope == .space(sid) {
                store.setScope(.global)   // 防御：正常情况不会停留在已删除桌面
            }
        }
    }

    /// 独立模式：把「数据作用域 + 当前壁纸窗口」同步到此刻真正活跃的桌面 Space。
    /// 无论数据落在哪个 scope 文件里，最终渲染都会遵循这里采样到的桌面。
    /// 调用时机：收到 Space 切换通知（延迟后）、周期性自愈、以及进入编辑/新建等用户动作前。
    private func syncToCurrentSpace(reason: String) {
        guard !AppDefaults.followAllSpaces else { return }
        let sid = SpaceManager.activeSpaceID()
        if sid == 0 {
            // 探测失败：不要轻率地新建 space-0 画布。连续多次仍取不到才退化为全局画布，
            // 避免单次瞬时失败误切换。
            consecutiveZero += 1
            SpaceTrace.log("探测异常 activeSpaceID=0（第\(consecutiveZero)次，reason=\(reason)）")
            if consecutiveZero >= 3 {
                SpaceTrace.log("连续探测失败≥3次，退化为全局画布")
                enterFollowMode(promoteCurrentSpace: false)
            }
            return
        }
        consecutiveZero = 0
        if sid != lastSampledSpaceID {
            // 记录新桌面采样（含双 API 原始值），便于验证探测是否随桌面变化
            let d = SpaceManager.diagnosticSample()
            SpaceTrace.log("采样新桌面 space=\(sid) (getActive=\(d.getActive), copyActive=\(d.copyActive), reason=\(reason))")
            lastSampledSpaceID = sid
        }
        let target: BoardScope = .space(sid)

        if store.scope != target {
            SpaceTrace.log("切换作用域 \(store.scope.fileName) -> \(target.fileName) (reason=\(reason))")
            if isEditing { exitEditing() }   // 收起上一桌面的编辑浮层（含保存）
            store.setScope(target)
        }
        lastActiveSpaceID = sid

        if let existing = spaceWallpapers[sid] {
            wallpaper = existing
        } else {
            SpaceTrace.log("为桌面 \(sid) 创建壁纸窗口 (reason=\(reason))")
            let w = WallpaperWindowController(store: store, scope: target)
            spaceWallpapers[sid] = w
            wallpaper = w
        }
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
        syncToCurrentSpace(reason: "enterEditing")   // 编辑前锚定当前桌面，避免编辑到别的桌面画布
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
        purgeEmptyTextItems()   // 先清空卡，再统一收尾，避免残留空窗口下次进入又出现
        for (_, c) in controllers { c.close() }
        controllers.removeAll()
        wallpaper.setEditing(false)
        store.saveNow()
        refreshMenuState()
    }

    /// 退出编辑时，把板上“没有任何文字内容”的文字卡一并删除：
    /// 新建后没填写就退出 / 历史遗留的空占位卡，都不应留着等下次进入编辑时再冒出来。
    private func purgeEmptyTextItems() {
        for item in store.items where item.kind == .text {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty else { continue }
            controllers[item.id]?.close()
            controllers.removeValue(forKey: item.id)
            store.remove(id: item.id)
        }
    }

    @discardableResult
    private func spawnEditor(for item: BoardItem, focus: Bool) -> ItemEditorWindowController? {
        guard isEditing else { return nil }
        // 同一 item 已存在编辑窗时直接复用，避免生成重复/不受控的“孤儿”窗口
        if let existing = controllers[item.id] {
            existing.show(focus: focus)
            return existing
        }
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
        syncToCurrentSpace(reason: "addText")   // 内容写在“当前所在桌面”的画布
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
        syncToCurrentSpace(reason: "importImage")   // 图片落在“当前所在桌面”的画布
        guard let fileName = store.importImage(from: url) else {
            beep("无法读取该图片")
            return
        }
        addImageItem(fileName: fileName)
    }

    private func addImageItem(fileName: String) {
        syncToCurrentSpace(reason: "addImage")   // 图片落在“当前所在桌面”的画布
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
            syncToCurrentSpace(reason: "clearAll")   // 清的是“当前所在桌面”的画布
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

    // MARK: - 检查更新（仅手动触发，不常驻网络）

    @objc func checkForUpdates(_ sender: Any?) {
        updateItem?.isEnabled = false
        updateItem?.title = "正在检查更新…"

        UpdateService.fetchLatest { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateItem?.isEnabled = true
                self.updateItem?.title = "检查更新…"
                self.presentUpdateResult(result)
            }
        }
    }

    private func presentUpdateResult(_ result: Result<UpdateService.ReleaseInfo, Error>) {
        NSApp.activate(ignoringOtherApps: true)

        switch result {
        case .failure(let error):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "无法检查更新"
            alert.informativeText = (error as? UpdateService.CheckError)?.errorDescription
                ?? error.localizedDescription
            alert.addButton(withTitle: "好")
            alert.runModal()

        case .success(let info):
            if UpdateService.isNewer(info.version, than: UpdateService.currentVersion) {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "发现新版本 \(info.version)"
                var text = "当前版本 \(UpdateService.currentVersion)，最新版本 \(info.version)。\n"
                if let body = info.body, !body.isEmpty {
                    let preview = body.count > 900 ? String(body.prefix(900)) + "…" : body
                    text += "\n更新内容：\n\(preview)"
                }
                alert.informativeText = text
                alert.addButton(withTitle: "下载安装包")
                alert.addButton(withTitle: "稍后再说")
                if alert.runModal() == .alertFirstButtonReturn, let url = info.dmgDownloadURL {
                    NSWorkspace.shared.open(url)
                }
                return
            }

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "已是最新版本"
            alert.informativeText = "当前已安装 v\(UpdateService.currentVersion)，无需更新。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    private func beep(_ message: String? = nil) {
        if let message { logger.notice("\(message)") }
        NSSound.beep()
    }
}
