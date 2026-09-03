import Foundation
import CoreGraphics

/// 只读地获取“当前活跃桌面 Space”的标识。
///
/// macOS 没有公开 API 暴露活跃 Space。实测（macOS 15/26）中 `CGSCopyActiveSpace`
/// 对无前台窗口的常驻菜单栏类应用会稳定返回 0，而 `CGSGetActiveSpace`（返回主显示器
/// 当前活跃 Space）在同类应用上工作正常，社区工具（SuperDimmer、SpacesGrid 等）均使用后者。
/// 这里以 dlsym 运行时解析，按 `CGSGetActiveSpace` → `CGSCopyActiveSpace` 顺序探测：
/// - 成功：返回当前活跃 Space 的 CGSSpaceID（会话内稳定，不同桌面值不同）；
/// - 全部失败：返回 0（调用方据此退化为“单画布”表现，不会崩溃）。
final class SpaceManager {
    typealias SpaceID = UInt64

    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    }()

    private static func connectionID() -> UInt32 {
        typealias Fn = @convention(c) () -> UInt32
        guard let handle, let sym = dlsym(handle, "CGSMainConnectionID") else { return 0 }
        return unsafeBitCast(sym, to: Fn.self)()
    }

    /// 用指定符号名解析“当前活跃 Space”。
    private static func activeSpace(_ symbol: String) -> SpaceID {
        typealias Fn = @convention(c) (UInt32) -> SpaceID
        guard let handle, let sym = dlsym(handle, symbol) else { return 0 }
        let cid = connectionID()
        guard cid != 0 else { return 0 }
        return unsafeBitCast(sym, to: Fn.self)(cid)
    }

    /// 当前活跃 Space 的 ID（主显示器）；全部探测失败返回 0。
    static func activeSpaceID() -> SpaceID {
        let primary = activeSpace("CGSGetActiveSpace")
        if primary != 0 { return primary }
        return activeSpace("CGSCopyActiveSpace")
    }

    /// 分别返回两个 API 的采样值（诊断用，仅在异常排查时调用）。
    static func diagnosticSample() -> (getActive: SpaceID, copyActive: SpaceID) {
        (activeSpace("CGSGetActiveSpace"), activeSpace("CGSCopyActiveSpace"))
    }

    /// 当前系统“现存普通桌面”的 Space ID 集合（跨所有显示器）。
    ///
    /// 用只读私有符号 `CGSCopyManagedDisplaySpaces`（Hammerspoon 等多年稳定使用的读路径）
    /// 枚举每块显示器下 `Spaces` 数组，取 `id64`，且只收普通桌面（type == 0）。
    /// 用于在删除桌面时判断“我们缓存的某个桌面已不存在”，从而让该桌面的画布内容随之清除。
    /// 任何一步失败返回 nil：调用方应跳过本轮清理，绝不因解析问题误删仍在的桌面。
    static func existingUserSpaceIDs() -> Set<SpaceID>? {
        typealias Fn = @convention(c) (UInt32) -> Unmanaged<CFArray>?
        guard let handle, let sym = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return nil }
        let cid = connectionID()
        guard cid != 0 else { return nil }
        guard let raw = unsafeBitCast(sym, to: Fn.self)(cid) else { return nil }
        let array = raw.takeRetainedValue()
        guard let displays = array as? [[String: Any]] else { return nil }

        var ids = Set<SpaceID>()
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for sp in spaces {
                // type：0 = 普通桌面（user space）；4 = 全屏 Space。取不到 type 时保守保留。
                if let type = sp["type"] as? Int, type != 0 { continue }
                if let id64 = (sp["id64"] as? NSNumber)?.uint64Value {
                    ids.insert(id64)
                } else if let id64 = sp["id64"] as? SpaceID {
                    ids.insert(id64)
                }
            }
        }
        return ids
    }
}

/// 极轻量的 Space 追踪落盘（诊断用）：
/// 把“采样到的新活跃 Space / 作用域切换”追加到数据目录 space-trace.log，
/// 便于排查“各桌面独立画布”时内容跑错桌面。日志很小，仅记录事件不记录内容。
enum SpaceTrace {
    private static var lock = NSLock()

    private static var logURL: URL? {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AcrylicBoard", isDirectory: true)
        return base?.appendingPathComponent("space-trace.log")
    }

    static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let url = logURL else { return }
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url, options: .atomic)
        }
    }
}
