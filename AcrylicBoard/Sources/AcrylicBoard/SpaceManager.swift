import Foundation
import CoreGraphics

/// 只读地获取“当前活跃桌面 Space”的标识。
///
/// macOS 没有公开 API 暴露活跃 Space，社区通用做法是调用 CoreGraphics 私有符号
/// `CGSMainConnectionID` / `CGSCopyActiveSpace`。这里用 dlsym 运行时解析：
/// - 解析成功：返回当前活跃 Space 的 CGSSpaceID（会话内稳定，不同桌面值不同）；
/// - 解析失败或环境异常：回退为固定值 0（退化为“单画布”表现，不会崩溃）。
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

    /// 当前活跃 Space 的 ID；获取失败返回 0
    static func activeSpaceID() -> SpaceID {
        typealias Fn = @convention(c) (UInt32) -> SpaceID
        guard let handle, let sym = dlsym(handle, "CGSCopyActiveSpace") else { return 0 }
        return unsafeBitCast(sym, to: Fn.self)(connectionID())
    }
}
