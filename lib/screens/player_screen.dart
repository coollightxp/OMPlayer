import 'dart:async';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../services/player_controller.dart';
import '../services/web_env.dart';
import '../services/web_launch.dart';
import '../services/win_hotkeys.dart';
import '../services/window_drag.dart';
import '../widgets/bottom_program_panel.dart';
import '../widgets/gesture_indicator_overlay.dart';
import '../widgets/left_channel_drawer.dart';
import '../widgets/right_epg_panel.dart';
import '../widgets/settings_panel.dart';
import '../widgets/top_title_bar.dart';
import '../widgets/video_player_widget.dart';

/// 主播放器界面
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WindowListener {
  // 面板显隐状态
  bool _leftDrawerOpen = false;
  bool _rightEpgOpen = false;
  bool _bottomPanelVisible = false;
  bool _settingsOpen = false;

  // 手势调节状态
  bool _showBrightnessIndicator = false;
  bool _showVolumeIndicator = false;

  // 手势检测
  double? _dragStartY;
  double? _dragStartX;
  double _lastBrightness = 0.8;
  double _lastVolume = 0.8;
  bool _isHorizontalDrag = false;
  static const double _edgeWidth = 30;
  static const double _dragSensitivity = 0.005;

  // 底部面板自动隐藏定时器
  Timer? _bottomHideTimer;

  // 控制器监听
  PlayerController? _controllerRef;
  PlayerState _prevState = PlayerState.idle;
  String? _prevChannelId;
  bool _prevWebActive = false;

  // 鼠标自动隐藏（播放中 3 秒无动作）
  Timer? _cursorHideTimer;
  bool _cursorHidden = false;

  // 侧边抽屉自动隐藏
  Timer? _drawerHideTimer;
  static const _drawerAutoHide = Duration(seconds: 3);

  // 切台 OSD
  Timer? _osdTimer;
  bool _osdVisible = false;

  // 数字选台输入缓存
  String _numBuffer = '';
  Timer? _numTimer;

  // 底部面板 hover 状态（悬停时不自动隐藏）
  bool _bottomHovering = false;

  // 顶部悬停标题栏
  bool _topBarVisible = false;

  // 根焦点：硬件快捷键（含数字选台）都挂在这个节点上。
  // 点击抽屉/面板内按钮后焦点会跑到子节点甚至随面板销毁而丢失，
  // 导致数字键/快捷键失灵，需要在交互后把焦点抢回来。
  final FocusNode _rootFocusNode = FocusNode();

  /// Windows 低级键盘钩子桥：WebView2 吞焦点时数字选台仍可用
  final WinHotkeys _winHotkeys = WinHotkeys();

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // 全局硬件键盘监听：不依赖 Flutter 焦点，任何控件持有焦点、面板
    // 关闭后都能收到按键；中文输入法状态下硬件 KeyDown 照样送达。
    HardwareKeyboard.instance.addHandler(_onGlobalKeyEvent);
    // Windows：低级键盘钩子转发数字键与动作键（网页 HWND 吞焦点时也有效）
    _winHotkeys.setDigitHandler(_onNumberKey);
    _winHotkeys.setActionHandler(_onNativeAction);
    // 桌面端拦截窗口关闭：网页频道的 WebView2 若随引擎一起析构，
    // 部分系统会在退出瞬间抛 0xc000000d。先让网页控件销毁再关窗。
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
  }

  @override
  void onWindowClose() async {
    final c = _controllerRef;
    try {
      if (c != null && c.webPageActive) {
        c.exitWebPage();
        // 等一帧让 WebView 平台视图完成原生销毁，规避退出崩溃
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = context.read<PlayerController>();
    if (_controllerRef != c) {
      _controllerRef?.removeListener(_onControllerChanged);
      _controllerRef = c..addListener(_onControllerChanged);
      // 首帧布局完成后，按「启动全屏」设置决定是否进入全屏（只执行一次）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) c.applyStartupFullscreen();
      });
    }
  }

  void _onControllerChanged() {
    final c = _controllerRef;
    if (c == null || !mounted) return;
    final becamePlaying =
        c.state == PlayerState.playing && _prevState != PlayerState.playing;
    _prevState = c.state;

    // 切台：显示左上角台名/节目名 OSD
    final cid = c.currentChannel?.id;
    if (cid != null && cid != _prevChannelId) {
      _showChannelOsd();
    }
    _prevChannelId = cid;

    if (becamePlaying && c.currentChannel != null) {
      setState(() {
        _bottomPanelVisible = true;
        _bottomHovering = false;
      });
      _scheduleBottomHide();
      _pokeCursor();
    }

    // 网页频道切入/切出：切入时像正常起播一样先显示信息面板再自动隐藏
    if (c.webPageActive != _prevWebActive) {
      _prevWebActive = c.webPageActive;
      if (c.webPageActive) {
        setState(() {
          _bottomPanelVisible = true;
          _bottomHovering = false;
        });
        _scheduleBottomHide();
        _pokeCursor();
      }
    }
  }

  /// 切台提示：大字台名 + 小字当前节目，8 秒后消失
  void _showChannelOsd() {
    _osdTimer?.cancel();
    setState(() => _osdVisible = true);
    _osdTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _osdVisible = false);
    });
  }

  /// 数字键选台：追加到缓存，1.5 秒后跳转
  void _onNumberKey(int n) {
    // 设置面板打开时不拦截数字键（避免影响输入框）
    if (_settingsOpen) return;
    setState(() {
      _numBuffer += n.toString();
      _osdVisible = true;
    });
    _numTimer?.cancel();
    _numTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted && _numBuffer.isNotEmpty) {
        final number = int.tryParse(_numBuffer);
        if (number != null) {
          context.read<PlayerController>().playChannelByNumber(number);
        }
        setState(() => _numBuffer = '');
      }
    });
  }

  /// 网页频道内由 JS 转发来的按键（焦点在 WebView 时 Flutter
  /// 收不到键盘消息）：d0-d9 数字选台，fullscreen 切换全屏
  void _onWebKey(String key) {
    if (_settingsOpen) return;
    if (key.startsWith('d')) {
      final n = int.tryParse(key.substring(1));
      if (n != null) _onNumberKey(n);
    } else if (key == 'fullscreen') {
      context.read<PlayerController>().toggleFullscreen();
    } else if (key == 'exitfullscreen') {
      context.read<PlayerController>().exitFullscreenIfNeeded();
    }
  }

  // 数字键（主键盘 + 小键盘）
  static const List<LogicalKeyboardKey> _digitKeys = [
    LogicalKeyboardKey.digit0,
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];
  static const List<LogicalKeyboardKey> _numpadKeys = [
    LogicalKeyboardKey.numpad0,
    LogicalKeyboardKey.numpad1,
    LogicalKeyboardKey.numpad2,
    LogicalKeyboardKey.numpad3,
    LogicalKeyboardKey.numpad4,
    LogicalKeyboardKey.numpad5,
    LogicalKeyboardKey.numpad6,
    LogicalKeyboardKey.numpad7,
    LogicalKeyboardKey.numpad8,
    LogicalKeyboardKey.numpad9,
  ];

  // 物理键（USB HID 码）：与输入法/布局无关，主键盘数字行
  static const List<PhysicalKeyboardKey> _physDigitKeys = [
    PhysicalKeyboardKey.digit0,
    PhysicalKeyboardKey.digit1,
    PhysicalKeyboardKey.digit2,
    PhysicalKeyboardKey.digit3,
    PhysicalKeyboardKey.digit4,
    PhysicalKeyboardKey.digit5,
    PhysicalKeyboardKey.digit6,
    PhysicalKeyboardKey.digit7,
    PhysicalKeyboardKey.digit8,
    PhysicalKeyboardKey.digit9,
  ];

  // 小键盘数字（含安卓遥控器数字键常见映射）
  static const List<PhysicalKeyboardKey> _physNumpadKeys = [
    PhysicalKeyboardKey.numpad0,
    PhysicalKeyboardKey.numpad1,
    PhysicalKeyboardKey.numpad2,
    PhysicalKeyboardKey.numpad3,
    PhysicalKeyboardKey.numpad4,
    PhysicalKeyboardKey.numpad5,
    PhysicalKeyboardKey.numpad6,
    PhysicalKeyboardKey.numpad7,
    PhysicalKeyboardKey.numpad8,
    PhysicalKeyboardKey.numpad9,
  ];

  /// 鼠标活动：恢复显示并重置 3 秒隐藏计时（仅播放中计时）
  void _pokeCursor() {
    if (!mounted) return;
    if (_cursorHidden) setState(() => _cursorHidden = false);
    _cursorHideTimer?.cancel();
    final controller = context.read<PlayerController>();
    // 网页频道：通知网页重置光标隐藏定时器
    // （数字键切频道等 Flutter 侧交互不会触发网页 JS 事件）
    if (controller.webPageActive && controller.webController != null) {
      try {
        controller.webController
            .evaluateJavascript(source: 'window.__omShowCursor && window.__omShowCursor()');
      } catch (_) {}
    }
    if (!controller.isPlaying) return;
    _cursorHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted &&
          controller.isPlaying &&
          !_settingsOpen &&
          !_leftDrawerOpen &&
          !_rightEpgOpen) {
        setState(() => _cursorHidden = true);
      }
    });
  }

  /// 鼠标在抽屉内：始终保持显示
  void _cancelDrawerHide() {
    _drawerHideTimer?.cancel();
  }

  /// 抽屉打开（桌面端 3 秒后无悬停自动隐藏；移动端需手动关闭）
  void _armDrawerAutoHide() {
    final desktop = context.read<PlayerController>().isDesktop;
    if (!desktop) return;
    _startDrawerHideTimer();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKeyEvent);
    _winHotkeys.setDigitHandler(null);
    _winHotkeys.setActionHandler(null);
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      windowManager.removeListener(this);
    }
    _cursorHideTimer?.cancel();
    _drawerHideTimer?.cancel();
    _osdTimer?.cancel();
    _numTimer?.cancel();
    _rootFocusNode.dispose();
    _controllerRef?.removeListener(_onControllerChanged);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  /// 把焦点收回根节点，保证硬件快捷键/数字选台随时可响应。
  /// 设置面板打开时不抢焦点（里面有输入框）。
  void _ensureShortcutFocus() {
    if (_settingsOpen) return;
    if (_rootFocusNode.hasPrimaryFocus) return;
    _rootFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
      // 返回键始终拦截，统一交给 _handleBackPressed 处理
      // （含无面板时的退出确认）；否则 canPop=true 时系统会直接退出
      return Focus(
        focusNode: _rootFocusNode,
        autofocus: true,
        child: PopScope(
          canPop: false,
          onPopInvoked: (didPop) {
            if (!didPop) _handleBackPressed();
          },
          child: Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        cursor: _cursorHidden ? SystemMouseCursors.none : MouseCursor.defer,
        onHover: (event) {
          _pokeCursor();
          // 鼠标靠近屏幕顶部时呼出悬停标题栏
          final nearTop = event.position.dy < 40;
          if (nearTop != _topBarVisible) {
            setState(() => _topBarVisible = nearTop);
          }
        },
        child: Listener(
          // 任何鼠标/触摸活动都恢复显示鼠标，并把快捷键焦点收回根节点
          onPointerDown: (_) {
            _pokeCursor();
            // 面板可能在静止光标下滑出（无 hover 事件），
            // 用户开始点击时保持面板不自动隐藏
            if (_leftDrawerOpen || _rightEpgOpen) {
              _cancelDrawerHide();
            }
            _ensureShortcutFocus();
          },
          onPointerMove: (_) {
            _pokeCursor();
          },
          child: Consumer<PlayerController>(
            builder: (context, controller, _) {
              // 网页频道下信息面板按「播放中」逻辑自动隐藏（只看
              // _bottomPanelVisible）；普通频道维持原逻辑
              final panelVisible = controller.webPageActive
                  ? _bottomPanelVisible
                  : _bottomPanelVisible ||
                      controller.state != PlayerState.playing;
              final webUrl = controller.webPageActive
                  ? controller.currentChannel?.webPageUrl ?? ''
                  : '';
              return Stack(
                children: [
                  // 最底层：网页频道控件。网页在后台缓冲时也存在于此，
                  // 被上方黑屏占位盖住；起播后黑屏移走，网页显露到全屏
                  if (webUrl.isNotEmpty)
                    Positioned.fill(
                      child: _WebChannelOverlay(
                        key: ValueKey(webUrl),
                        url: webUrl,
                        foreground: controller.webPageForeground,
                        onForeground: () =>
                            controller.setWebForeground(true),
                        onWebKey: _onWebKey,
                        onPlayStateChanged: controller.setWebPlaying,
                        onWebMouseMove: _pokeCursor,
                        onBridgeAttached: controller.attachWebBridge,
                        onBridgeDetached: controller.detachWebBridge,
                      ),
                    ),

                  // 视频层：
                  // - 普通频道：正常视频控件
                  // - 网页频道后台缓冲中：黑屏占位（网页在其下方缓冲）
                  // - 网页频道前台播放：空层（让下方网页全屏显露）
                  // - 等待网络：显示网络等待提示
                  Positioned.fill(
                    child: controller.state == PlayerState.waitingForNetwork
                        ? Container(
                            color: Colors.black,
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  CircularProgressIndicator(
                                      color: Colors.blueAccent),
                                  SizedBox(height: 16),
                                  Text('正在等待网络连接...',
                                      style: TextStyle(
                                          color: Colors.white70,
                                          fontSize: 16)),
                                  SizedBox(height: 8),
                                  Text('网络恢复后将自动开始播放',
                                      style: TextStyle(
                                          color: Colors.white54,
                                          fontSize: 13)),
                                ],
                              ),
                            ),
                          )
                        : !controller.webPageActive
                            ? const VideoPlayerWidget()
                            : (!controller.webPageForeground
                                ? Container(
                                    color: Colors.black,
                                    child: Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const CircularProgressIndicator(
                                              color: Colors.blueAccent),
                                          const SizedBox(height: 12),
                                          const Text('网页频道缓冲中，起播后自动切换...',
                                              style: TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 14)),
                                          const SizedBox(height: 16),
                                          TextButton.icon(
                                            onPressed: () => controller
                                                .setWebForeground(true),
                                            icon: const Icon(Icons.open_in_new,
                                                size: 18,
                                                color: Colors.white70),
                                            label: const Text('立即显示网页',
                                                style: TextStyle(
                                                    color: Colors.white70)),
                                          ),
                                        ],
                                      ),
                                    ),
                                  )
                                : const SizedBox.shrink()),
                  ),

                  // 桌面端亮度调节遮罩：仅普通视频层生效。
                  // 网页频道用 WebView2 原生 HWND，Flutter 半透明层盖上去
                  // 会变成灰蒙蒙，所以网页频道走系统亮度调节，不叠 Flutter 遮罩
                  if (controller.isDesktop && !controller.webPageActive)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          color: Colors.black.withOpacity(
                              (1.0 - controller.brightness) * 0.9),
                        ),
                      ),
                    ),

                  // 切台 OSD（左上角序号/台名/节目名）
                  // 放在手势层与各面板【之下】：面板滑出时盖住它，
                  // 避免 OSD 卡片挡住频道面板顶部的返回按钮
                  _buildChannelOsd(controller),

                  // 右上角系统时间：在视频画面之上、所有弹出面板之下
                  if (controller.settings.showClock) _buildClock(),

                  // 手势检测层：普通模式全功能；网页模式仅保留左右两侧
                  // 垂直滑动（亮度/音量），中间区域完全穿透不拦截网页点击，
                  // 面板由边缘触发区弹出
                  _buildGestureLayer(controller,
                      webMode: controller.webPageActive),

                  // 网页前台播放时的双击全屏：JS 侧已屏蔽网页自身 dblclick，
                  // 这里接管为 App 窗口全屏切换（双击手势不吞单击，网页播放器
                  // 的单击暂停/播放不受影响）
                  if (controller.webPageActive &&
                      controller.webPageForeground &&
                      controller.isDesktop)
                    Positioned.fill(
                      child: _WebDoubleTapFullScreen(
                        onToggle: controller.toggleFullscreen,
                      ),
                    ),

                  // 左右边缘点击区（移动端；桌面端用 hover 自动弹出）
                  if (!controller.isDesktop) _buildEdgeTapZones(),

                  // 桌面端 hover 边缘自动弹出
                  if (controller.isDesktop) ...[
                    // 左边缘：不在 onExit 里启动隐藏计时——面板滑入会覆盖
                    // 这个 20px 触发区，触发区合成 onExit 与面板 onEnter 的
                    // 回调顺序若为「先入后出」，会把面板刚取消的隐藏定时器
                    // 重新启动，导致光标明明停在面板内、3 秒后仍自动关闭，
                    // 表现为顶部返回/关闭钮点不到。隐藏统一由面板自身
                    // onExit 负责。
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 20,
                      child: MouseRegion(
                        onEnter: (_) {
                          if (_leftDrawerOpen) {
                            _cancelDrawerHide();
                          } else {
                            _openDrawer(left: true);
                          }
                        },
                      ),
                    ),
                    // 右边缘
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      width: 20,
                      child: MouseRegion(
                        onEnter: (_) {
                          if (_rightEpgOpen) {
                            _cancelDrawerHide();
                          } else {
                            _openDrawer(left: false);
                          }
                        },
                      ),
                    ),
                    // 底部边缘
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 20,
                      child: MouseRegion(
                        onEnter: (_) => _showBottomPanel(),
                        onExit: (_) => _scheduleBottomHide(),
                      ),
                    ),
                  ],

                  // 底部信息/控制面板（hover 回调由面板内部 MouseRegion 处理，
                  // 不能在外面用 MouseRegion 包裹：根是 AnimatedPositioned 的
                  // 组件被其它 RenderObjectWidget 包裹会破坏 Stack parentData，
                  // release 下直接灰屏）
                  BottomProgramPanel(
                    isVisible: panelVisible,
                    onHoverEnter: _cancelBottomHide,
                    onHoverExit: _scheduleBottomHide,
                    onHoverMove: _cancelBottomHide,
                    onTogglePlayPause: controller.togglePlayPause,
                    onOpenChannels: () => _openDrawer(left: true),
                    onOpenEpg: () => _openDrawer(left: false),
                    onOpenSettings: _toggleSettings,
                    onScreenshot: _takeScreenshot,
                    onToggleRecord: () => _toggleRecording(controller),
                  ),

                  // 左侧频道抽屉
                  LeftChannelDrawer(
                    isOpen: _leftDrawerOpen,
                    onClose: () {
                      setState(() => _leftDrawerOpen = false);
                      WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _ensureShortcutFocus());
                    },
                    onHoverEnter: _cancelDrawerHide,
                    onHoverExit: _startDrawerHideTimer,
                    onHoverMove: _cancelDrawerHide,
                    onOpenSettings: () {
                      setState(() => _leftDrawerOpen = false);
                      _toggleSettings();
                    },
                  ),

                  // 右侧 EPG 面板
                  RightEpgPanel(
                    isOpen: _rightEpgOpen,
                    onClose: () {
                      setState(() => _rightEpgOpen = false);
                      WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _ensureShortcutFocus());
                    },
                    onHoverEnter: _cancelDrawerHide,
                    onHoverExit: _startDrawerHideTimer,
                    onHoverMove: _cancelDrawerHide,
                  ),

                  // 设置面板
                  SettingsPanel(
                    isOpen: _settingsOpen,
                    onClose: () {
                      setState(() => _settingsOpen = false);
                      // 关闭后恢复低级钩子对数字键的选台拦截
                      _winHotkeys.setCapture(true);
                      WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _ensureShortcutFocus());
                    },
                  ),

                  // 亮度调节指示
                  GestureIndicatorOverlay(
                    isVisible: _showBrightnessIndicator,
                    icon: Icons.brightness_6,
                    iconColor: Colors.amber,
                    value: controller.brightness,
                    label: '亮度 ${(controller.brightness * 100).round()}%',
                  ),

                  // 音量调节指示
                  GestureIndicatorOverlay(
                    isVisible: _showVolumeIndicator,
                    icon: controller.volume == 0
                        ? Icons.volume_off
                        : (controller.volume < 0.5
                            ? Icons.volume_down
                            : Icons.volume_up),
                    iconColor: Colors.blueAccent,
                    value: controller.volume,
                    label: '音量 ${(controller.volume * 100).round()}%',
                  ),

                  // 录制指示器（网页/原生均显示）
                  if (controller.isRecording)
                    Positioned(
                      top: 48,
                      left: 16,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            controller.webPageActive
                                ? 'REC · ${_formatBytes(controller.webRecordingBytes)}'
                                : 'REC',
                            style: const TextStyle(
                              color: Colors.red,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),

                  // 顶部悬停标题栏（桌面端，置于最顶层，
                  // 避免被右上角时钟/切台 OSD 遮挡导致点不到）
                  // 频道抽屉 / EPG / 设置打开时不显示，以免挡住它们
                  // 顶部的关闭、返回按钮
                  if (controller.isDesktop &&
                      !_leftDrawerOpen &&
                      !_rightEpgOpen &&
                      !_settingsOpen)
                    TopTitleBar(
                      visible: _topBarVisible,
                      onHide: () {
                        if (_topBarVisible) {
                          setState(() => _topBarVisible = false);
                        }
                      },
                    ),
                ],
              );
            },
          ),
        ),
      ),
        ),
        ),
      );
  }

  /// 安卓返回键/遥控器返回处理（PopScope 拦截后调用）：
  /// 按层级关闭 设置→投屏→面板→全屏；都没有时弹退出确认
  Future<void> _handleBackPressed() async {
    final c = context.read<PlayerController>();
    if (_settingsOpen) {
      setState(() => _settingsOpen = false);
      return;
    }
    if (c.isCasting) {
      // v1.0.98 已有的标准投屏停止/恢复逻辑
      await c.stopCastAndRestore();
      return;
    }
    if (_leftDrawerOpen) {
      setState(() => _leftDrawerOpen = false);
      return;
    }
    if (_rightEpgOpen) {
      setState(() => _rightEpgOpen = false);
      return;
    }
    if (c.isFullscreen) {
      c.exitFullscreenIfNeeded();
      return;
    }
    // 无任何可关闭项：退出前确认，避免误触
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('退出 OMPlayer'),
        content: const Text('确定要退出 OMPlayer 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (shouldExit == true) {
      await SystemNavigator.pop();
    }
  }

  // ==================== 硬件按键快捷键 ====================

  /// 全局硬件按键处理（注册在 HardwareKeyboard 上，不依赖焦点）。
  /// 返回 true 表示事件已消费，不再向焦点链传递。
  bool _onGlobalKeyEvent(KeyEvent event) {
    // 只处理首次按下；长按重复事件是 KeyRepeatEvent，天然被排除
    if (event is! KeyDownEvent) return false;
    // 设置面板里有输入框（URL、数字等）：所有按键放行
    if (_settingsOpen) return false;

    final k = event.logicalKey;
    final p = event.physicalKey;

    // 数字键（主键盘 / 小键盘）选台。
    // 同时按逻辑键与物理键（USB HID 码）匹配：
    // 物理键不受输入法/键盘布局影响，避免中文输入法下逻辑键
    // 映射异常导致数字选台失灵；安卓遥控器数字键也走小键盘码。
    for (var i = 0; i < 10; i++) {
      if (k == _digitKeys[i] ||
          k == _numpadKeys[i] ||
          p == _physDigitKeys[i] ||
          p == _physNumpadKeys[i]) {
        _onNumberKey(i);
        return true;
      }
    }

    if (k == LogicalKeyboardKey.escape) {
      context.read<PlayerController>().exitFullscreenIfNeeded();
      return true;
    }

    String? action;
    if (k == LogicalKeyboardKey.space) {
      action = 'playpause';
    } else if (k == LogicalKeyboardKey.keyF ||
        k == LogicalKeyboardKey.f11) {
      action = 'fullscreen';
    } else if (k == LogicalKeyboardKey.keyM) {
      action = 'mute';
    } else if (k == LogicalKeyboardKey.printScreen) {
      action = 'screenshot';
    } else if (k == LogicalKeyboardKey.keyC) {
      action = 'channels';
    } else if (k == LogicalKeyboardKey.keyE) {
      action = 'epg';
    } else if (k == LogicalKeyboardKey.keyS) {
      action = 'settings';
    } else if (k == LogicalKeyboardKey.keyR) {
      action = 'record';
    }
    if (action != null) {
      _onShortcut(action);
      return true;
    }

    if (k == LogicalKeyboardKey.arrowLeft) {
      _onArrow('prevSource');
      return true;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _onArrow('nextSource');
      return true;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _onArrow('prevChannel');
      return true;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _onArrow('nextChannel');
      return true;
    }

    return false;
  }

  // ==================== 边缘点击区 ====================

  Widget _buildEdgeTapZones() {
    // 移动端边缘热区：左右竖条点击开抽屉，底部横条点击呼出信息面板
    //（网页播放等面板自动隐藏后，底部始终有一个可以呼出的入口）
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: _edgeWidth.toDouble(),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _openDrawer(left: true),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: _edgeWidth.toDouble(),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _openDrawer(left: false),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 28,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _showBottomPanel,
            ),
          ),
        ],
      ),
    );
  }

  void _openDrawer({required bool left}) {
    setState(() {
      // 打开面板时隐藏悬停标题栏，避免遮挡面板顶部按钮
      _topBarVisible = false;
      if (left) {
        _leftDrawerOpen = true;
        _rightEpgOpen = false;
      } else {
        _rightEpgOpen = true;
        _leftDrawerOpen = false;
      }
    });
    _armDrawerAutoHide();
  }

  /// 快捷键用：再次按键时关闭对应面板
  void _toggleDrawer({required bool left}) {
    setState(() {
      _topBarVisible = false;
      if (left) {
        if (_leftDrawerOpen) {
          _leftDrawerOpen = false;
        } else {
          _leftDrawerOpen = true;
          _rightEpgOpen = false;
        }
      } else {
        if (_rightEpgOpen) {
          _rightEpgOpen = false;
        } else {
          _rightEpgOpen = true;
          _leftDrawerOpen = false;
        }
      }
    });
    _armDrawerAutoHide();
  }

  // ==================== 切台 OSD / 时钟 ====================

  Widget _buildChannelOsd(PlayerController controller) {
    final ch = controller.currentChannel;
    final program = controller.currentProgram?.title;
    final number = controller.currentChannelNumber;
    final showOsd = (_osdVisible && ch != null) || _numBuffer.isNotEmpty;
    final isPhone = defaultTargetPlatform == TargetPlatform.android &&
        MediaQuery.of(context).size.shortestSide < 600;
    return Positioned(
      top: 0,
      left: 0,
      child: AnimatedOpacity(
        opacity: showOsd ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 300),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(isPhone ? 12 : 24),
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: isPhone ? 14 : 20, vertical: isPhone ? 10 : 16),
              decoration: BoxDecoration(
                color: const Color(0xCC1A1A2E),
                borderRadius: BorderRadius.circular(isPhone ? 10 : 12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 第一行：大号数字 + 频道名
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        number != null ? number.toString().padLeft(2, '0') : '--',
                        style: const TextStyle(
                          color: Colors.blueAccent,
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                          height: 1,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        ch?.name ?? '',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  // 第二行：正在直播 + 当前节目
                  if (program != null && program.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '正在直播 · $program',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  // 数字选台输入提示
                  if (_numBuffer.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '输入: $_numBuffer',
                        style: const TextStyle(
                          color: Colors.blueAccent,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildClock() {
    return Positioned(
      top: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          // 与屏幕上边、右边保持约一行的距离（桌面无 SafeArea 边距，
          // 这里显式留白）
          padding: const EdgeInsets.only(top: 20, right: 28, bottom: 8),
          child: StreamBuilder<int>(
            stream: _clockStream,
            builder: (context, _) {
              final now = DateTime.now();
              return Text(
                DateFormat('HH:mm').format(now),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                  shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  static final Stream<int> _clockStream =
      Stream.periodic(const Duration(seconds: 1), (i) => i);

  // ==================== 手势层 ====================

  Widget _buildGestureLayer(PlayerController controller,
      {bool webMode = false}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Row(
          children: [
            // 左侧：亮度调节 + 左边缘滑出抽屉
            //（与 v1.0.98 一致：不设 onTap，避免与底部面板的按钮
            // 在手势竞技场竞争，导致面板上的按钮点不动）
            Expanded(
              child: GestureDetector(
                onVerticalDragStart: (details) {
                  _isHorizontalDrag = false;
                  _dragStartY = details.globalPosition.dy;
                  _dragStartX = details.globalPosition.dx;
                  _lastBrightness = controller.brightness;
                  setState(() => _showBrightnessIndicator = true);
                },
                onVerticalDragUpdate: (details) {
                  if (_isHorizontalDrag || _dragStartY == null) return;
                  final dy = _dragStartY! - details.globalPosition.dy;
                  controller.setBrightness(
                      _lastBrightness + dy * _dragSensitivity);
                },
                onVerticalDragEnd: (_) => _onBrightnessDragEnd(),
                onHorizontalDragStart: (details) {
                  _isHorizontalDrag = true;
                  _dragStartX = details.globalPosition.dx;
                },
                onHorizontalDragEnd: (details) {
                  if (_dragStartX != null &&
                      _dragStartX! <= _edgeWidth &&
                      details.velocity.pixelsPerSecond.dx > 100) {
                    _openDrawer(left: true);
                  }
                },
              ),
            ),
            // 中间：点击切换面板，双击播放暂停（桌面端双击全屏，按住拖动窗口）。
            // 网页模式：桌面端完全穿透（点击/滑动全交给网页，面板由边缘
            // hover 与底部点击区触发，双击全屏由 _WebDoubleTapFullScreen 接管）；
            // 移动端保留点击呼出信息面板
            Expanded(
              child: webMode
                  ? (controller.isDesktop
                      ? const SizedBox.expand()
                      : GestureDetector(onTap: _toggleBottomPanel))
                  : GestureDetector(
                      onTap: _toggleBottomPanel,
                      onDoubleTap: controller.isDesktop
                          ? controller.toggleFullscreen
                          : controller.togglePlayPause,
                      // 全屏状态下绝不能拖动窗口，否则窗口会掉到最底层、点击穿透
                      onPanStart:
                          (controller.isDesktop && !controller.isFullscreen)
                              ? (_) => startWindowDrag()
                              : null,
                    ),
            ),
            // 右侧：音量调节 + 右边缘滑出 EPG（与 v1.0.98 一致：不设 onTap）
            Expanded(
              child: GestureDetector(
                onVerticalDragStart: (details) {
                  _isHorizontalDrag = false;
                  _dragStartY = details.globalPosition.dy;
                  _lastVolume = controller.volume;
                  setState(() => _showVolumeIndicator = true);
                },
                onVerticalDragUpdate: (details) {
                  if (_isHorizontalDrag || _dragStartY == null) return;
                  final dy = _dragStartY! - details.globalPosition.dy;
                  controller.setVolume(_lastVolume + dy * _dragSensitivity);
                },
                onVerticalDragEnd: (_) => _onVolumeDragEnd(),
                onHorizontalDragStart: (details) {
                  _isHorizontalDrag = true;
                  _dragStartX = details.globalPosition.dx;
                },
                onHorizontalDragEnd: (details) {
                  if (_dragStartX != null &&
                      _dragStartX! >= width - _edgeWidth &&
                      details.velocity.pixelsPerSecond.dx < -100) {
                    _openDrawer(left: false);
                  }
                },
              ),
            ),
          ],
        );
      },
    );
  }

  void _onBrightnessDragEnd() {
    _dragStartY = null;
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showBrightnessIndicator = false);
    });
  }

  void _onVolumeDragEnd() {
    _dragStartY = null;
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showVolumeIndicator = false);
    });
  }

  // ==================== 面板控制 ====================

  void _toggleBottomPanel() {
    final c = context.read<PlayerController>();
    // 网页模式下没有原生播放状态（_state 通常仍是 loading），
    // 不能用 state==playing 拦截，否则左右点击永远呼不出面板
    if (!c.webPageActive && c.state != PlayerState.playing) return;
    setState(() {
      _bottomPanelVisible = !_bottomPanelVisible;
      if (_bottomPanelVisible) {
        _scheduleBottomHide();
      }
    });
  }

  void _toggleSettings() {
    setState(() {
      _settingsOpen = !_settingsOpen;
      // 打开设置时隐藏悬停标题栏
      if (_settingsOpen) _topBarVisible = false;
    });
    // 设置面板有输入框：打开时放行数字键给输入框，关闭后恢复选台拦截
    _winHotkeys.setCapture(!_settingsOpen);
  }

  /// 桌面端快捷键：空格 播放/暂停，F/F11 全屏，M 静音，
  /// PrintScreen 截屏，C 频道列表开/关，E 节目单开/关，S 设置，R 录制
  void _onShortcut(String action) {
    if (_settingsOpen && action != 'settings') return;
    final controller = context.read<PlayerController>();
    switch (action) {
      case 'channels':
        _toggleDrawer(left: true);
      case 'epg':
        _toggleDrawer(left: false);
      case 'settings':
        _toggleSettings();
      case 'record':
        _toggleRecording(controller);
      case 'playpause':
        controller.togglePlayPause();
      case 'fullscreen':
        controller.toggleFullscreen();
      case 'mute':
        controller.toggleMute();
      case 'screenshot':
        _takeScreenshot();
    }
  }

  /// 方向键：←/→ 切换播放源，↑/↓ 切换频道
  void _onArrow(String action) {
    if (_settingsOpen || _leftDrawerOpen || _rightEpgOpen) return;
    final controller = context.read<PlayerController>();
    switch (action) {
      case 'prevSource':
        controller.prevSource();
      case 'nextSource':
        controller.nextSource();
      case 'prevChannel':
        controller.previousChannel();
      case 'nextChannel':
        controller.nextChannel();
    }
  }

  /// 原生钩子转发的动作键（网页持有焦点时 HardwareKeyboard 收不到，
  /// 由 WH_KEYBOARD_LL 经 omplayer/win_hotkeys 通道送达）
  void _onNativeAction(String action) {
    if (!mounted || _settingsOpen) return;
    final controller = context.read<PlayerController>();
    switch (action) {
      case 'space':
        controller.togglePlayPause();
      case 'left':
        _onArrow('prevSource');
      case 'right':
        _onArrow('nextSource');
      case 'up':
        _onArrow('prevChannel');
      case 'down':
        _onArrow('nextChannel');
      case 'esc':
        controller.exitFullscreenIfNeeded();
      case 'm':
        _onShortcut('mute');
      case 'f':
        _onShortcut('fullscreen');
      case 'r':
        _onShortcut('record');
      case 'c':
        _onShortcut('channels');
      case 'e':
        _onShortcut('epg');
      case 's':
        _onShortcut('settings');
    }
  }

  Future<void> _takeScreenshot() async {
    final controller = context.read<PlayerController>();
    final path = await controller.takeScreenshot();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(path != null ? '截图已保存: $path' : '截图失败'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _toggleRecording(PlayerController controller) async {
    if (!controller.isDesktop) return;
    if (controller.isRecording) {
      final path = await controller.stopRecording();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(path != null
                ? '录制已停止，保存至: $path'
                : '录制已停止（未捕获到视频数据）'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } else {
      final ok = await controller.startRecording();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok
                ? (controller.webPageActive
                    ? '开始录制网页视频，保存到程序所在文件夹的 recordings 子文件夹'
                    : '开始录制，视频保存到程序所在文件夹的 recordings 子文件夹')
                : (controller.lastError ?? '录制失败')),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// 录制指示器的字节数格式化（网页录制显示实时落盘大小）
  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
  }

  /// 底部面板 hover 取消隐藏
  void _cancelBottomHide() {
    _bottomHideTimer?.cancel();
    // 避免鼠标每次移动都触发重建
    if (!_bottomHovering && mounted) {
      setState(() => _bottomHovering = true);
    }
  }

  /// 底部面板 hover 离开后启动隐藏计时
  void _scheduleBottomHide() {
    setState(() => _bottomHovering = false);
    _bottomHideTimer?.cancel();
    final delay =
        context.read<PlayerController>().settings.autoHideDelay;
    _bottomHideTimer = Timer(Duration(milliseconds: delay), () {
      if (mounted && !_bottomHovering) {
        setState(() => _bottomPanelVisible = false);
      }
    });
  }

  /// 桌面端 hover 到底部边缘时显示面板
  void _showBottomPanel() {
    setState(() => _bottomPanelVisible = true);
    _bottomHideTimer?.cancel();
  }

  /// 抽屉 hover 移出后 3 秒自动隐藏
  void _startDrawerHideTimer() {
    _drawerHideTimer?.cancel();
    _drawerHideTimer = Timer(_drawerAutoHide, () {
      if (mounted) {
        setState(() {
          _leftDrawerOpen = false;
          _rightEpgOpen = false;
        });
        _ensureShortcutFocus();
      }
    });
  }
}

/// 网页频道前台的双击全屏层。
/// 用 Listener（透明命中，不参与手势竞技场）手动识别双击：单击指针
/// 事件原样穿透给下方的 WebView（不影响网页播放器的单击暂停/播放），
/// 只在 300ms 内两次相邻点按时触发 [onToggle] 切换 App 窗口全屏。
class _WebDoubleTapFullScreen extends StatefulWidget {
  final VoidCallback onToggle;
  const _WebDoubleTapFullScreen({required this.onToggle});

  @override
  State<_WebDoubleTapFullScreen> createState() =>
      _WebDoubleTapFullScreenState();
}

class _WebDoubleTapFullScreenState extends State<_WebDoubleTapFullScreen> {
  DateTime? _lastTap;
  Offset _lastPos = Offset.zero;

  void _onDown(PointerDownEvent e) {
    final now = DateTime.now();
    final last = _lastTap;
    if (last != null &&
        now.difference(last).inMilliseconds <= 300 &&
        (e.position - _lastPos).distance < 40) {
      _lastTap = null;
      widget.onToggle();
      return;
    }
    _lastTap = now;
    _lastPos = e.position;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      child: const SizedBox.expand(),
    );
  }
}


/// 内嵌网页频道控件：充满整个窗口，由网站自身播放器播放
/// （如央视频网页版）。网页先在【后台】加载缓冲（被 PlayerScreen 的
/// 黑屏占位盖住），JS 探测到视频有声起播后通过 [onForeground] 通知
/// 父层把网页推到全屏前台；信息面板/节目单/EPG 抽屉由 PlayerScreen
/// 叠加在本控件之上。退出网页请从左侧频道列表选普通频道。
class _WebChannelOverlay extends StatefulWidget {
  final String url;

  /// 网页是否已处于前台播放（false=后台缓冲，被黑屏占位覆盖）
  final bool foreground;

  /// 探测到有声起播，请求父层把网页推到前台
  final VoidCallback onForeground;

  /// 网页内按键（焦点在 WebView 中时 Flutter 收不到键盘消息，
  /// 由 JS 转发）：'d0'..'d9' 数字选台，'fullscreen' 全屏切换
  final ValueChanged<String> onWebKey;

  /// 网页播放/暂停状态变化（底部面板按钮图标）
  final ValueChanged<bool> onPlayStateChanged;

  /// 网页内鼠标移动（自动隐藏/呼出系统鼠标）
  final VoidCallback onWebMouseMove;

  /// WebView 创建后注册控制桥（执行 JS / 截图）
  final void Function({
    required Future<dynamic> Function(String) eval,
    required Future<List<int>?> Function() screenshot,
  }) onBridgeAttached;

  /// WebView 销毁前注销控制桥
  final VoidCallback onBridgeDetached;

  const _WebChannelOverlay({
    super.key,
    required this.url,
    required this.foreground,
    required this.onForeground,
    required this.onWebKey,
    required this.onPlayStateChanged,
    required this.onWebMouseMove,
    required this.onBridgeAttached,
    required this.onBridgeDetached,
  });

  @override
  State<_WebChannelOverlay> createState() => _WebChannelOverlayState();
}

class _WebChannelOverlayState extends State<_WebChannelOverlay> {
  bool _loaded = false;
  String? _error;
  bool _runtimeMissing = false;
  /// WebView 是否报告过任何加载进度（有进度即证明 WebView2 运行时正常）
  bool _sawProgress = false;
  InAppWebViewController? _webController;

  /// 后台缓冲期间每秒探测一次页面 <video> 的真实起播状态
  Timer? _probeTimer;

  /// 超时兜底：网站不允许自动播放（需用户手动点播放按钮）时，
  /// 不能永远黑屏把用户卡死——8 秒后强制把网页推到前台，
  /// JS 会继续尝试自动播放，用户也可手动点击页面播放器
  Timer? _forceForegroundTimer;

  /// 15 秒内 WebView 毫无加载进度：判定为缺少 WebView2 运行时
  Timer? _runtimeTimer;

  /// CSS：把页面里的 <video> 伪全屏铺满窗口
  static const String _cssJs = r'''
(function(){
  var CSS_TEXT = 'html,body{margin:0!important;padding:0!important;background:#000!important;overflow:hidden!important;height:100%!important;width:100%!important}'
      + '*{-webkit-user-select:none!important;user-select:none!important}'
      + 'input,textarea{-webkit-user-select:text!important;user-select:text!important}'
      + 'video{position:fixed!important;top:0!important;left:0!important;width:100vw!important;height:100vh!important;object-fit:contain!important;z-index:2147483647!important;background:#000!important;outline:none!important}'
      + 'html.__om_hide_cursor,html.__om_hide_cursor *{cursor:none!important}'
      + '#__om_web_layer{position:fixed!important;inset:0!important;background:#000!important;z-index:2147483646!important}';
  function inject(d){
    try {
      if (!d || !d.head) return;
      var old = d.getElementById('__om_fullscreen_style');
      if (old) return;
      var s = d.createElement('style');
      s.id = '__om_fullscreen_style';
      s.textContent = CSS_TEXT;
      d.head.appendChild(s);
    } catch(e) {}
  }
  function walk(root){
    inject(root);
    try {
      var frames = root.querySelectorAll('iframe');
      for (var i=0;i<frames.length;i++){
        try { var d = frames[i].contentDocument; if (d) walk(d); } catch(e) {}
      }
    } catch(e) {}
  }
  walk(document);
  window.__omCssText = CSS_TEXT;
})();
''';

  /// 常驻注入：强制解除静音/调大音量/拉起播放，探测起播；
  /// 转发鼠标移动 / 数字键与全屏键 / play-pause 状态到 Dart；
  /// 屏蔽网页自身双击全屏（由 Flutter 统一处理）。
  /// 央视频等站点的播放器可能位于同源 iframe 内，需要递归遍历。
  static const String _bootJs = r'''
(function(){
  if (window.__omBooted) return;
  window.__omBooted = true;
  function fire(name, arg){
    try { window.flutter_inappwebview.callHandler(name, arg); } catch(e) {}
  }
  // 修复 iframe 自动播放：给所有 iframe 加 allow="autoplay"
  function fixIframes(doc){
    try {
      var frames = doc.querySelectorAll('iframe');
      for (var i=0;i<frames.length;i++){
        var f = frames[i];
        var allow = f.getAttribute('allow') || '';
        if (allow.indexOf('autoplay') === -1) {
          f.setAttribute('allow', (allow ? allow + '; ' : '') + 'autoplay; fullscreen; encrypted-media');
        }
      }
    } catch(e) {}
  }
  setInterval(function(){ fixIframes(document); }, 1000);
  fixIframes(document);
  // 网页自己的双击全屏与 App 窗口全屏冲突，屏蔽之
  document.addEventListener('dblclick', function(e){
    e.stopPropagation(); e.preventDefault();
  }, true);

  // ===== 鼠标 / 键盘 桥接（含同源 iframe）=====
  var hideCursorTimer = null;
  var cursorHidden = false;
  var hookedDocs = [];
  function allElsCursor(h, doc){
    try {
      doc.documentElement.style.cursor = h ? 'none' : '';
      var vids = doc.querySelectorAll('video');
      for (var i=0;i<vids.length;i++) vids[i].style.cursor = h ? 'none' : '';
    } catch(e){}
  }
  function setCursorHidden(h){
    cursorHidden = h;
    for (var i=0;i<hookedDocs.length;i++){
      try {
        var root = hookedDocs[i].documentElement;
        if (h) root.classList.add('__om_hide_cursor');
        else root.classList.remove('__om_hide_cursor');
        allElsCursor(h, hookedDocs[i]);
      } catch(e){}
    }
  }
  setInterval(function(){
    if (cursorHidden) {
      for (var i=0;i<hookedDocs.length;i++){
        try {
          var root = hookedDocs[i].documentElement;
          if (!root.classList.contains('__om_hide_cursor'))
            root.classList.add('__om_hide_cursor');
          allElsCursor(true, hookedDocs[i]);
        } catch(e){}
      }
    }
  }, 500);
  function showCursor(){
    setCursorHidden(false);
    if (hideCursorTimer) clearTimeout(hideCursorTimer);
    hideCursorTimer = setTimeout(function(){ setCursorHidden(true); }, 3000);
  }
  // 暴露给 Dart 侧：数字键切频道等 Flutter 侧交互时调用，
  // 否则网页收不到事件，光标不会自动隐藏
  window.__omShowCursor = showCursor;
  // 暴露给 Dart 侧：网络断开/恢复时暂停/继续网页播放
  window.__omPause = function(){
    window.__omUserPaused = true;
    var vs = allVideos(document);
    for (var i=0;i<vs.length;i++){ try { vs[i].pause(); } catch(e){} }
  };
  window.__omResume = function(){
    window.__omUserPaused = false;
    kick();
  };
  var lastMM = 0;
  function onMouseMove(){
    var n = Date.now();
    if (n - lastMM < 300) return;
    lastMM = n;
    showCursor();
    fire('omMouse');
  }
  // 点击后也要重置隐藏定时器，否则点完不挪鼠标就不会自动隐藏
  function onMouseActivity(){
    showCursor();
  }
  function onKeyDown(e){
    var t = e.target;
    if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA'
        || t.isContentEditable)) return;
    var k = e.key;
    if (k >= '0' && k <= '9') {
      fire('omKey', 'd' + k);
      e.preventDefault();
    } else if (k === 'F11' || k === 'f' || k === 'F') {
      fire('omKey', 'fullscreen');
      e.preventDefault();
    } else if (k === 'Escape') {
      fire('omKey', 'exitfullscreen');
    }
  }
  function hookDoc(d){
    if (!d || d.__omHooked) return;
    d.__omHooked = true;
    hookedDocs.push(d);
    d.addEventListener('mousemove', onMouseMove, true);
    d.addEventListener('mousedown', onMouseActivity, true);
    d.addEventListener('click', onMouseActivity, true);
    d.addEventListener('keydown', onKeyDown, true);
    try {
      var ss = d.createElement('style');
      ss.textContent = 'html.__om_hide_cursor,html.__om_hide_cursor *{cursor:none!important}';
      (d.head || d.documentElement).appendChild(ss);
    } catch(e){}
  }
  hookDoc(document);
  showCursor();

  function eachFrameDoc(root, fn){
    var frames = root.querySelectorAll('iframe');
    for (var i=0;i<frames.length;i++){
      try {
        var d = frames[i].contentDocument;
        if (d) { hookDoc(d); fn(d); eachFrameDoc(d, fn); }
      } catch(e) {}
    }
  }

  function allVideos(root){
    var out = Array.prototype.slice.call(root.querySelectorAll('video'));
    eachFrameDoc(document, function(d){
      out = out.concat(Array.prototype.slice.call(d.querySelectorAll('video')));
    });
    return out;
  }
  var clickCooldown = 0;
  var videoClickCooldown = 0;
  function collectAll(root, sels, out){
    for (var s=0;s<sels.length;s++){
      try {
        var found = root.querySelectorAll(sels[s]);
        for (var i=0;i<found.length;i++) out.push(found[i]);
      } catch(e){}
    }
    var frames = root.querySelectorAll('iframe');
    for (var i=0;i<frames.length;i++){
      try {
        var d = frames[i].contentDocument;
        if (d) collectAll(d, sels, out);
      } catch(e){}
    }
  }
  function clickBigPlayButton(){
    var sels = [
      '.vjs-big-play-button','.vjs-poster',
      '.xgplayer-start','.xgplayer-start-button','.xgplayer-poster',
      '.prism-player .vjs-big-play-button','.vcp-bigplay',
      '.dplayer-play-icon','.art-play-btn','.art-video-poster',
      '.tvplayer-play','.player-start-btn','.tv-player-start',
      '[class*="big-play"]','[class*="bigPlay"]','[class*="start-button"]',
      '[class*="player-start"]','[class*="cover-play"]','[class*="video-cover"]',
      '[class*="poster"]'
    ];
    var els = [];
    collectAll(document, sels, els);
    for (var i=0;i<els.length;i++){
      var b = els[i];
      var cls = (b.className && b.className.toString) ? b.className.toString() : '';
      if (/control|bar|small/i.test(cls)) continue;
      var r;
      try { r = b.getBoundingClientRect(); } catch(e) { continue; }
      if (r.width >= 48 && r.height >= 48) {
        try { b.click(); } catch(e) {}
        clickCooldown = 3;
        return true;
      }
    }
    return false;
  }
  var pausedTicks = 0;
  var lastUrl = location.href;
  function bindMedia(v){
    if (v.__omMediaBound) return;
    v.__omMediaBound = true;
    v.addEventListener('play', function(){ fire('omPlay', 1); });
    v.addEventListener('pause', function(){ fire('omPlay', 0); });
  }
  function kick(){
    if (location.href !== lastUrl) {
      lastUrl = location.href;
      window.__omUserPaused = false;
    }
    var vs = allVideos(document);
    var up = !!window.__omUserPaused;
    var anyPaused = false;
    var anyPlaying = false;
    for (var i=0;i<vs.length;i++){
      var v = vs[i];
      try {
        bindMedia(v);
        try { v.removeAttribute('muted'); } catch(e) {}
        v.muted = false;
        var wv = window.__omVol;
        v.volume = (typeof wv === 'number') ? wv : 1;
        if (!v.paused) anyPlaying = true;
        if (!up && v.paused && v.play) {
          anyPaused = true;
          var p = v.play();
          if (p && p.catch) p.catch(function(){});
        }
      } catch(e) {}
      if (!window.__omPlayingFired && !v.paused && v.readyState >= 2
          && v.currentTime > 0) {
        window.__omPlayingFired = true;
        fire('omPlaying');
      }
    }
    var st = anyPlaying ? 1 : 0;
    if (st !== window.__omLastReported) {
      window.__omLastReported = st;
      fire('omPlay', st);
    }
    if (anyPaused && !up) {
      pausedTicks++;
      if (clickCooldown > 0) { clickCooldown--; }
      else if (pausedTicks >= 2) {
        if (clickBigPlayButton()) return;
      }
      if (videoClickCooldown > 0) { videoClickCooldown--; }
      else if (pausedTicks >= 6) {
        for (var j=0;j<vs.length;j++){
          try { if (vs[j].paused) vs[j].click(); } catch(e){}
        }
        videoClickCooldown = 5;
      }
    } else {
      pausedTicks = 0;
    }
  }
  setInterval(kick, 700);
  kick();
})();
''';

  /// Dart 侧轮询探测（不依赖 JS bridge 是否可用，双保险）。
  /// 递归同源 iframe；只认可见面积最大的主视频（隐藏预览/广告播放器
  /// 会导致"主视频没播却被判定已起播"）；返回数字 1/0，规避字符串编解码差异。
  static const String _probeJs = r'''
(function(){
  function allVideos(root){
    var out = Array.prototype.slice.call(root.querySelectorAll('video'));
    var frames = root.querySelectorAll('iframe');
    for (var i=0;i<frames.length;i++){
      try {
        var d = frames[i].contentDocument;
        if (d) out = out.concat(allVideos(d));
      } catch(e) {}
    }
    return out;
  }
  var vs = allVideos(document);
  var best = null, bestA = 0;
  for (var i=0;i<vs.length;i++){
    var r;
    try { r = vs[i].getBoundingClientRect(); } catch(e) { continue; }
    var a = (r.width >= 80 && r.height >= 60) ? r.width * r.height : 0;
    if (a > bestA) { bestA = a; best = vs[i]; }
  }
  if (!best) return 0;
  try {
    if (best.paused && best.play) { var p = best.play(); if (p && p.catch) p.catch(function(){}); }
    if (!best.paused && best.readyState >= 2 && best.currentTime > 0) return 1;
  } catch(e) {}
  return 0;
})();
''';

  @override
  void initState() {
    super.initState();
    // 每次打开网页频道前清理 WebView2 缓存，避免旧频道的 Service Worker
    // 或残留状态导致新频道黑屏/长时间不播放
    cleanWebView2Cache();
    // 后台缓冲期间持续探测，起播即推前台
    _probeTimer = Timer.periodic(const Duration(seconds: 1), (_) => _probe());
    // 8 秒仍未自动起播：强制推前台，避免永久黑屏
    _forceForegroundTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && !widget.foreground) widget.onForeground();
    });
    // 运行时缺失判定（乐观策略）：注册表/版本查询在不同系统上都不可靠
    // （实测已装 WebView2 的家庭版也会误报）。只要 WebView 能报告任何
    // 加载进度，就证明运行时正常；15 秒内毫无进展才提示安装。
    _runtimeTimer = Timer(const Duration(seconds: 15), () {
      if (mounted && !_sawProgress && _error == null) {
        setState(() => _runtimeMissing = true);
      }
    });
  }

  @override
  void dispose() {
    widget.onBridgeDetached();
    _probeTimer?.cancel();
    _forceForegroundTimer?.cancel();
    _runtimeTimer?.cancel();
    super.dispose();
  }

  Future<void> _inject() async {
    final c = _webController;
    if (c == null) return;
    try {
      await c.evaluateJavascript(source: _cssJs);
      await c.evaluateJavascript(source: _bootJs);
    } catch (_) {
      // 页面尚未就绪时注入可能失败，轮询探测会在后续重试
    }
  }

  Future<void> _probe() async {
    if (!mounted || widget.foreground) return;
    final c = _webController;
    if (c == null) return;
    // 每次探测顺带确保全屏样式/静音状态（SPA 页面可能被站点脚本改写）
    try {
      await c.evaluateJavascript(source: _cssJs);
      final r = await c.evaluateJavascript(source: _probeJs);
      // WebView2 JSON 解码后通常是 int 1，兼容字符串 "1"
      final playing = r == 1 || r?.toString() == '1';
      if (playing && mounted && !widget.foreground) {
        widget.onForeground();
      }
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant _WebChannelOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 已推到前台（探测成功或超时兜底）后不再需要超时定时器
    if (widget.foreground && !oldWidget.foreground) {
      _forceForegroundTimer?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        InAppWebView(
          webViewEnvironment: webViewEnvironment,
          initialUrlRequest: URLRequest(url: WebUri(widget.url)),
          initialSettings: InAppWebViewSettings(
            // 网页播放器（如央视频）自动开播，无需用户先点击网页
            mediaPlaybackRequiresUserGesture: false,
            supportZoom: false,
            transparentBackground: false,
            cacheMode: CacheMode.LOAD_DEFAULT,
            // 允许 iframe 内的视频自动播放（央视频播放器在 iframe 内）
            iframeAllow: "autoplay; fullscreen; encrypted-media",
            iframeAllowFullscreen: true,
            // 伪装桌面 Chrome，避免安卓 WebView 被网站检测到移动端
            // 而重定向到“下载 App”页
            userAgent:
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          ),
          onWebViewCreated: (controller) async {
            _webController = controller;
            // 把 controller 存到 PlayerController，供 Dart 侧调用网页 JS
            context.read<PlayerController>().webController = controller;
            // JS bridge 通道
            controller.addJavaScriptHandler(
              handlerName: 'omPlaying',
              callback: (_) {
                if (mounted && !widget.foreground) widget.onForeground();
              },
            );
            controller.addJavaScriptHandler(
              handlerName: 'omKey',
              callback: (args) {
                if (args.isNotEmpty) {
                  widget.onWebKey(args.first.toString());
                }
              },
            );
            controller.addJavaScriptHandler(
              handlerName: 'omMouse',
              callback: (_) => widget.onWebMouseMove(),
            );
            controller.addJavaScriptHandler(
              handlerName: 'omPlay',
              callback: (args) {
                if (args.isNotEmpty) {
                  widget.onPlayStateChanged(
                      args.first.toString() == '1' ||
                          args.first.toString() == '1.0');
                }
              },
            );
            // 网页录制：MediaRecorder 分块（base64）与结束通知
            controller.addJavaScriptHandler(
              handlerName: 'omRecChunk',
              callback: (args) {
                if (args.isNotEmpty) {
                  context
                      .read<PlayerController>()
                      .appendWebRecordingChunk(args.first.toString());
                }
                return null;
              },
            );
            controller.addJavaScriptHandler(
              handlerName: 'omRecEnd',
              callback: (args) {
                context.read<PlayerController>().finishWebRecording();
                return null;
              },
            );
            // 注册控制桥：执行 JS（播放/暂停）与网页截图
            widget.onBridgeAttached(
              eval: (js) => controller.evaluateJavascript(source: js),
              screenshot: () async => await controller.takeScreenshot(),
            );
          },
          onLoadStop: (controller, _) async {
            _sawProgress = true;
            if (mounted) setState(() => _loaded = true);
            await _inject();
          },
          // 页面开始渲染时立即注入 CSS，避免白屏闪现
          onPageCommitVisible: (controller, _) async {
            try {
              await controller.evaluateJavascript(source: _cssJs);
            } catch (_) {}
          },
          onProgressChanged: (controller, progress) {
            // 能收到任何进度都说明 WebView2 运行时工作正常
            if (progress > 0) _sawProgress = true;
            // 部分页面 onLoadStop 触发较晚，加载完成即收起等待层
            if (progress >= 100 && mounted && !_loaded) {
              setState(() => _loaded = true);
            }
          },
          onReceivedError: (controller, request, error) {
            // 主文档加载失败才提示（子资源失败不影响播放）
            if (request.isForMainFrame ?? false) {
              if (mounted) {
                setState(() => _error = error.description);
              }
            }
          },
        ),
        // 等待层：仅后台缓冲期间显示（推到前台后即使页面慢也露出来，
        // 避免「正在打开网页频道」永久转圈把用户锁死）
        if (!_loaded && _error == null && !_runtimeMissing && !widget.foreground)
          const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('正在打开网页频道...',
                    style: TextStyle(color: Colors.white70)),
              ],
            ),
          ),
        if (_error != null && !_runtimeMissing)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.link_off, color: Colors.white54, size: 40),
                const SizedBox(height: 8),
                Text('网页打开失败：$_error',
                    style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
        // 未安装/版本过旧的 WebView2 运行时（部分 Win10 家庭版）
        if (_runtimeMissing)
          Center(
            child: Container(
              margin: const EdgeInsets.all(24),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.8),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.web_asset,
                      color: Colors.amber, size: 40),
                  const SizedBox(height: 12),
                  const Text(
                    '未检测到 WebView2 运行环境\n网页频道需要 Microsoft Edge WebView2 Runtime',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  const SizedBox(height: 14),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('下载并安装 WebView2'),
                    onPressed: () => launchExternal(
                        'https://developer.microsoft.com/microsoft-edge/webview2/'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
