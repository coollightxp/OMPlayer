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

## Verification Conclusion
等待 post-fix 证据：期望快照由 `p:1,ct 冻结` 变为 `p:0` 且 ct 持续增长，__om_playing 后视频全屏起播。
