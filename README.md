# EasyMacTool

一款 macOS 原生风格的菜单栏效率工具，集成**窗口切换器**（类 Windows Alt+Tab）与**剪切板历史**（类 Paste）两大核心功能。纯 Swift + SwiftUI + AppKit 实现，零第三方依赖。

![platform](https://img.shields.io/badge/platform-macOS%2026.5%2B-blue)
![language](https://img.shields.io/badge/language-Swift%205-orange)
![license](https://img.shields.io/badge/license-MIT-green)

## 功能特性

### 1. 窗口切换器（类 Windows Alt+Tab）

呼出后以毛玻璃面板平铺展示当前所有可用窗口的**实时缩略图**，支持鼠标点击与键盘导航。

- **多快捷键配置**：每个快捷键可独立设置窗口过滤器（最小化/隐藏/空应用）、缩略图尺寸（小/中/大）、释放行为
- **MRU 排序**：按最近激活顺序排列，A→B 切换后下次呼出顺序为 [B, A, C, D]，与 Windows Alt+Tab 一致
- **并行捕获**：使用 `withTaskGroup` 并行抓取所有窗口缩略图，配合 `WindowPreviewCache` 缓存预填充，无左→右波浪加载动画
- **悬停预瞄 + 点击提交**：鼠标 hover 仅显示浅色边框预瞄，点击才真正选中并激活（与 Windows 一致）
- **释放行为**：
  - `释放后聚焦`：松开修饰键即激活当前选中窗口（默认）
  - `按住（Enter 确认）`：保持面板，按 Enter 才激活
- **多屏支持**：面板出现位置可选「活跃屏幕 / 鼠标所在屏 / 主屏幕」
- **应用占位**：最小化/隐藏/无窗口的应用只显示应用图标，不尝试捕获隐藏窗口
- **Finder 桌面过滤**：始终排除 Finder 桌面窗口

### 2. 剪切板历史（类 Paste）

底部贴边浮层展示最近复制内容，支持文本、图片、链接、文件、颜色五类。

- **焦点默认在卡片**：呼出后无需点击，直接用 `← / →` 切换卡片，`Enter` 复制选中项
- **富文本保留**：从 VSCode/Xcode 复制的代码会保留语法高亮颜色（RTF 渲染）
- **类型筛选**：顶部彩色圆点图标分类，一键筛选某类内容
- **搜索**：按标题与内容模糊搜索
- **预览**：
  - 鼠标悬停 1 秒自动弹起放大预览（tooltip 式，无全屏遮罩）
  - 右键菜单「预览」
  - 空格键预览（与 Quick Look 一致）
- **自动粘贴**：选中卡片后自动粘贴回前台应用（可关闭）
- **图片文件缩略图**：单图片文件异步加载缩略图展示
- **链接预览**：显示 host / path / 完整 URL，可直接在浏览器打开
- **历史容量**：默认保留 100 条，可配置

### 3. 菜单栏常驻

- `LSUIElement=YES`，无 Dock 图标
- 菜单栏显示 SF Pro Rounded 字体绘制的「E」图标（template 模式自适应深浅色）
- 设置窗口浮动置顶（`NSPanel` + `.floating`）

## 默认快捷键

| 功能           | 快捷键            |
| -------------- | ----------------- |
| 窗口切换（正向） | `⌘ + Tab`         |
| 窗口切换（反向） | `⌘ + ⇧ + Tab`     |
| 剪切板历史      | `⌘ + ⇧ + V`       |
| 设置           | `⌘ + ,`           |
| 退出           | `⌘ + Q`           |

所有快捷键均可在设置中自定义。剪切板面板内：

| 操作               | 按键       |
| ------------------ | ---------- |
| 切换选中卡片       | `← / →`    |
| 复制并粘贴选中卡片 | `Enter`    |
| 预览/关闭预览      | `Space`    |
| 关闭面板           | `Esc` / 点击外部 |

## 系统要求

- macOS 26.5（Tahoe）或更高
- Apple Silicon / Intel 通用

## 系统权限

应用需以下三项系统权限方能正常工作。权限请求**按顺序**触发，避免系统弹窗冲突：

1. **辅助功能（Accessibility）**：`CGEventTap` 拦截全局快捷键必需
2. **屏幕录制（Screen Recording）**：`SCShareableContent` 抓取窗口缩略图必需（macOS 15+ 静默失败，首次调用即便抛错也会注册 app 到 TCC 列表）
3. **输入监控（Input Monitoring）**：`CGEventTap` 创建后系统会自动提示

> 注意：App Sandbox 已禁用，否则无法使用 `CGEventTap` 与 Accessibility API。

## 安装与使用

### 下载预编译版本

1. 从 [Releases](https://github.com/wanderingdever/easy-mac-tool/releases) 下载 `EasyMacTool.zip`
2. 解压后将 `EasyMacTool.app` 拖入 `/Applications/` 目录
3. 首次启动因未签名，需在「系统设置 → 隐私与安全性」中允许打开
4. 启动后按提示依次授权：辅助功能 → 屏幕录制 → 输入监控
5. 菜单栏出现「E」图标即表示运行中

### 从源码构建

```sh
git clone https://github.com/wanderingdever/easy-mac-tool.git
cd easy-mac-tool
./script/build_and_run.sh
```

或手动构建：

```sh
xcodebuild \
    -project EasyMacTool.xcodeproj \
    -scheme EasyMacTool \
    -configuration Release \
    -destination 'platform=macOS' \
    build
```

构建产物位于 `~/Library/Developer/Xcode/DerivedData/EasyMacTool-*/Build/Products/Release/EasyMacTool.app`。

## 技术栈

| 领域         | 技术                                                  |
| ------------ | ----------------------------------------------------- |
| UI           | SwiftUI（视图层）+ AppKit（窗口/事件/面板）          |
| 全局快捷键   | `CGEventTap` + `.cgSessionEventTap`（捕获虚拟键盘）  |
| 窗口枚举     | Accessibility API（`AXUIElement` / `AXObserver`）     |
| 窗口捕获     | `ScreenCaptureKit`（`SCShareableContent` / `SCStream`）|
| 状态持久化   | `UserDefaults`（JSON 序列化）                        |
| 应用跟踪     | `NSWorkspace.didActivateApplicationNotification`      |
| 应用图标     | Run Script 阶段 `sips + iconutil` 生成 `AppIcon.icns`  |

## 项目结构

```
EasyMacTool/
├── EasyMacTool/
│   ├── AppKit/
│   │   ├── OverlayPanel.swift              # 切换器透明面板
│   │   ├── OverlayPanelController.swift    # 面板位置/选择/激活
│   │   └── ClipboardPanelController.swift   # 剪切板浮层窗口
│   ├── Models/
│   │   ├── AppSettings.swift               # 全局设置（持久化）
│   │   ├── ShortcutConfig.swift            # 单个快捷键配置
│   │   ├── WindowItem.swift                # 窗口元数据
│   │   └── ClipboardItem.swift             # 剪切板条目（含 RTF/图片/链接）
│   ├── Services/
│   │   ├── HotkeyManager.swift             # CGEventTap 快捷键分发
│   │   ├── WindowEnumerator.swift          # AX 枚举窗口 + MRU 排序
│   │   ├── ScreenCaptureManager.swift      # SCScreenshotManager 并行捕获
│   │   ├── WindowActivator.swift           # AX 激活目标窗口
│   │   ├── ClipboardManager.swift          # 剪切板监听 + 历史存储
│   │   ├── AppUsageTracker.swift           # 应用激活顺序追踪
│   │   ├── AccessibilityChecker.swift      # 权限检查
│   │   └── RelativeTimeFormatter.swift     # 相对时间格式化
│   ├── Views/
│   │   ├── SwitcherOverlayView.swift       # 切换器主视图
│   │   ├── WindowThumbnailCell.swift       # 单窗口缩略图
│   │   ├── ClipboardOverlayView.swift      # 剪切板主视图
│   │   ├── RTFTextView.swift                # 富文本预览 NSTextView
│   │   ├── HorizontalWheelScrollView.swift # 纵向滚轮转横向滚动
│   │   ├── FlowLayout.swift                # 自动换行布局
│   │   ├── BlackEMenuBarIcon.swift         # 菜单栏 E 图标
│   │   ├── MenuBarView.swift               # 菜单栏下拉菜单
│   │   └── Settings/                        # 设置窗口各 Tab
│   ├── EasyMacToolApp.swift                # @main 入口
│   ├── Info.plist                           # 自定义（持久化 CFBundleIcon）
│   └── EasyMacTool.entitlements
├── script/
│   ├── build_and_run.sh                    # 构建并运行
│   └── generate_app_icon.swift             # 生成 AppIcon.icns
└── EasyMacTool.xcodeproj
```

## 设计理念

- **Windows Alt+Tab 交互逻辑**：hover 仅预瞄、点击才提交、释放即激活，避免误操作
- **macOS 原生视觉**：毛玻璃材质、圆角、SF Symbols、深浅色自适应
- **小而美**：零第三方依赖，最终产物约 1 MB
- **零延迟**：所有窗口缩略图并行捕获，缓存预填充，无加载动画

## 已知限制

- macOS 15+ 屏幕录制权限首次请求可能静默失败，需在「系统设置 → 隐私 → 屏幕录制」手动启用
- 最小化/隐藏窗口无法实时捕获预览，统一显示应用图标占位
- 暂不支持 iCloud 同步与跨设备剪切板

## 许可证

MIT License © wanderingdever
