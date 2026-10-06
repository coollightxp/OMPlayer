# v1.1.001 UI 重构 — 独立代码审查报告

- 审查日期：2026-10-06
- 审查方式：fresh-context 只读独立审查（未改文件）+ 主会话修复复核
- 审查依据：`.trae/specs/2026-10-06-ui-redesign-v1.1/spec.md`（FR-1..FR-25、AC-1..AC-14）与 tasks.md
- 验证限制：本机无 Flutter SDK，未运行 analyze/构建；结论基于人工通读 + GetDiagnostics（零错误），构建以 CI 为准

## 审查结论

发现 2 个严重问题与 8 个一般问题；**2 个严重问题 + 6 个一般问题已修复并复核**，2 个一般项记录为已知风险/暂缓。

## 严重问题（已修复）

### S1. 隐藏分类仍参与切台循环/数字选台 —— 已修复
- 现象：`playAdjacentChannel`、`flatChannels` 展平全部 `_categories`，用户在「分类管理」隐藏分类后，遥控器上下键、数字选台仍能进入该分类频道，违反 FR-12/AC-6。
- 修复：
  - `player_controller.dart` `flatChannels` 改为基于 `visibleCategories` 展平；`playAdjacentChannel` 改用 `flatChannels`。数字选台、播放失败兜底（video_player_widget）随之统一口径。
  - `channel_epg_drawer.dart` L2 全局序号偏移（globalOffset）由遍历 `categories` 改为 `visibleCategories`，频道序号与数字选台完全一致。
- 口径决策：隐藏分类 = 从浏览/切台/序号中整体移除（「我的收藏」为虚拟分类，本就不在 `_categories` 内，不受影响）。

### S2. 底部面板「频道列表」OK 抬起沿误触发抽屉播放 —— 已修复
- 现象：OK 按下时底部面板激活并同步打开抽屉、关闭自身；OK 抬起时 player 层把孤立的 `ok-up` 转发给刚打开的抽屉，L2 未校验配对 down 即执行 `_playFocusedChannel`，导致当前频道被重新 playChannel（内核重建）且抽屉一闪即关。
- 修复：`channel_epg_drawer.dart` 新增 `_l2OkDown` 配对守卫——L2 仅在收到本次按下沿后才允许抬起播放；在 `_initOnOpen`、`_handleBack`、L2 左右移出层级时复位。无配对 down 的孤立 up（含 L1 OK 进 L2 的抬起沿）一律忽略。鼠标点击路径不受影响。

## 一般问题处置

| 编号 | 问题 | 处置 |
| --- | --- |
| G3 | Android PopScope 返回在 rail 子页直接整栏关闭，跳过子级→一级 | 已修复：`_handleBackPressed` 改为转发 rail `handleRemoteKey('back')`，与 Esc/native 同路径 |
| G4 | 回看临时频道仅 1 条地址，起播失败后切源无备用 | 已知风险，本期保留：成功才替换当前频道且失败有 SnackBar；后续版本可加失败回滚 |
| G5 | 媒体快退/快进键注释写 ±10 秒，实现为 ±60 秒 | 已修复注释 |
| G6 | catchup 模板以 `/` 开头的相对路径被错拼成 `base?/path` | 已修复：识别前导 `/`，按直播地址 origin 拼同源绝对路径（http/https 校验） |
| G7 | 从 rail「列表管理」进源对话框，关闭后回不到 rail | 已修复：`_openSourceDialog` 记录 cameFromRail，关闭后恢复 rail（含 setCapture 状态） |
| G8 | 抽屉 L2 频道序号在有隐藏分类时不连续 | 已修复（随 S1，改用 visibleCategories 计偏移） |
| G9 | source_manage_dialog `_slotKeys` 删除源后不清理 | 已修复：删除后 removeWhere 越界 key |
| G10 | player_screen build 历史深层缩进 | 暂缓：纯格式问题，避免大面积无功能 diff |

## PASS 项（审查逐条核实通过）

- 退出框（FR-20/21）：无标题、「请选择退出方式」、三按钮居中（actionsAlignment）、平台条件渲染（仅非 Web 的 Windows/Linux 显示关闭系统）、左右循环、四条关闭路径（硬件 OK/Esc/菜单、native、鼠标）均先摘 `_exitDialogOpen` 再 pop；`shutdown /s /t 5` + SnackBar 取消提示、Linux `poweroff`；system_power 条件导出三件套，web 不引用 dart:io。
- 按键体系：菜单键单击 toggle rail（500ms 长按计时器已删尽）；抽屉/rail/modal 四态互斥与两条按键路径（HardwareKeyboard + win native hook）转发一致；modal 内字母数字放行输入框；setCapture 在 rail/对话框开关后恢复正确。
- 三级抽屉：L1「我的收藏」固定首位；L2 短按播放关闭/长按 500ms 收藏（800ms 防抖）；L3 日期条自然日聚合 ∪ 今天、catchup-days 下限、两阶段 ensureVisible；五级徽章优先级与置灰不可操作；空态文案；索引防护齐全。
- 回看链路：M3U 三属性解析与同名频道合并补缺；XMLTV `<catchup-source>` 子元素优先属性回退；占位符 `{start}/{end}/{utc}/{utcend}/{duration}` 与 `$start/$end`；playCatchup 失败 false → SnackBar；临时频道保留 tvgId/name 不影响 EPG 匹配与订阅。
- 预约：±60000ms 容差；频道解析三处统一；触发记录持久化；触发时优先按预约记录重建频道。
- 设置：画面比例 6 模式映射 + RotatedBox；隐藏分类/收藏/偏好持久化；超时换源 0=关/5/10/15/20；无缓冲时间、手势灵敏度入口；updateSettings 副作用同步。
- 底部面板：二维码按钮删除；节目源(Icons.source)/频道列表/设置三跳转键；既有播放控制保留。
- 回归点：点播左右立即 ±60s seek + 中央 OSD 不弹面板；loading 返回拦截；切台 OSD；旧三类/旧函数全仓零残留。
- 图标/CI/版本：branding 资源尺寸实测齐全；build.yml android/web/windows 三作业 Apply app icon 步骤在 flutter create 之后；pubspec `1.1.001+2001`。
- Flutter 3.44.8 API 兼容：activeColor、Focus(canRequestFocus:false) 包 TextButton、AlertDialog.actionsAlignment、qr_flutter 4.1.0 API、GlobalKey 泛型与 handleRemoteKey 签名全部匹配。

## 修复后验证

- 全项目 GetDiagnostics：零错误。
- 待 CI：android/web/windows 三平台构建（Flutter 3.44.8）为最终编译验证。
