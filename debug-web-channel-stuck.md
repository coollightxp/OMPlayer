# Debug Session: web-channel-stuck
- **Status**: [OPEN]
- **Issue**: Windows 网页频道卡在"网页频道缓冲中"灰屏，点击页面/播放按钮均无反应，8 秒强制前台兜底未生效；v1.0.62/v1.0.63 两轮静态修复（缓存清理、主视频中心控制）均未解决
- **Debug Server**: http://127.0.0.1:7777/event
- **Log File**: .dbg/trae-debug-log-web-channel-stuck.ndjson

## Reproduction Steps
1. 打开 OMPlayer（Windows，驰为 Win10 家庭版）
2. 选择网页频道（webview:// 包装，如 CCTV-5+ / CCTV-6 网页版）
3. 观察：长时间停留在"网页频道缓冲中"黑/灰屏，点击无反应

## Hypotheses & Verification
| ID | Hypothesis | Likelihood | Effort | Evidence |
|----|------------|------------|--------|----------|
| A | WebView2 渲染进程卡死/崩溃，JS eval 全部失败或超时 | High | Low | Pending |
| B | 页面根本没加载成功（网络/加载错误），进度回调无进展 | Medium | Low | Pending |
| C | JS 注入成功但找不到主视频（跨域 iframe/页面结构），reload 两次后放弃 | Medium | Low | Pending |
| D | 8 秒强制前台计时器未触发或 foreground 状态被重置 | Medium | Low | Pending |
| E | Flutter UI 线程整体冻结（所有计时器停走） | Low | Low | Pending |

## Log Evidence（pre-fix，2026-10-01，4 次换台，站点 yangshipin.cn/tv/home?pid=…）

每次换台同一模式：
1. 页面加载完全正常：progress 0→33→66→100、onLoadStop、`drs:"complete"`（行 5-16/37-42/69-80/109-116）→ **B 否决**
2. JS eval 全程可用、无异常，`rs:4`（HAVE_ENOUGH_DATA）→ **A 否决**
3. 视频元素存在且唯一，尺寸恒为 **1536×864**（被注入 CSS 强制铺满的结果）
4. 视频短暂前进到 ct≈0.6~1.4 秒后**永久 `p:1`（暂停）、currentTime 冻结、rs:4**（行 22-31/54-63/86-103/126-152）
5. 8 秒兜底定时器准时触发、setWebForeground(true) 成功、fg=true（行 20-21/52-53/84-85/124-125）→ **D 否决**
6. 2 秒心跳全程不断 → **E 否决**
7. 用户点播放按钮 5 次：JS 均返回 `r:"0"`（已对 video 调 play()），但 2 秒后快照仍 `p:1`（行 94/132/145/147/148/150）→ **站点播放器立刻把程序化 play() 打回暂停，它只认自己的播放按钮激活**

## 判定
| ID | 假设 | 结论 |
|----|------|------|
| A | WebView2 渲染进程卡死 | ❌ 否决：eval/心跳全程正常 |
| B | 页面没加载成功 | ❌ 否决：100% complete |
| C | 找不到视频 | ⚠️ 变异：视频在、已缓冲(rs=4)，但被站点播放器按住暂停，程序化 play() 无效 |
| D | 8 秒前台兜底失效 | ❌ 否决：准时触发 |
| E | UI 线程冻结 | ❌ 否决 |

**新根因假设 F（高置信）**：注入 CSS 把 `<video>` 强制 `position:fixed;100vw/100vh;z-index:2147483647`，盖在央视频站点自己的播放按钮之上 → 用户真实点击落在 video 上、点不到站点的大播放按钮；而站点播放器的状态机只接受自己的按钮激活（程序化 video.play() 被立即暂停），导致永久暂停。

## Instrumentation (v1.0.64+65, runId=pre-fix)
- player_screen.dart：`_dbg` 上报器（http→127.0.0.1:7777）；overlay init/forceFgTimer/onWebViewCreated/onLoadStop/onProgressChanged(10%降频)/onReceivedError/_probe 结果与失败；新增 2s 诊断心跳 `_diagReport`（`_diagJs` 只读快照：视频数/主视频 paused/readyState/currentTime/尺寸/reload 计数/href）
- player_controller.dart：`_dbg` 上报器；attachWebBridge/detachWebBridge/setWebForeground/_openWebPageChannel/togglePlayPause(网页分支结果与异常)
- 业务逻辑零改动；诊断构建随 v1.0.64 发布

## Fix (v1.0.65+66, runId=post-fix，保留全部插桩)
1. `_cssJs`：video 的 fixed/100vw/100vh/z-index 最大化规则改为 `html.__om_playing video` 门控——起播前保留站点原生播放器布局（站点自己的大播放钮可见可点），起播锁定后才拉满全屏
2. `_bootJs`：
   - hookDoc 内对每个同源文档注册捕获阶段 click 代理：起播前用户真实点击落在 video 上时，临时给所有 video 设 pointer-events:none，用 elementFromPoint 找其下方站点真实播放按钮（button/[role=button]/类名含 play|start|poster|cover/cursor:pointer），在同一 user-activation 窗口内向其派发 MouseEvent；找不到则完全不干预；含视口内小网格搜索
   - kick 每拍向所有 hookedDocs 同步 `__om_playing` class（随 started 开/关，含停滞解锁与 SPA 换页复位）
3. `_webToggleJs`（信息栏播放钮）：暂停时先在视口中心附近 elementFromPoint 代点站点大播放钮，再兜底 video.play()
4. runId 切 post-fix；业务行为其余不变

## Verification Conclusion（迭代 1，v1.0.65 post-fix）
部分见效：页面 UI 完整露出（视频尺寸 1536×864 → 原生 890×500），用户能看到央视频整站界面；但视频仍 `p:1`、ct 冻结 0.4~0.5，信息栏 toggle r:"0" 后仍被暂停。说明除"按钮被盖住"外还存在站点侧激活门槛（疑似只接受真实手势/仅允许静音自动播放）。

## Iteration 2 证据（v1.0.67，央视频 pid=600001818/600108442）
1. **播放器真身 = VideoJS**：`event.play/pause on VIDEO.video-js vjs-default-skin vjs-big-play-centered`
2. 视频区中心命中链（video 临时 pointer-events:none 后）不是 vjs 大播放钮，而是**站点自盖的遮罩**：`div.loading.black-bg < div.con.poster < div#vodbox...c-container.img`，后期为 `div.y-full-bg/div.container < div.con.poster`——站点自己的"加载中/海报"层一直不消失，盖在 VideoJS 控件之上
3. 反复循环：`call.play`(我们) → 300ms 后 `call.pause`(站点)；event.play→event.pause；视频 ct 曾从 0 爬到 0.7 / 8.1 后永久暂停，rs:4
4. 初始 `muted=true`（站点默认静音起播策略），我们的注入每拍强制 muted=false——疑似 play() 带声被拒绝→VideoJS 捕获 reject→pause
5. `proxy-click MISS @0,0` 全部是我们自己 kick 里 `main.click()` 的合成点击（坐标 0,0），且未拦截时会落到 video 上让 VideoJS 切换暂停（自己和自己打架）；**用户真实点击在日志里零记录**（落在 poster 层而非 video，无法证明是否到达网页，需补 document 级 mousedown 探针）
6. 站点 WASM HLS 管线（hls.cmg.js + cmg.worker.js）疑似未完成初始化（loading 层不消失）；需查 SharedArrayBuffer/window.error/videojs player.error

## Iteration 3 (v1.0.68) 方案
- 行为修复：起播锁定前不再强制 unmute（kick/_probeJs/_applyWebVolume/_webToggleJs 全部由 window.__omStarted 门控），让站点按静音策略起播，started 后再解除静音
- 去掉 main.click() 合成点击（避免 0,0 点击误触 VideoJS 暂停）
- 代点选择器补站点遮罩 .con.poster/.loading-main/.y-full-bg/.y-full/[id^="vodbox"]，并记录 clickbtn 命中
- 补证据：修正调用栈上报（拼进消息）、env(SAB/Worker/UA)、window.onerror/unhandledrejection、play() reject reason、videojs 玩家 paused/rs/ns/currentSrc/error、document 级 mousedown 坐标+目标链（验证真实点击是否到达网页）、快照增加 mu
- 待验证：静音起播能否让站点管线进入播放态；真实点击是否被 WebView2 HWND 吞掉
