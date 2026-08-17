# EasyMacTool

一款 macOS 原生风格的菜单栏效率工具，集成**窗口切换器**（类 Windows Alt+Tab）、**剪切板历史**（类 Paste）、**系统监控**（类 iStat Menus）、**应用卸载器**与**窗口布局**（类 Loop）五大核心功能。纯 Swift + SwiftUI + AppKit 实现，零第三方依赖。

![platform](https://img.shields.io/badge/platform-macOS%2014.0%2B-blue)
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

- **焦点默认在卡片**：参考 Paste，呼出后 firstResponder 直接是卡片容器（非搜索框），无需点击即可用 `← / →` 切换、`Enter` 复制
- **搜索需主动激活**：点击搜索框或按 `⌘F` 才进入搜索态，避免输入字符意外触发筛选
- **Esc 智能退出**：搜索态按 Esc 清空查询回卡片，卡片态按 Esc 关闭面板
- **富文本保留**：从 VSCode/Xcode 复制的代码会保留语法高亮颜色（RTF 渲染）
- **分组管理**：可创建多个可命名分组（各配标识色），条目归属分组分类管理；删除分组时连带清理组内条目与图片文件
- **类型筛选**：顶部彩色圆点图标分类，一键筛选某类内容
- **搜索**：按标题与内容模糊搜索
- **预览**：
  - 鼠标悬停 1 秒自动弹起放大预览（tooltip 式，无全屏遮罩）
  - 右键菜单「预览」
  - 空格键预览（与 Quick Look 一致）
- **自动粘贴**：选中卡片后自动粘贴回前台应用（可关闭）；可开启**纯文本粘贴**剥掉富文本格式
- **忽略应用**：按 bundleID 忽略指定来源应用（密码管理器等），通过系统文件面板选择
- **图片文件缩略图**：单图片文件异步加载缩略图展示
- **链接预览**：显示 host / path / 完整 URL，可直接在浏览器打开；预览网络策略可配置（关闭 / 手动 / 自动）
- **历史容量**：默认保留 100 条，可配置；支持跨启动持久化（可关闭）

### 3. 系统监控（类 iStat Menus）

实时采样系统指标，菜单栏常驻显示 + 下拉面板详情。默认关闭，开启前零开销。

- **9 类指标**：

  | 指标 | 内容 |
  | ---- | ---- |
  | CPU | 使用率 + 温度（按 Apple Silicon 代际自动选择传感器） |
  | GPU | 使用率 + 温度（IOKit `AGXAccelerator` / `IOAccelerator`） |
  | 内存 | 已用/总量 + 内存压力色点（正常/警告/危急） |
  | 网络 | 实时上/下行速率（排除虚拟接口） |
  | 磁盘 | 占用率 + 实时读写速率 |
  | 功耗 | 整机功率、电池电量/循环次数/健康度 |
  | 风扇 | 转速 RPM（多风扇分隔显示，无风扇硬件自动隐藏） |

- **菜单栏指标块**：每项指标可独立开关（紧凑双行显示，网络为 ↓下行/↑上行），支持拖拽排序，温度单位 °C/°F 可切换
- **下拉面板**：
  - CPU 温度 / CPU 占用 / 内存占用 三张放大卡片
  - **活动应用内存**列表：聚合主进程 + Helper 进程的物理内存占用，仅显示有可见窗口的应用（微信家族自动合并统计），支持一键请求应用退出
  - GPU / 网络 / 磁盘 / 功耗 / 风扇附加参数行（按需显示）
- **采样**：间隔 1 / 2 / 5 秒可调（默认 2 秒），后台低优先级队列执行，不占用主线程

### 4. 应用卸载器（类 AppCleaner）

完整卸载应用及其残留文件，删除走废纸篓、可随时恢复。

- **应用扫描**：列出 `/Applications`、`~/Applications` 下的用户安装应用（图标/名称/bundleID/占用大小），支持搜索，也可直接拖拽 `.app` 进入
- **残留查找**：按 bundleID 扫描 9 类残留——应用本体、Application Support、缓存（Caches/HTTPStorages/WebKit/Cookies）、偏好设置、容器与脚本（Containers/Group Containers）、保存状态、日志、PrivilegedHelperTools、LaunchAgents/LaunchDaemons，并发现 `.appex/.xpc/.plugin` 等嵌套子 bundle 的残留
- **逐项勾选**：按类别分组展示全部残留，实时统计已选体积
- **安全机制**：
  - bundleID 反向 DNS 格式校验，拒绝 `com.apple.*` 等受保护前缀
  - 系统应用（`/System/`、`/Library/Apple/`）排除
  - 符号链接穿越防护 + 删除路径白名单 + 文件身份指纹（device/inode）防篡改
  - 删除前自动请求运行中实例退出
- **删除策略**：优先移至废纸篓；权限不足时回退 Finder 授权删除；失败项单独列出并附原因
- **完成报告**：显示释放空间与失败清单，可继续卸载下一个应用

### 5. 窗口布局（类 Loop）

通过径向菜单或快捷键将前台窗口快速吸附到屏幕区域。默认关闭，开启前零监听。

- **9 个布局动作**：左/右/上/下半屏、全屏、左上/右上/左下/右下四角
- **径向菜单**：
  - 默认**按住鼠标中键**呼出，也可录制键盘修饰键组合触发（区分左右 ⌘/⌥/⌃/⇧，如「右⌘」）
  - 菜单出现在鼠标位置：向扇区方向移动即选中对应半屏/四角，移向中心为全屏，松开应用
  - 纯点击不移动鼠标不触发布局，避免误操作
- **布局快捷键**：左/右/上/下半屏 + 全屏 5 项可独立录制快捷键（默认未绑定，录制后立即生效，自动与系统保留组合及其他功能快捷键做冲突校验）
- **多屏支持**：径向菜单在鼠标所在屏幕生效；坐标系以主显示器为基准，副屏（含负坐标排列）布局不串屏

## 默认快捷键

| 功能             | 快捷键        |
| ---------------- | ------------- |
| 窗口切换（正向） | `⌘ + Tab`     |
| 窗口切换（反向） | `⌘ + ⇧ + Tab` |
| 剪切板历史       | `⌘ + ⇧ + V`   |
| 设置             | `⌘ + ,`       |
| 退出             | `⌘ + Q`       |
| 径向菜单（鼠标） | 按住鼠标中键  |
| 径向菜单（键盘） | 未设置（需录制） |
| 布局快捷键       | 未设置（需录制） |

所有快捷键均可在设置中自定义。剪切板面板内：

| 操作               | 按键                  |
| ------------------ | --------------------- |
| 切换选中卡片       | `← / →` / `↑ / ↓`     |
| 复制并粘贴选中卡片 | `Enter`               |
| 预览/关闭预览      | `Space`               |
| 切换到搜索框       | `⌘F` 或 点击搜索框    |
| 退出搜索回卡片     | `Esc`（搜索态）       |
| 关闭面板           | `Esc`（卡片态）/ 点击外部 |

## 系统要求

- macOS 14.0（Sonoma）或更高
- Apple Silicon / Intel 通用

## 系统权限

应用需以下两项系统权限方能正常工作。权限请求**按顺序**触发，避免系统弹窗冲突：

1. **辅助功能（Accessibility）**：`CGEventTap` 拦截全局快捷键与 Accessibility API 操控窗口（切换/布局）必需
2. **屏幕录制（Screen Recording）**：`SCShareableContent` 抓取窗口缩略图必需（macOS 15+ 静默失败，首次调用即便抛错也会注册 app 到 TCC 列表）

> 注意：App Sandbox 已禁用，否则无法使用 `CGEventTap` 与 Accessibility API。无需「输入监控」权限——辅助功能授权已完整覆盖。

## 安装与使用

### 下载预编译版本

1. 从 [Releases](https://github.com/wanderingdever/easy-mac-tool/releases) 下载 `EasyMacTool.zip`
2. 解压后将 `EasyMacTool.app` 拖入 `/Applications/` 目录
3. 首次启动因未签名，需在「系统设置 → 隐私与安全性」中允许打开
4. 启动后按提示依次授权：辅助功能 → 屏幕录制
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

### 打包发布

```sh
./script/release.sh          # 构建 + 打包 dist/EasyMacTool.zip + SHA-256
./script/release.sh --verify # 额外启动验证
```

## 技术栈

| 领域         | 技术                                                                 |
| ------------ | -------------------------------------------------------------------- |
| UI           | SwiftUI（视图层）+ AppKit（窗口/事件/面板）                          |
| 全局快捷键   | `CGEventTap` + `.cgSessionEventTap`（捕获虚拟键盘，含健康自愈重建）  |
| 窗口枚举     | Accessibility API（`AXUIElement` / `AXObserver`）                    |
| 窗口捕获     | `ScreenCaptureKit`（`SCShareableContent` / `SCStream`）              |
| 系统监控     | SMC（`AppleSMC` user client）、IOKit（GPU/磁盘）、`host_statistics`  |
| 进程内存     | `proc_listallpids` / `proc_pid_rusage`（按应用聚合物理内存）         |
| 状态持久化   | `UserDefaults`（JSON 序列化，防抖写入）                              |
| 模块联动     | Combine 订阅设置变更，各功能即时启停                                 |
| 应用跟踪     | `NSWorkspace.didActivateApplicationNotification`                     |
| 应用图标     | Run Script 阶段 `sips + iconutil` 生成 `AppIcon.icns`                |

## 项目结构

```
EasyMacTool/
├── EasyMacTool/
│   ├── AppKit/
│   │   ├── OverlayPanel.swift              # 切换器透明面板
│   │   ├── OverlayPanelController.swift    # 面板位置/选择/激活
│   │   └── ClipboardPanelController.swift  # 剪切板浮层窗口
│   ├── Models/
│   │   ├── AppSettings.swift               # 全局设置（持久化 + 冲突校验）
│   │   ├── ShortcutConfig.swift            # 单个快捷键配置
│   │   ├── WindowItem.swift                # 窗口元数据
│   │   ├── WindowLayoutAction.swift        # 9 个布局动作
│   │   ├── RadialKeyTrigger.swift          # 径向菜单键盘触发（左右修饰键）
│   │   ├── ClipboardItem.swift             # 剪切板条目（RTF/图片/链接）
│   │   └── ClipboardGroup.swift            # 剪切板分组
│   ├── Services/
│   │   ├── HotkeyManager.swift             # CGEventTap 快捷键分发
│   │   ├── WindowEnumerator.swift          # AX 枚举窗口 + MRU 排序
│   │   ├── ScreenCaptureManager.swift      # 并行窗口缩略图捕获
│   │   ├── WindowActivator.swift           # AX 激活目标窗口
│   │   ├── ClipboardManager.swift          # 剪切板监听 + 历史存储
│   │   ├── AppUsageTracker.swift           # 应用激活顺序追踪
│   │   ├── SystemMonitor/                  # 系统监控（SMC/IOKit/采样调度）
│   │   ├── Uninstaller/                    # 卸载器（扫描/残留/安全删除）
│   │   └── WindowLayout/                   # 窗口布局（AX 布局 + 径向控制器）
│   ├── Views/
│   │   ├── SwitcherOverlayView.swift       # 切换器主视图
│   │   ├── ClipboardOverlayView.swift      # 剪切板主视图
│   │   ├── MenuBarView.swift               # 菜单栏下拉（监控面板/退出）
│   │   ├── SystemMonitorMenuBarController.swift # 菜单栏指标块
│   │   ├── SystemMonitorSettingsView.swift # 系统监控设置页
│   │   ├── UninstallerSettingsView.swift   # 卸载器设置页
│   │   ├── WindowLayout/RadialOverlayView.swift  # 径向菜单拨盘
│   │   └── Settings/                       # 设置窗口各导航页
│   ├── EasyMacToolApp.swift                # @main 入口 + AppCoordinator
│   ├── Info.plist                           # 自定义（持久化 CFBundleIcon）
│   └── EasyMacTool.entitlements
├── EasyMacToolTests/                        # 单元测试（策略/几何/回归）
├── script/
│   ├── build_and_run.sh                    # 构建并运行
│   ├── release.sh                          # 打包 zip + SHA-256
│   └── generate_app_icon.swift             # 生成 AppIcon.icns
└── EasyMacTool.xcodeproj
```

## 设计理念

- **Windows Alt+Tab 交互逻辑**：hover 仅预瞄、点击才提交、释放即激活，避免误操作
- **macOS 原生视觉**：毛玻璃材质、圆角、SF Symbols、深浅色自适应
- **小而美**：零第三方依赖，最终产物约 2 MB
- **零开销默认**：系统监控与窗口布局默认关闭，关闭时不监听、不采样
- **安全第一**：卸载仅移废纸篓可恢复；多重路径/身份校验防误删

## 已知限制

- macOS 15+ 屏幕录制权限首次请求可能静默失败，需在「系统设置 → 隐私 → 屏幕录制」手动启用
- 最小化/隐藏窗口无法实时捕获预览，统一显示应用图标占位
- CPU/GPU 温度依赖 SMC 传感器键，部分机型读数缺失时显示 `--`
- 暂不支持 iCloud 同步与跨设备剪切板

## 许可证

MIT License © wanderingdever
