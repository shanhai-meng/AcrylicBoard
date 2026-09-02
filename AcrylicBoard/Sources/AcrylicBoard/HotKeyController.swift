import AppKit
import Carbon.HIToolbox

/// 全局快捷键（Carbon RegisterEventHotKey，无需辅助功能权限）
final class HotKeyController {
    static let shared = HotKeyController()

    // 语义 id → handler
    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerInstalled = false
    private let signature: OSType = 0x4143_424F // "ACBO"

    private func ensureEventHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                       eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return noErr }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hkID)
            guard status == noErr else { return noErr }
            let center = Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue()
            center.handlers[hkID.id]?()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// keyCode: kVK_ANSI_*；modifiers: cmdKey/shiftKey/optionKey/controlKey 组合
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        ensureEventHandler()

        var hotKeyRef: EventHotKeyRef?
        let hotID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, let hotKeyRef else { return }
        hotKeyRefs.append(hotKeyRef)
        handlers[id] = {
            // 事件在主运行循环派发，为稳妥再切回主线程
            if Thread.isMainThread {
                action()
            } else {
                DispatchQueue.main.async { action() }
            }
        }
    }

    func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        handlers.removeAll()
    }

    func unregister(id: UInt32) {
        handlers.removeValue(forKey: id)
    }
}

/// 语义快捷键常量
enum HotKeys {
    static let toggleEdit: UInt32 = 1
    static let newText: UInt32 = 2
    static let pasteImage: UInt32 = 3

    static let kVK_ANSI_B: UInt32 = 11
    static let kVK_ANSI_N: UInt32 = 45
    static let kVK_ANSI_V: UInt32 = 9
}
