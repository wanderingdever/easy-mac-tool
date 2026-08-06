# EasyMacTool UI 现代化改版方案（Aurora v2）

日期：2026-08-06

## 设计目标

统一四个核心界面（设置、剪切板、窗口切换、菜单栏弹窗）的视觉语言，
采用「Aurora 极光」设计体系：品牌渐变 + 毛玻璃 + 分层阴影 + 统一控件形态，
全面适配明暗两种系统外观。

## 设计体系

### 品牌渐变
- 三段渐变：System Blue → System Indigo → System Purple（Apple 系统色系，和谐不刺眼）
- 明暗自适应：light `#007AFF/#5856D6/#AF52DE`，dark `#0A84FF/#5E5CE6/#BF5AF2`
- 克制使用：仅用于选中导航、主按钮、选中描边、品牌图标等关键强调位

### 玻璃质感
- 面板：`ultraThinMaterial` 底 + 极光微光叠加层（glassSheen）+ 白色发丝描边 + 顶部反光高线
- 三级阴影：卡片浮起（cardShadow）/ 悬浮（floatShadow）/ 品牌外发光（brandGlow），明暗自适应

### 统一表面（分组设置）
- 页面背景 `pageBackground`（light 冷调浅灰 / dark 深灰）
- 卡片 `cardSurface`（light 纯白 / dark #242429）+ 发丝描边 + 浮起阴影
- 控件 tint 统一为品牌靛蓝（Toggle / Slider / 链接按钮）

### 共享组件（DesignTokens.swift）
- `AuroraIconChip`：渐变图标 chip（subdued 淡底 / solid 实底两态）
- `AuroraKbd`：快捷键胶囊
- `AuroraPrimaryButtonStyle`：渐变主按钮（按下缩放反馈）
- `auroraSettingsCard()` / `auroraGradientStroke()` 修饰符

## 各界面改动

### 设置窗口
- 侧栏：品牌头部（渐变图标 + 名称 + 版本）、选中项渐变实底 + 白字 + 外发光、hover 极淡填充
- 内容区：Divider 分隔改为分组卡片布局；section header 统一为渐变 chip + 15pt semibold
- 窗口切换页：多屏幕/快捷键两张浮起卡片；快捷键列表选中项渐变实底；详情组卡片统一
- 剪切板页：呼出快捷键/行为/历史三卡片；Toggle/Slider 品牌 tint
- 权限页：权限卡片带状态胶囊（已授权绿 / 未授权红）；「请求权限」渐变主按钮
- 关于页：Aurora 渐变图标 + 版本胶囊 + 功能 chip 行
- KeyRecorder：录制中渐变描边 + 外发光

### 剪切板面板
- 面板：四边留白全浮动玻璃卡片（圆角 20），极光微光 + 顶部反光高线
- 头部：渐变 chip 计数、胶囊玻璃搜索框（聚焦渐变环）、圆形清空按钮（hover 红）
- 卡片：圆角 14 cardSurface；hover/选中 = 品牌渐变描边 2.5pt + 外发光 + 上浮 2pt（0.16s 过渡）
- 文本预览底部 15% 渐隐；footer 改为「类型圆点 + 类型名 | 统计」双段式
- 筛选菜单：玻璃浮层 + 渐变选中态；预览卡片渐变描边 + 渐变复制主按钮

### 窗口切换
- 面板：玻璃底 + 极光微光 + 顶部反光高线；新增页眉（渐变 chip + 计数胶囊）与页脚（kbd 提示条）
- 缩略图：选中 = 渐变描边 2pt + 渐变淡填充 + 品牌外发光；hover = 渐变 55% 浅描边；当前活跃窗口 = 渐变描边标记
- `OverlayPanelController.positionPanel` 同步加入 header/footer 固定高度（36/30pt）与 320pt 最小宽度

### 菜单栏弹窗
- 品牌头部（渐变实底图标 + 名称 + 版本）+ 渐变发丝分隔线
- 菜单项三段式：渐变 chip 图标 + 标题 + kbd 胶囊；hover 整行渐变实底反白 + 外发光，按下 0.98 缩放

## 修改文件
- `Views/DesignTokens.swift`（Aurora 体系 + 共享组件）
- `Views/MenuBarView.swift`（重写）
- `Views/ClipboardOverlayView.swift`（视觉重构，交互/性能逻辑保留）
- `Views/SwitcherOverlayView.swift`（重写，新增页眉页脚）
- `Views/WindowThumbnailCell.swift`（选中态渐变描边 + 发光）
- `AppKit/OverlayPanelController.swift`（面板尺寸计算同步）
- `Views/Settings/SettingsRootView.swift`、`WindowSwitcherSettingsView.swift`、
  `ClipboardSettingsView.swift`、`PermissionsSettingsView.swift`、`AboutView.swift`、`KeyRecorderView.swift`
