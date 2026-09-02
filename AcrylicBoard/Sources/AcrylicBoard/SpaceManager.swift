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
