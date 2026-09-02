import AppKit

/// 无边框浮层窗口基类（NSPanel）。
/// - 自动带 .nonactivatingPanel：点击窗口里的控件**无需先激活 App**，第一击直接送达控件，
///   解决在别的 App（如编辑器）前台时点浮层控件需要"点两次"的问题。
/// - 壁纸层窗口：allowsBecomeKey=false + 点击穿透；编辑层窗口：可成为 key 获得 IME 输入。
final class BoardWindow: NSPanel {
    /// 是否允许成为 key window（编辑浮层用 true，壁纸层用 false）
    var allowsBecomeKey: Bool = true {
        didSet {
            if !allowsBecomeKey && isKeyWindow {
                resignKey()
            }
        }
    }

    override var canBecomeKey: Bool { allowsBecomeKey }
    override var canBecomeMain: Bool { allowsBecomeKey }

    /// 为 true 时 constrainFrameRect 原样返回（防止被约束进菜单栏之下产生顶部缝隙）
    var allowsUnconstrainedFrame: Bool = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        if allowsUnconstrainedFrame { return frameRect }
        return super.constrainFrameRect(frameRect, to: screen)
    }

    convenience init(contentRect: NSRect, styleMask style: NSWindow.StyleMask) {
        self.init(contentRect: contentRect,
                  styleMask: style.union(.nonactivatingPanel),
                  backing: .buffered,
                  defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
    }
}

/// 简单的视图工具类
extension NSView {
    /// 生成圆角图层遮罩
    func applyRoundedCornerMask(radius: CGFloat) {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = radius
    }
}
