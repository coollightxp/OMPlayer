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

## Log Evidence
（待收集）

## Instrumentation (v1.0.64+65, runId=pre-fix)
- player_screen.dart：`_dbg` 上报器（http→127.0.0.1:7777）；overlay init/forceFgTimer/onWebViewCreated/onLoadStop/onProgressChanged(10%降频)/onReceivedError/_probe 结果与失败；新增 2s 诊断心跳 `_diagReport`（`_diagJs` 只读快照：视频数/主视频 paused/readyState/currentTime/尺寸/reload 计数/href）
- player_controller.dart：`_dbg` 上报器；attachWebBridge/detachWebBridge/setWebForeground/_openWebPageChannel/togglePlayPause(网页分支结果与异常)
- 业务逻辑零改动；诊断构建随 v1.0.64 发布

## Verification Conclusion
（待分析）
