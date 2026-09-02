import AppKit

// 亚克力记录板 —— macOS 桌面壁纸层透明记录板
// 一份数据 + 双窗口表现：壁纸层静态渲染(点击穿透/垫桌面图标之下)，浮层窗口负责编辑输入。

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory) // 仅菜单栏，不出现在 Dock / Cmd+Tab
app.run()
