# OMPlayer 界面重构 v1.1.001 - 实施计划

实施顺序即依赖顺序。UI 各部件与 player_screen 路由强耦合，采用串行实施（每片自带 GetDiagnostics 验证），T2/T3 等纯数据/渲染片若上下文允许可并行委派。

## Task 1: 数据模型与持久化扩展（画面比例模式、隐藏分类、回看字段）
- **Status**: `completed`
- **Completion Evidence (2026-10-06)**: PlayerSettings 加 AspectRatioMode 枚举（中文 label）与 hiddenCategoryIds，copyWith/默认值/load/save 齐全（_kAspectRatioMode/_kHiddenCategoryIds）；controller 加 setAspectRatioMode、setCategoryHidden、isCategoryHidden、visibleCategories；Channel 加 catchupType/catchupSource/catchupDays + buildCatchupUrl（{start}{end}{utc}{utcend}{duration}/$start/$end，append/相对模板拼直播地址，无模板 null）；EpgProgram 加 catchupUrl；ReservationManager.isTriggered（前缀+±60s 容差）与 controller.isReservationTriggered（频道解析与 toggle 一致）；收藏独立持久化 omplayer_favorite_channel_ids + favoriteChannelIds/isFavoriteChannel/toggleFavoriteChannel/buildFavoriteChannels。5 个文件 GetDiagnostics 零错误。
- **Priority**: high
- **Depends On**: None
- **Description**:
  - `PlayerSettings` 新增：`aspectRatioMode`（枚举：auto/ratio16x9/ratio4x3/fill/original/crop，含中文 label）、`hiddenCategoryIds`（`List<String>`，默认空）；copyWith/默认值齐全。
  - `player_controller.dart` 设置读写（SharedPreferences）：新两个字段的 load/save；新增 `setAspectRatioMode`、`setCategoryHidden(id, hidden)` 并 notifyListeners；暴露 `bool isCategoryHidden(id)` 与「可见分类列表」过滤辅助。
  - `Channel` 新增 catchup 字段：`catchupType`（default/dash/flussonic/append 等，可空）、`catchupSource`（模板，可空）、`catchupDays`（int，可空）；fromM3u 解析与 JSON 序列化兼容。
  - `EpgProgram` 新增可空 `catchupUrl`（XMLTV `<catchup-source>`）；Channel 上新增回看 URL 构造方法（或独立 helper）：支持 `{start}` `{end}` `{utc}` `{duration}` 占位符（Unix 秒），无模板时返回 null。
  - ReservationManager 暴露 `bool isTriggered(String channelId, DateTime startTime)`（按 `res_${channelId}_${startTimeMillis}` 规则比对已持久化的 `_triggeredIds`）；PlayerController 包装为 `isReservationTriggered(EpgProgram)`，频道 ID 解析与 toggle/isReserved 完全一致（精确匹配→当前频道兜底）。
  - 频道收藏：独立持久化 `omplayer_favorite_channel_ids`（`List<String>`，不改动 Channel/分类结构，不影响预约）；PlayerController 新增 `favoriteChannelIds`、`bool isFavoriteChannel(id)`、`toggleFavoriteChannel(id)`（notifyListeners）、`List<Channel> buildFavoriteChannels()`（按各频道在源分类中的原始顺序聚合）。
- **Acceptance Criteria Addressed**: AC-5, AC-6, AC-3, AC-2c
- **Test Requirements**:
  - `rule` TR-1.1: 新字段有默认值且 SharedPreferences 读写往返一致（代码走查 load/save 键与 copyWith 调用）
  - `rule` TR-1.2: 给定 catchup-source 模板与节目起止时间，构造出的 URL 占位符全部替换、时间为 Unix 秒；无模板返回 null（走查 helper 单测性代码路径）
  - `rule` TR-1.3: GetDiagnostics 对所改 4 个文件零错误
- **Notes**: bufferSeconds 字段保留但本期不接 UI。

## Task 2: 视频画面比例渲染
- **Status**: `completed`
- **Completion Evidence (2026-10-06)**: video_player_widget.dart 读 settings.aspectRatioMode 映射：16:9/4:3 固定比例 contain、fill=BoxFit.fill、crop=BoxFit.cover、auto/original=视频真实尺寸 contain（保留无尺寸 16:9 兜底）；旋转 RotatedBox 保留；GetDiagnostics 零错误。
- **Priority**: high
- **Depends On**: Task 1
- **Description**:
  - `video_player_widget.dart` 按 `settings.aspectRatioMode` 渲染：
    - auto：现有行为（视频尺寸比例，BoxFit.contain，16:9 兜底）
    - ratio16x9 / ratio4x3：SizedBox 强制对应比例 + contain
    - fill：BoxFit.fill（拉伸铺满）
    - original：按视频原始尺寸比例 contain（无 16:9 兜底时等同 auto，去掉兜底）
    - crop：BoxFit.cover 居中裁切（外层 SizedBox 填满）
  - PlayerController 暴露 `setAspectRatioMode`（T1 已建），切换后视频层立即 rebuild（Consumer/context.watch）。
- **Acceptance Criteria Addressed**: AC-5
- **Test Requirements**:
  - `rule` TR-2.1: 6 个枚举分支各自映射到明确的 BoxFit/宽高组合，代码走查无遗漏分支
  - `rule` TR-2.2: 切换模式后视频层即时 rebuild 且旋转（RotatedBox）行为不破坏
  - `rule` TR-2.3: GetDiagnostics 零错误

## Task 3: M3U/XMLTV 回看解析与回看播放入口
- **Status**: `completed`
- **Completion Evidence (2026-10-06)**: playlist_parser 解析 catchup/catchup-source/catchup-days 三属性，同名频道合并时补齐缺失回看字段；xmltv_epg_parser 读取 programme 子元素 `<catchup-source>`（回退同名属性）写入 EpgProgram.catchupUrl；PlayerController.playCatchup 经 buildCatchupUrl 构造地址、以 copyWith(streamUrls:[url]) 临时频道起播、失败返回 false 不污染原频道；三个文件 GetDiagnostics 零错误。
- **Priority**: medium
- **Depends On**: Task 1
- **Description**:
  - M3U 解析器读取 `catchup`、`catchup-source`、`catchup-days` 属性填入 Channel（含 `catchup=default` 时按源默认模板规则）。
  - XMLTV 解析器读取 programme 的 `<catchup-source>`（能力允许时）。
  - PlayerController 新增 `Future<bool> playCatchup(Channel, EpgProgram)`：构造 URL 成功则以临时直链方式播放（不改变当前频道/订阅），返回 true；失败返回 false 由 UI 提示。
- **Acceptance Criteria Addressed**: AC-3
- **Test Requirements**:
  - `rule` TR-3.1: 带 catchup 参数的 M3U 行解析后 Channel 三字段有值；不带时为 null
  - `rule` TR-3.2: playCatchup 成功/失败两条路径清晰，失败时不污染 currentChannel
  - `rule` TR-3.3: GetDiagnostics 零错误

## Task 4: 左侧三级抽屉（合并频道列表与 EPG）
- **Status**: `completed`
- **Completion Evidence (2026-10-06)**: 新建 lib/widgets/channel_epg_drawer.dart（约 1100 行，GetDiagnostics 零错误）：AnimatedPositioned 左滑、780 设计宽三列（112 分类/240 频道/EPG 自适应）；L1 首位固定「我的收藏」（红心+收藏数，buildFavoriteChannels 聚合，空态文案），其后 visibleCategories；L2 行=全局序号/台标 Image.network+兜底/名/用户收藏红心/当前播放蓝框，上下移动只 _channelFocusChanged 重置 L3 不播放，OK 500ms Timer 长按 toggleFavoriteChannel+SnackBar（_okLongFired 抑制抬起播放，Timer 抬起/back 取消），短按 800ms 防抖 playChannel+onClose；L3 水平日期条（数据自然日∪今天、catchupDays 下限过滤、周X/MM-DD、今天红/明天标注、左右换日重置选中、两阶段 ensureVisible）+ 当日 00:00–24:00 过滤列表（空态「该日期暂无节目单」），列表首项向上进日期条、日期条向下回列表；节目行前置周X/MM-DD 日期列+时间段+标题+五级徽章（直播红实底/预约白/已预约琥珀/已播放灰不可点 InkWell onTap null/回看蓝）；OK 分支：直播无动作、未播 toggleReservation+SnackBar、已触发灰态「预约已执行」、其余 playCatchup 成功关闭失败「该节目暂不支持回看」；_epgOkHeld 按住去重+800ms 防抖；频道@开始毫秒稳定标识对齐；打开定位当前分类（收藏优先）→当前频道→今天→当前节目；暴露 handleRemoteKey(action,isDown) 供 Task 8 双路径分发。
- **Priority**: high
- **Depends On**: Task 1, Task 3
- **Description**:
  - 新建 `lib/widgets/channel_epg_drawer.dart`：AnimatedPositioned 左滑出，三列布局（分类窄列/频道中列/EPG 宽列，ScaledPanel 体系、深色半透明）。
  - 状态机：level=1/2/3；上下移动当前列；右/OK 进下级；左键/返回逐级回退。
  - L1 首项固定为「我的收藏」虚拟分类（心形图标，始终显示，不参与分类显隐），其后为未隐藏真实分类；「我的收藏」二级频道由 buildFavoriteChannels() 聚合，空列表显示空态文案。
  - L2 频道行（序号/台标/名/已收藏心形标记）；上下移动即刷新 L3 节目单但不播放；**OK 短按（抬起时未满 500ms）=播放并关闭抽屉；长按 500ms=toggleFavoriteChannel + SnackBar，且不触发播放**（计时器在抬起/移出时取消，长按触发后本次抬起不再播放）；左键回一级。
  - L3 顶部为「日期选择条」、下方为当日节目列表。日期条按当前频道 EPG 聚合出所有有数据的自然日（受 catchup-days 回看窗口约束），项显示「周X MM-DD」、今天/明天特殊标注，默认选中今天；L3 焦点分日期条/列表两区（列表首项继续向上=进日期条，日期条左右换日、向下回列表）；列表按所选自然日 00:00–24:00 过滤，空日期显示「该日期暂无节目单」；切换频道/重开抽屉时日期重置为今天。
  - L3 节目行布局与参考图对齐：前置「周X / MM-DD」日期列，然后时间段（HH:00 - HH:00）、标题，最右状态按钮按五级优先级：直播徽标 > 未播「预约」> 未播「已预约」(琥珀) > 已播且预约已触发「已播放」(灰色置灰不可操作) > 已播「回看」。
  - 打开时定位当前分类→当前频道→今天→当前节目；列表滚动沿用「粗跳+ensureVisible 两阶段」；选中项稳定标识（频道@开始时间）防 EPG 刷新漂移。
  - OK 逻辑：L3 未播节目走 toggleReservation（含频道 ID 一致化、SnackBar、800ms 防抖、按住不重复）；「已播放」灰态无动作（可轻提示「预约已执行」）；普通过期节目走 playCatchup，失败提示「该节目暂不支持回看」。
  - 迁移 left_channel_drawer.dart 中切台防抖（800ms）、GlobalKey 定位等已验证逻辑；删除旧 LeftChannelDrawer/RightEpgPanel 的使用（文件在 Task 10 清理）。
- **Acceptance Criteria Addressed**: AC-1, AC-2, AC-2b, AC-2c, AC-3, AC-13
- **Test Requirements**:
  - `rule` TR-4.1: 走查按键状态机覆盖 AC-1 完整路径（含边界：一级左键=关闭、L2 播放后关闭、L3 列表/日期两区上下左右转换、L3 clamp）
  - `rule` TR-4.2: L2 焦点变化仅刷新 L3 不调用 playChannel；仅短按 OK 播放；长按 OK 只走 toggleFavoriteChannel（搜索 playChannel 与计时器回调调用点）
  - `rule` TR-4.3: 日期集合由节目数据聚合 + catchup-days 约束；过滤按自然日；切换频道重置今天；空态文案存在
  - `rule` TR-4.4: 预约/已预约/已播放灰态/回看/直播五类渲染与 OK 分支全覆盖；回看失败文案准确；节目行前置日期列
  - `rule` TR-4.5: 「我的收藏」固定 L1 首位、真实分类不受影响、空态文案存在；收藏心形即时刷新
  - `rubric` TR-4.6: 视觉与手感（三列+日期条与参考图一致性）；scale 1-5；anchors 同 AC-13；threshold >= 4；evidence 截图+走查
  - `rule` TR-4.7: GetDiagnostics 零错误

## Task 5: 右侧设置中心
- **Status**: `completed`
- **Completion Evidence (2026-10-06)**: 新建 lib/widgets/settings_rail.dart（GetDiagnostics 零错误）：右滑 380 设计宽，一级固定 5 行（画面比例/超时换源/分类管理/列表管理/偏好设置），右或 OK 进子级、左/返回回一级、再返回关闭；统一 _Entry 行模型（toggle/radio/action + enabled 置灰）+ 两阶段 ensureVisible 遥控器导航；子页：画面比例 6 选 1（setAspectRatioMode）；超时换源开关+5/10/15/20 秒（语义注释：sourceTimeoutSeconds==0=关、开启恢复 5 秒）；分类管理遍历 controller.categories 全量真实分类 setCategoryHidden（收藏虚拟分类不参与）；列表管理两行动作行回调 onManagePlaylist/onManageEpg（Task 6 接线）；偏好设置=自启动/置顶/启动最大化/setShowClock/DLNA/扫码管理 6 开关 + 画质 5 选 1 + 自动连播 + 面板自动隐藏 2/3/5/8/10 秒 + 界面缩放自动开关与手动 1.0~3.0 六档（自动时手动档置灰）；无缓冲时间、无手势灵敏度入口。
- **Priority**: high
- **Depends On**: Task 1, Task 2
- **Description**:
  - 新建 `lib/widgets/settings_rail.dart`：右侧滑入，一级 5 行（画面比例/超时换源/分类管理/列表管理/偏好设置），右或 OK 进子级，左/返回回退；遥控器上下导航+选中高亮；与左侧抽屉互斥（打开时关另一侧，通过 player_screen 协调）。
  - 子级实现：
    - 画面比例：6 选 1（调 setAspectRatioMode）。
    - 超时换源：开关 + 等待时间 5/10/15/20（写 sourceTimeoutSeconds；开关复用「超时换源」语义——若现有字段只有秒数，则以「秒数>0=启用、0/关闭」或新增 bool，二选一并在代码注释说明）。
    - 分类管理：全部分类+显隐开关（setCategoryHidden）。
    - 列表管理：节目源设置 / EPG 源设置 两行，分别打开 Task 6 窗口。
    - 偏好设置：自启动、置顶、启动最大化、显示时钟、投屏接收、手机扫码管理开关；视频画质、自动播放下一频道、面板自动隐藏、界面缩放（含自动适配）；全部走 controller.updateSettings/既有生效逻辑；无缓冲时间、无手势灵敏度。
  - 菜单打开期间按键不穿透（player_screen 侧在 Task 8 接线，本 widget 提供 handleRemoteKey）。
- **Acceptance Criteria Addressed**: AC-4, AC-5, AC-6, AC-11, AC-13
- **Test Requirements**:
  - `rule` TR-5.1: 一级恰好 5 行且子级控件与 FR-10~FR-14 一一对应（走查）
  - `rule` TR-5.2: 偏好设置每个控件绑定到既有 settings 字段与生效方法；缓冲/手势无入口
  - `rule` TR-5.3: 超时换源开关与秒数的持久化语义在代码注释中明确且往返一致
  - `rule` TR-5.4: GetDiagnostics 零错误

## Task 6: 节目源/EPG 源管理应用内窗口
- **Status**: `completed`
- **Completion Evidence (2026-10-06)**: 新建 lib/widgets/source_manage_dialog.dart（GetDiagnostics 零错误）：SourceManageDialog.present(context, isPlaylist, GlobalKey<SourceManageDialogState>)；深色 Dialog；二维码区读 settings.remoteAdminEnabled+remoteAdminUrl，关闭时「请先在偏好设置开启手机扫码管理」，开启时 96px QrImageView（圆角方形眼/模块）+URL+复制；源列表来自 SourceManager.playlists/epgs（watch 自动刷新），当前源蓝对号、OK/点击 selectPlaylist/selectEpg 切换，每行复制 URL（Clipboard+SnackBar）、删除（removePlaylist/removeEpg+SnackBar，焦点钳制）；底部名称选填（空则取 host）+URL+确定，addPlaylist/addEpg（type=url、format=unknown、毫秒 id），保存后清空+SnackBar；平面槽位遥控器模型（每源 3 槽+确定）handleRemoteKey(up/down/ok/back) 供 Task 8 modal 收口转发，输入框仅鼠标/软键盘。
- **Priority**: high
- **Depends On**: Task 5
- **Description**:
  - 新建 `lib/widgets/source_manage_dialog.dart`，两个命名入口（playlist / epg）：
    - 二维码区：remoteAdminUrl（需 remoteAdminEnabled；关闭时显示「请先在偏好设置开启手机扫码管理」）。
    - 源列表：读 SourceManager.playlists/epgs，当前源勾选；每行复制 URL、删除（confirm  SnackBar 即可）；OK/遥控器可操作。
    - 底部：名称选填输入框、URL 输入框、确定；保存调 addPlaylist/addEpg（或更新）后触发刷新/重新加载；JSON/headers 本期不做。
  - 窗口为 showDialog，遥控器按键纳入 player_screen 既有 modal 收口（OK/返回关闭与输入框焦点的处理：输入框行用鼠标/软键盘，遥控器焦点默认落在列表与确定按钮上）。
- **Acceptance Criteria Addressed**: AC-7
- **Test Requirements**:
  - `rule` TR-6.1: 两窗口数据均来自 SourceManager 现有 API；保存后列表刷新且当前源逻辑不损坏
  - `rule` TR-6.2: 遥控器可关闭窗口、切换列表项、删除；无按键穿透到视频
  - `rule` TR-6.3: GetDiagnostics 零错误

## Task 7: 底部控制面板重组
- **Status**: `completed`
- **Completion Evidence (2026-10-06)**: bottom_program_panel.dart 删除 remoteAdmin 二维码按钮（移除 onOpenRemoteAdmin 字段/_KbAction/addById）；原 epg 按钮改为 manageSources（Icons.source，标签「节目源」，onOpenManageSources 回调，dismiss=true）；频道列表/设置按钮保留；面板文件 GetDiagnostics 零错误；player_screen 构造参数在 Task 8 接线更新。
- **Priority**: medium
- **Depends On**: Task 6
- **Description**:
  - `bottom_program_panel.dart`：删除手机扫码管理按钮；原「节目单/EPG」按钮改为「节目源」（action=manageSources，由 player_screen 打开节目源窗口）；节目列表按钮 action 改为打开新三级抽屉；设置按钮 action 打开右侧设置中心；其余按钮不动。
  - 对应 onPressed/handleRemoteKey 回调由 player_screen 重新接线（Task 8）。
- **Acceptance Criteria Addressed**: AC-8
- **Test Requirements**:
  - `rule` TR-7.1: 按钮清单与 FR-16 完全一致（代码走查 _enabledActions）
  - `rule` TR-7.2: GetDiagnostics 零错误

## Task 8: player_screen 总接线（面板互斥、菜单键、返回层级、弹层守卫）
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 4, Task 5, Task 6, Task 7
- **Description**:
  - Stack 中用 ChannelEpgDrawer 替换 LeftDrawer+RightEpgPanel；新增 SettingsRail；移除 SettingsPanel。
  - 状态：`_drawerOpen`、`_settingsRailOpen` 互斥；面板按钮、短按 OK（直播开抽屉）、菜单键、C/E/S 快捷键重新接线；菜单键改为单击切换 rail，删除 500ms 长按设置计时器（_menuDown/_menuUp 简化）。
  - `_handleBackPressed` 新层级：设置子级→rail 一级→关 rail；抽屉三级→二级→一级→关抽屉；modal 对话框→maybePop；bottom panel→关；loading 守卫保留；皆无→退出框；保留 _exitDialogOpen 重入守卫。
  - 方向键/OK 在抽屉与 rail 打开期间全部转发对应 handleRemoteKey，不切台/不 seek；modal 打开期间维持现有收口。
  - Windows 钩子路径 `_onNativeAction` 同步同一套层级（back/menu/ok/方向）。
- **Acceptance Criteria Addressed**: AC-1, AC-4, AC-9, AC-14
- **Test Requirements**:
  - `rule` TR-8.1: 代码搜索确认无 _menuLongTimer/Timer(500ms) 设置面板逻辑；菜单单击翻转 rail
  - `rule` TR-8.2: 走查两条按键路径（HardwareKeyboard + _onNativeAction）的返回层级与 FR-18 完全一致
  - `rule` TR-8.3: 抽屉/rail 打开期间切台与 seek 入口均被前置 return 拦截
  - `rule` TR-8.4: GetDiagnostics 零错误
- **Completion Evidence (2026-10-06)**: player_screen.dart 全量接线完成：①imports 换成 channel_epg_drawer/settings_rail/source_manage_dialog；删除 _rightEpgOpen、_menuHeld/_menuLongFired/_menuLongTimer 字段与 _menuDown/_menuUp/_showRemoteAdminQr 方法（菜单键 contextMenu 两条路径均改为按下沿 _toggleSettings()）；GlobalKey 换 _drawerKey/_settingsRailKey，新增 _sourceDialogKey+_sourceDialogOpen。②overlay：BottomProgramPanel 接 onOpenManageSources（节目源窗口），ChannelEpgDrawer 替掉左右旧抽屉，SettingsRail 替掉 SettingsPanel（onClose 经 _toggleSettings(open:false) 恢复 _winHotkeys.setCapture）。③互斥：_openDrawer/_toggleDrawer/_toggleSettings({open}) 互相收口并隐藏 topBar；新增 _openSourceDialog(isPlaylist)——开 modal 前关抽屉/rail/底部面板、setCapture(false)，finally 复位。④返回层级 _handleBackPressed：rail→投屏→抽屉（转发 drawer handleRemoteKey('back') 走内部三级层级，并取消 hover 自动隐藏）→底部面板→loading 守卫→退出框。⑤按键收口：rail 打开期间 HardwareKeyboard/_onNativeAction 全部转发 rail；modal 期间 _sourceDialogOpen 转发 up/down/left/right/ok/back 给 SourceManageDialog（字母数字放行输入框），退出框保留专用逻辑；_panelKey 只发 drawer；左右边缘 hover/触摸滑动右缘改开 rail；快捷键 C/E 均开抽屉。全项目 GetDiagnostics 零错误/零警告。

## Task 9: 退出确认框重做（三按钮+关机）
- **Status**: `completed`
- **Priority**: medium
- **Depends On**: Task 8
- **Description**:
  - AlertDialog 去掉 title，content 为一句提示（如「请选择退出方式」）；actions 居中：取消（蓝）、退出程序（红）、关闭系统（橙，仅 windows/linux，defaultTargetPlatform 判断，web/安卓/iOS 不渲染）。
  - 焦点索引 0..2，左右循环移动、StatefulBuilder 刷新；OK 执行；back/esc/menu=取消。
  - 关机：Windows `shutdown /s /t 5`（给 5 秒延迟，命令前 SnackBar「即将关机，可运行 shutdown /a 取消」），Linux `poweroff`；用 Process.run（io 条件导入，web 不调用）。
  - 所有关闭路径保留「先摘 _exitDialogOpen 再 pop」一次性守卫（Flutter 全局、native、鼠标三处）。
- **Acceptance Criteria Addressed**: AC-10
- **Test Requirements**:
  - `rule` TR-9.1: 安卓构建下按钮数=2，桌面=3（平台条件渲染代码走查）
  - `rule` TR-9.2: 三条关闭路径都有一次性守卫；关机命令字符串与平台分支正确
  - `rule` TR-9.3: GetDiagnostics 零错误；web 构建不引用 Process.run
- **Completion Evidence (2026-10-06)**: 新增 services/system_power.dart 条件导出 + system_power_stub.dart（web 空实现）+ system_power_io.dart（Platform.isWindows→Process.run('shutdown',['/s','/t','5'])、isLinux→Process.run('poweroff',[])，web 编译不触碰 dart:io Process）。player_screen 退出框重写：showDialog<int?>（null=取消/1=退出程序/2=关机）；AlertDialog 去 title，content「请选择退出方式」，actionsAlignment 居中；_buildExitOption 统一构造 取消蓝/退出程序红/关闭系统橙；_canShutdownSystem（!kIsWeb && windows/linux）条件渲染第三项，安卓/iOS/Web/mac 仅 2 按钮。HardwareKeyboard 路径 _handleExitDialogKey 与 native _onNativeAction 均改为 0..n-1 左右循环、OK pop 当前索引、back/esc/menu pop null；所有路径先摘 _exitDialogOpen 再 pop（含鼠标 onPressed）；result==2 先 SnackBar（Win「5 秒后将关闭系统，可运行 shutdown /a 取消」/Linux「即将关闭系统…」）再 shutdownSystem()。全项目 GetDiagnostics 零错误。

## Task 10: 旧代码清理与全局静态验证
- **Status**: `completed`
- **Priority**: medium
- **Depends On**: Task 8
- **Description**:
  - 删除 left_channel_drawer.dart、right_epg_panel.dart、settings_panel.dart（含 showRemoteAdminQrDialog 迁移：二维码能力移入 Task 6 窗口后删除旧函数）；全局搜索旧类名/import 清零。
  - 清理缓冲时间/手势灵敏度在其它地方的入口引用（若有）；统一中文文案。
  - 全部改动文件 GetDiagnostics 零错误；人工核对命名冲突与枚举名（v1.0.139/143 教训）。
- **Acceptance Criteria Addressed**: AC-11, AC-12, AC-14
- **Test Requirements**:
  - `rule` TR-10.1: 全仓 grep 无 LeftChannelDrawer/RightEpgPanel/SettingsPanel/showRemoteAdminQrDialog 残留引用
  - `rule` TR-10.2: 所有被改 dart 文件 GetDiagnostics 为空
- **Completion Evidence (2026-10-06)**: 已删除 lib/widgets/left_channel_drawer.dart、right_epg_panel.dart、settings_panel.dart（showRemoteAdminQrDialog 随之删除，二维码能力已在 Task 6 SourceManageDialog 内）；删除后全仓 *.dart grep 旧类名/旧 import/函数零命中；缓冲时间/手势灵敏度仅保留 model 字段与功能层使用（fvp 注册、滑屏音量亮度系数、main.dart 启动读取），UI 入口无残留；删除后全项目 GetDiagnostics 零错误。

## Task 11: 应用图标「视频取景框」资源与 CI 覆盖
- **Status**: `completed`
- **Completion Evidence (2026-10-06)**: branding/ 下生成 icon_1024.png、android 五档 mipmap（48/72/96/144/192）、app_icon.ico（256/16 六档 PNG 条目）、web Icon-192/512+maskable+favicon；源图实测边界 x1397..1713/y247..556、圆角 R≈66 做透明底圆角蒙版；build.yml 三作业（android/windows/web）flutter create 后均已加 Apply app icon 覆盖步骤；主图目视通过（取景框/OM/播放钮完整、角透明、无白边）。
- **Priority**: medium
- **Depends On**: None（可与 UI 任务并行）
- **Description**:
  - 从用户选定的图标方案图（视频取景框）裁剪出图标主体（深色圆角方块+取景框角线+OM+右下播放圆钮），透明底、保留适度安全边距。
  - 生成 `branding/` 资源：icon_1024.png（主图）；android 五档 `mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png`（48/72/96/144/192）；`app_icon.ico`（256/128/64/48/32/16 多尺寸 PNG 压缩条目）；web `Icon-192.png`、`Icon-512.png`、`favicon.png`。
  - build.yml 三个作业（android/windows/web）在 `flutter create` 之后各加一步「Apply app icon」：覆盖 `android/app/src/main/res/mipmap-*/ic_launcher.png`、`windows/runner/resources/app_icon.ico`、`web/icons/*` 与 `web/favicon.png`，再进入构建。
- **Acceptance Criteria Addressed**: AC-12b
- **Test Requirements**:
  - `rule` TR-11.1: branding/ 下资源尺寸与路径逐一核对（文件存在+像素尺寸）
  - `rule` TR-11.2: build.yml 三个作业均有拷贝步骤且路径与 flutter create 生成模板一致
  - `rule` TR-11.3: 主图目视检查：取景框/OM/播放钮完整、圆角透明、无白底毛边

## Task 12: 版本号与提交
- **Status**: `pending`
- **Priority**: high
- **Depends On**: Task 10, Task 11
- **Description**:
  - pubspec.yaml → `1.1.001+2001`；提交全部改动到 main（不推 tag）。
  - Review 通过后：打 tag v1.1.001、推送、创建中文 Release、监控四平台 CI 并挂产物；失败按发版 skill 递增修复。
- **Acceptance Criteria Addressed**: AC-12
- **Test Requirements**:
  - `rule` TR-12.1: pubspec 版本字符串为 1.1.001+2001
  - `rule` TR-12.2: Review pass 后四平台 CI 全 success（证据为 CI run 与 Release 产物列表）
