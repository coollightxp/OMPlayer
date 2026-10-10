import 'dart:async';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../services/osd_bus.dart';
import '../services/player_controller.dart';
import '../services/system_power.dart';
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

  // 遥控器/键盘长按检测：OK 短按与长按区分；左右键短按切源、长按拖进度。
  // 部分平台按住时重复发 KeyDownEvent 而非 KeyRepeatEvent，
  // 用 _okHeld/_arrowDown 去重，避免长按计时被反复重置
  // （注意：布尔状态名不能与边沿回调方法 _okDown() 同名）
  Timer? _okLongTimer;
  bool _okHeld = false;

  /// OK 按下边沿发生在面板打开期间：抬起时仍需走面板路径，
  /// 不能落入「面板外短按」（播放/暂停、重开频道列表）
  bool _okDownInPanel = false;
  bool _okLongFired = false;
  Timer? _arrowLongTimer;
  bool _arrowDown = false;
  bool _arrowLongFired = false;

  // 菜单键：短按=EPG 节目单，长按=设置面板
  Timer? _menuLongTimer;
  bool _menuHeld = false;
  bool _menuLongFired = false;

  // 点播点按左右键：屏幕中央数字进度 OSD（不弹控制面板，避免面板打开后
  // 左右键被按钮导航接管、与连续 seek 冲突）
  Timer? _seekOsdHideTimer;
  bool _seekOsdVisible = false;
  bool _seekOsdForward = true;
  Duration _seekOsdTarget = Duration.zero;
  Duration _seekOsdDuration = Duration.zero;

  // 播放加载防抖：按下键到内核真正初始化完成期间，遥控器连按的
  // 切台/切源/面板 OK 全部排队忽略，防止"往下按了一下、松手后才加载完、
  // 补按的 OK 直接落到停在很后面的频道"这类竞态（fvp 每次重建播放器
  // 会回收原 controller 重建，窗口越大用户越容易感到「按了没反应」）
  DateTime _loadingLockUntil = DateTime.fromMillisecondsSinceEpoch(0);
  static const _loadingLock = Duration(milliseconds: 900);

  // 屏幕中央消息 OSD：替代页面底部 SnackBar（电视远距离看不清底部小字，
  // 中央半透明大卡片更醒目）。新消息刷新文字并重新计时。
  Timer? _msgOsdTimer;
  bool _msgOsdVisible = false;
  String _msgOsdText = '';
  IconData _msgOsdIcon = Icons.info_outline;

  // 退出确认面板展示的应用版本（与 pubspec.yaml version 前半保持一致）
  static const String _appVersion = '1.0.147';

  // 退出确认对话框的遥控器友好句柄：左右键移动焦点，OK 确认当前按钮
  int _exitDialogFocusIndex = 0; // 0=取消, 1=退出, 2=关机
  bool _exitDialogOpen = false;

  /// 对话框内部 StatefulBuilder 的刷新句柄：遥控器 ←/→ 改焦点后
  /// 通过它只重建对话框（外层 setState 不会触发 showDialog 内容重建）
  StateSetter? _exitDialogRefresh;

  // 两个侧边面板的状态句柄：遥控器/键盘导航由本页统一分发
  // （HardwareKeyboard 与 Windows 低级钩子走同一入口）
  final GlobalKey<LeftChannelDrawerState> _leftDrawerKey = GlobalKey();
  final GlobalKey<RightEpgPanelState> _rightEpgKey = GlobalKey();
  final GlobalKey<BottomProgramPanelState> _bottomPanelKey = GlobalKey();

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
    // 深层 widget（设置/EPG 面板）发来的中央 OSD 消息
    OsdBus.message.addListener(_onBusOsd);
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
      // 释放 WebView2 环境及其宿主子进程，避免退出后残留
      // WebView2 进程继续解码占用资源（Win10 家庭版报"已停止工作"）
      try {
        await webViewEnvironment?.dispose();
      } catch (_) {}
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {
      try {
        await webViewEnvironment?.dispose();
      } catch (_) {}
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
    _okLongTimer?.cancel();
    _arrowLongTimer?.cancel();
    _menuLongTimer?.cancel();
    _seekOsdHideTimer?.cancel();
    _msgOsdTimer?.cancel();
    OsdBus.message.removeListener(_onBusOsd);
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
              // 信息面板显隐完全由 _bottomPanelVisible 控制：
              // 用户主动呼出（长按 OK / 鼠标 hover）或底部边缘 hover 打开；
              // 不再因 buffering/loading 强制显示——这会让 _bottomPanelActive
              // 判断与视觉不同步，导致遥控器左右键被 seek 逻辑接管而面板
              // 按钮收不到焦点，返回键也关不掉面板
              final panelVisible = _bottomPanelVisible;
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
                                          const Text(
                                              '网页频道缓冲中，起播后自动切换...',
                                              style: TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 14)),
                                        ],
                                      ),
                                    ),
                                  )
                                : const SizedBox.shrink()),
                  ),

                  // 亮度说明：不再使用全屏遮罩——它与 ScreenBrightness 的
  // 原生亮度调节重复，且会让视频画面常驻一层灰蒙蒙；桌面（gamma ramp）与
  // 安卓（系统亮度）统一走原生亮度，网页频道同理。

                  // 切台 OSD（左上角序号/台名/节目名）
                  // 放在手势层与各面板【之下】：面板滑出时盖住它，
                  // 避免 OSD 卡片挡住频道面板顶部的返回按钮
                  _buildChannelOsd(controller),

                  // 右上角系统时间：独立自治，切换不重建整棵 Stack
                  const ClockOverlay(),

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
                    key: _bottomPanelKey,
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
                    onOpenRemoteAdmin:
                        controller.remoteAdminUrl.isEmpty
                            ? null
                            : () => _showRemoteAdminQr(controller),
                    onDismissRemote: () {
                      if (_bottomPanelVisible) {
                        setState(() => _bottomPanelVisible = false);
                      }
                      _bottomHideTimer?.cancel();
                    },
                  ),

                  // 左侧频道抽屉
                  LeftChannelDrawer(
                    key: _leftDrawerKey,
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
                    key: _rightEpgKey,
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

                  // 鼠标右键 = 遥控器返回：按层级关闭 设置→投屏→抽屉→面板，
                  // 再按弹退出确认（网页频道前台时右键被 WebView 消费，
                  // 网页区内不触发；网页菜单已在 JS 层禁用）
                  if (controller.isDesktop)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onSecondaryTapUp: (_) => _handleBackPressed(),
                      ),
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

                  // 点播长按左右键：数字进度 OSD（不拦截手势）
                  _buildSeekOsd(),

                  // 屏幕中央消息 OSD（截图/录制/关机等提示）
                  _buildMessageOsd(),

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
    // 重入守卫：退出确认框已在显示时直接忽略，
    // 防止连按返回弹出两个路由、关闭时连带弹掉播放器（黑屏）
    if (_exitDialogOpen) return;
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
    if (_bottomPanelVisible) {
      _bottomHideTimer?.cancel();
      setState(() => _bottomPanelVisible = false);
      return;
    }
    // 点播尚未加载出画面时按返回：什么都不做，避免把全屏窗口缩小
    // 或误判为「退出播放器」。用户想退出请在播放中再按返回
    if (c.state == PlayerState.loading) {
      return;
    }
    // 全屏下无其他面板时：直接弹退出确认，不先退回小窗
    //
    // 无任何可关闭项：退出前确认，避免误触
    _exitDialogOpen = true;
    _exitDialogFocusIndex = 0; // 默认聚焦「取消」，避免误触退出/关机
    final result = await showDialog<int?>(
      context: context,
      builder: (dialogCtx) {
        // 遥控器友好：AlertDialog 用 StatefulBuilder 包裹，按钮高亮
        // 随 _exitDialogFocusIndex 变化；遥控器 ←/→ 在 _handleExitDialogKey
        // 里改字段后调用 _exitDialogRefresh 刷新本对话框
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            _exitDialogRefresh = setDialogState;
            // 自绘退出面板：左侧放大的程序图标，右侧上部为程序名称与
            // 版本号，文字下方为直角矩形按钮（取消/退出/关机）。
            // 安卓电视逻辑分辨率较小（常见 960x540），按屏宽等比缩小面板
            final double panelScale =
                (MediaQuery.sizeOf(ctx).width / 1280).clamp(0.55, 1.0);
            return Dialog(
              backgroundColor: const Color(0xFF12151A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Colors.white24),
              ),
              child: SizedBox(
                // 外层按比例给尺寸，内层 FittedBox 把 620 宽的面板整体缩放
                width: 620 * panelScale,
                height: 240 * panelScale,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(
                    width: 620,
                    child: Padding(
                      // 图标+文字+按钮整块在弹窗内水平居中，左右留白对称；
                      // 用 Column(min) 收紧高度——Center 在 Dialog 的松散
                      // 高度约束下会把弹窗撑到近乎全屏高（内容缩在中间）
                      padding: const EdgeInsets.all(34),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 左侧放大程序图标
                              Container(
                                width: 136,
                                height: 136,
                                clipBehavior: Clip.antiAlias,
                                decoration: BoxDecoration(
                                  color: Colors.white10,
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: Image.asset(
                                  'branding/icon_1024.png',
                                  fit: BoxFit.cover,
                                ),
                              ),
                              const SizedBox(width: 48),
                              // 右侧：名称 / 版本 / 按钮
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'OMPlayer',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 27,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '版本 $_appVersion',
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 32),
                                  Wrap(
                                    spacing: 14,
                                    runSpacing: 12,
                                    children: [
                                      _buildExitOption(
                                          ctx, 0, '取消', Colors.blueAccent),
                                      _buildExitOption(
                                          ctx, 1, '退出', Colors.redAccent),
                                      // 关闭系统仅 Windows/Linux 原生显示
                                      if (_canShutdownSystem)
                                        _buildExitOption(
                                            ctx, 2, '关机', Colors.orangeAccent),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    _exitDialogOpen = false;
    _exitDialogRefresh = null;
    if (!mounted) return;
    if (result == 1) {
      // SystemNavigator.pop() 只在 Android/iOS 有效，桌面端需要用 windowManager
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.linux ||
              defaultTargetPlatform == TargetPlatform.macOS)) {
        await windowManager.close();
      } else {
        await SystemNavigator.pop();
      }
    } else if (result == 2) {
      final isWindows =
          !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
      _showOsd(
        isWindows ? '5 秒后将关闭系统，可运行 shutdown /a 取消' : '即将关闭系统…',
        icon: Icons.power_settings_new,
        duration: const Duration(seconds: 5),
      );
      await shutdownSystem();
    }
  }

  /// 退出框是否提供「关闭系统」：仅 Windows/Linux 原生（Web/安卓/iOS/macOS 不显示）
  bool get _canShutdownSystem =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  /// 退出框按钮数（2 或 3）
  int get _exitOptionCount => _canShutdownSystem ? 3 : 2;

  /// 构建退出框中的一个直角矩形按钮（不取键盘焦点，高亮由全局按键维护）
  Widget _buildExitOption(
      BuildContext ctx, int index, String label, Color color) {
    final selected = _exitDialogFocusIndex == index;
    return Focus(
      canRequestFocus: false,
      child: TextButton(
        // 一次性守卫：先摘标志再 pop，鼠标点击与遥控器 OK 都不会双 pop
        onPressed: () {
          _exitDialogOpen = false;
          Navigator.of(ctx).pop<int?>(index == 0 ? null : index);
        },
        style: TextButton.styleFrom(
          backgroundColor: selected
              ? color.withOpacity(0.22)
              : Colors.white.withOpacity(0.04),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
          ),
          side: BorderSide(
            color: selected ? color : Colors.white24,
            width: selected ? 2.0 : 1.0,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? color : Colors.white70,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  // ==================== 硬件按键快捷键 ====================

  /// 是否有对话框/弹层盖在播放页之上（二维码、退出确认等
  /// showDialog 路由；设置面板是内嵌 overlay 不算）
  bool get _modalRouteOpen {
    final r = ModalRoute.of(context);
    return r != null && !r.isCurrent;
  }

  /// 对话框打开期间的遥控器/键盘按键收口。
  /// 返回 true=已消费；不认识的键放行给弹层内控件（如输入框）。
  bool _handleKeyWhileModal(
      LogicalKeyboardKey k, bool isDown, bool isUp) {
    final isOk = k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.gameButtonA;
    final isLr = k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight;
    // 退出确认对话框有遥控器友好界面，走专用逻辑
    if (_exitDialogOpen) {
      return _handleExitDialogKey(k, isDown, isUp);
    }
    if (isOk) {
      if (isDown) {
        // 复位配对状态并关闭弹层（等同「关闭」按钮）
        _okHeld = true;
        _okLongTimer?.cancel();
        Navigator.of(context).maybePop();
      } else if (isUp) {
        _okHeld = false;
        _okLongTimer?.cancel();
        _okLongFired = false;
      }
      return true;
    }
    if (isLr) {
      // 仅消费并复位，避免弹层关闭后被当成短按切源
      if (isUp) {
        _arrowDown = false;
        _arrowLongTimer?.cancel();
        _arrowLongFired = false;
      }
      return true;
    }
    if (k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown) {
      return true; // 弹层内无列表导航需求，吞掉防穿透切台
    }
    if (k == LogicalKeyboardKey.contextMenu) {
      if (isDown) Navigator.of(context).maybePop();
      if (isUp) {
        _menuHeld = false;
        _menuLongTimer?.cancel();
        _menuLongFired = false;
      }
      return true;
    }
    if (k == LogicalKeyboardKey.escape) {
      if (isDown) Navigator.of(context).maybePop();
      return true;
    }
    return false;
  }

  /// 退出确认对话框的遥控器按键处理：
  /// ←/→ 在「取消」「退出」间移动高亮，OK 确认当前选中项，返回/Esc 直接取消
  bool _handleExitDialogKey(
      LogicalKeyboardKey k, bool isDown, bool isUp) {
    final isOk = k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.gameButtonA;
    final isLr = k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight;
    if (isOk) {
      if (isDown && _exitDialogOpen) {
        // 先置标志位，防止同一按键事件被路由双处理（全局 handler + 按钮 Focus）
        final idx = _exitDialogFocusIndex;
        _exitDialogOpen = false;
        Navigator.of(context).pop<int?>(idx == 0 ? null : idx);
      }
      return true;
    }
    if (isLr) {
      if (isDown) {
        // 按钮间循环移动：showDialog 里的 StatefulBuilder
        // 需要内部 setState 才能看到高亮移动
        final count = _exitOptionCount;
        final step = k == LogicalKeyboardKey.arrowRight ? 1 : -1;
        _exitDialogFocusIndex =
            (_exitDialogFocusIndex + step) % count;
        if (_exitDialogFocusIndex < 0) _exitDialogFocusIndex += count;
        _exitDialogRefresh?.call(() {});
      }
      return true;
    }
    if (k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown) {
      return true; // 两按钮水平排列，上下无意义
    }
    if (k == LogicalKeyboardKey.contextMenu) {
      if (isDown && _exitDialogOpen) {
        _exitDialogOpen = false;
        Navigator.of(context).pop<int?>(null);
      }
      return true;
    }
    if (k == LogicalKeyboardKey.escape) {
      if (isDown && _exitDialogOpen) {
        _exitDialogOpen = false;
        Navigator.of(context).pop<int?>(null);
      }
      return true;
    }
    return false;
  }

  /// 侧边面板（频道列表/EPG）是否有一个打开：打开期间方向键与 OK
  /// 全部转作面板内导航，不触发播放控制
  bool get _navPanelOpen => _leftDrawerOpen || _rightEpgOpen;

  /// 底部控制面板是否由用户主动呼出（长按 OK / 鼠标 hover）。
  /// 为 true 期间 ←/→ 与 OK 用于面板内按钮导航，返回键关闭面板。
  /// 面板显隐与 _bottomPanelVisible 一对一，不再被 state 强制联动
  bool get _bottomPanelActive => _bottomPanelVisible;

  /// 把遥控器动作分发给当前打开的侧边面板，并取消桌面端自动隐藏
  /// （遥控器没有鼠标 hover，面板应一直保留到返回键关闭）
  void _panelKey(String action, bool isDown) {
    _cancelDrawerHide();
    if (_leftDrawerOpen) {
      _leftDrawerKey.currentState?.handleRemoteKey(action, isDown: isDown);
    } else if (_rightEpgOpen) {
      _rightEpgKey.currentState?.handleRemoteKey(action, isDown: isDown);
    }
  }

  /// 把遥控器动作分发给底部控制面板，并取消自动隐藏
  void _bottomPanelRemoteKey(String action, bool isDown) {
    _bottomHideTimer?.cancel();
    _bottomPanelKey.currentState?.handleRemoteKey(action, isDown: isDown);
  }

  /// 全局硬件按键处理（注册在 HardwareKeyboard 上，不依赖焦点）。
  /// 返回 true 表示事件已消费，不再向焦点链传递。
  ///
  /// 遥控器适配（TV 盒子 / HTPC 遥控器在系统层就是键盘+媒体键）：
  /// - OK（select/enter）：短按=直播出节目列表 / 点播暂停播放；长按=控制面板；
  ///   面板打开时方向键/OK 全部用于面板内导航
  /// - ←/→：短按=切源；长按=点播拖动进度（直播忽略长按）
  /// - ↑/↓：切台；⏯ 媒体键：播放/暂停；⏮/⏭：切台；⏪/⏩：单步 ±10s
  /// - 菜单键（contextMenu）：短按=EPG 节目单，长按=设置面板
  /// - 返回/Esc：按层级关闭 设置→投屏→面板→全屏，再按弹退出确认。
  ///   Windows 与 Android 行为一致（Android 系统 Back 走 PopScope）
  bool _onGlobalKeyEvent(KeyEvent event) {
    final k = event.logicalKey;
    final isDown = event is KeyDownEvent;
    final isUp = event is KeyUpEvent;

    // 设置面板里有输入框（URL、数字等）：仅返回/菜单键负责关面板，
    // 其余按键放行给输入框
    if (_settingsOpen) {
      if (isDown &&
          (k == LogicalKeyboardKey.escape ||
              k == LogicalKeyboardKey.contextMenu)) {
        _handleBackPressed();
        return true;
      }
      return false;
    }
    // 有对话框（二维码/退出确认等）盖在页面上时：遥控器按键统一收口——
    // OK/返回/菜单关闭弹层，方向键消费不穿透，避免弹层是在 OK 按下后
    // 才弹出时抬起事件丢失，导致按住状态卡死、关弹层后误触节目列表
    if (_modalRouteOpen) {
      return _handleKeyWhileModal(k, isDown, isUp);
    }

    // OK 与左右方向键要区分短按/长按，走按下-抬起配对处理
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.gameButtonA) {
      if (isDown) _okDown();
      if (isUp) _okUp();
      return true;
    }
    if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight) {
      final left = k == LogicalKeyboardKey.arrowLeft;
      if (isDown) _lrDown(left);
      if (isUp) _lrUp(left);
      return true;
    }
    // 菜单键：短按 EPG / 长按设置，走按下-抬起配对
    if (k == LogicalKeyboardKey.contextMenu) {
      if (isDown) _menuDown();
      if (isUp) _menuUp();
      return true;
    }
    // 上下：面板打开时面板内移动，否则切台
    if (k == LogicalKeyboardKey.arrowUp) {
      if (isDown) _verticalKey(true);
      return true;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (isDown) _verticalKey(false);
      return true;
    }
    // Esc / 遥控器返回：层级关闭（与 Android Back 同一入口）
    if (k == LogicalKeyboardKey.escape) {
      if (isDown) _handleBackPressed();
      return true;
    }

    // 其余按键只处理首次按下；长按重复事件是 KeyRepeatEvent，天然被排除
    if (!isDown) return false;

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
    } else if (k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.mediaPlay ||
        k == LogicalKeyboardKey.mediaPause) {
      // 遥控器 ⏯ 播放/暂停键
      action = 'playpause';
    }
    if (action != null) {
      _onShortcut(action);
      return true;
    }

    // ⏮/⏭ 曲目键 = 切台；⏪/⏩ 快退快进键 = 点播单步 ±10 秒
    if (k == LogicalKeyboardKey.mediaTrackNext) {
      _onArrow('nextChannel');
      return true;
    }
    if (k == LogicalKeyboardKey.mediaTrackPrevious) {
      _onArrow('prevChannel');
      return true;
    }
    if (k == LogicalKeyboardKey.mediaFastForward) {
      _singleSeekStep(false);
      return true;
    }
    if (k == LogicalKeyboardKey.mediaRewind) {
      _singleSeekStep(true);
      return true;
    }

    return false;
  }

  /// OK 按下边沿（首次按下；系统自动重复由 _okHeld 去重）。
  /// 面板打开：转发面板；否则启动 500ms 长按计时。
  void _okDown() {
    if (_okHeld) return;
    _okHeld = true;
    _okLongFired = false;
    if (_navPanelOpen) {
      _okDownInPanel = true;
      _panelKey('ok', true);
      return;
    }
    if (_bottomPanelActive) {
      _okDownInPanel = true;
      _bottomPanelRemoteKey('ok', true);
      return;
    }
    _okLongTimer?.cancel();
    _okLongTimer = Timer(const Duration(milliseconds: 500), () {
      _okLongFired = true;
      // 长按 OK = 呼出/收起控制面板（内部有播放状态守卫）
      _toggleBottomPanel();
    });
  }

  /// OK 抬起边沿：面板打开时转发；否则长按不触发、短按按播放状态处理
  void _okUp() {
    if (!_okHeld) return;
    _okHeld = false;
    _okLongTimer?.cancel();
    // 按下时面板是打开的（选台/按钮操作可能在按下边沿已关闭面板），
    // 这次抬起仍属于面板内操作，绝不能落到短按逻辑里——否则频道列表
    // 选台后松手会触发「面板外短按」= 播放/暂停切换或重开列表（串台感）
    if (_okDownInPanel) {
      _okDownInPanel = false;
      if (_navPanelOpen) {
        _panelKey('ok', false);
      } else if (_bottomPanelActive) {
        _bottomPanelRemoteKey('ok', false);
      }
      _okLongFired = false;
      return;
    }
    if (_navPanelOpen) {
      _panelKey('ok', false);
      return;
    }
    if (_bottomPanelActive) {
      _bottomPanelRemoteKey('ok', false);
      return;
    }
    if (!_okLongFired) {
      final c = context.read<PlayerController>();
      // 点播短按 OK = 暂停/播放；直播/网页频道 = 呼出或收起节目列表
      if (c.isSeekable && !c.webPageActive) {
        c.togglePlayPause();
      } else {
        _toggleDrawer(left: true);
      }
    }
    _okLongFired = false;
  }

  /// ←/→ 按下边沿。面板打开：转发面板内导航；
  /// 可 seek（点播）：点按直接 ±60s seek（不再长按，避免面板冲突）；
  /// 不可 seek（直播/网页）：启动短按切源计时
  void _lrDown(bool isLeft) {
    if (_arrowDown) return;
    _arrowDown = true;
    _arrowLongFired = false;
    _arrowLongTimer?.cancel();
    if (_navPanelOpen) {
      _panelKey(isLeft ? 'left' : 'right', true);
      return;
    }
    if (_bottomPanelActive) {
      _bottomPanelRemoteKey(isLeft ? 'left' : 'right', true);
      return;
    }
    final c = context.read<PlayerController>();
    // 可 seek（点播）：点按直接 seek，不再长按——长按会误弹面板、
    // 与面板打开后的左右导航冲突，体验不好
    if (c.isSeekable && !c.webPageActive) {
      _singleSeekStep(isLeft);
      return;
    }
    // 不可 seek（直播/网页）：抬起前快速操作即切源（防抖避免按多次切多台）
    _arrowLongTimer = Timer(const Duration(milliseconds: 400), () {
      _arrowLongFired = true;
    });
  }

  /// ←/→ 抬起边沿：点播点按 seek 后淡出 OSD；直播/网页短按切源
  void _lrUp(bool isLeft) {
    if (!_arrowDown) return;
    _arrowDown = false;
    _arrowLongTimer?.cancel();
    if (_navPanelOpen) {
      _panelKey(isLeft ? 'left' : 'right', false);
      _arrowLongFired = false;
      return;
    }
    if (_bottomPanelActive) {
      _bottomPanelRemoteKey(isLeft ? 'left' : 'right', false);
      _arrowLongFired = false;
      return;
    }
    final c = context.read<PlayerController>();
    if (c.isSeekable && !c.webPageActive) {
      // 点播点按 seek：OSD 再停留 1.2 秒后淡出
      if (_seekOsdVisible) _armSeekOsdHide();
    } else if (_arrowLongFired) {
      // 直播/网页长按无动作
    } else {
      _onArrow(isLeft ? 'prevSource' : 'nextSource');
    }
    _arrowLongFired = false;
  }

  /// ↑/↓ 按下边沿：侧边面板打开时面板内移动；底部控制面板打开时忽略
  /// （按钮只有一行，避免误触切台）；其余情况切台
  void _verticalKey(bool isUp) {
    if (_navPanelOpen) {
      _panelKey(isUp ? 'up' : 'down', true);
      return;
    }
    if (_bottomPanelActive) return;
    _onArrow(isUp ? 'prevChannel' : 'nextChannel');
  }

  /// 菜单键按下：启动 500ms 长按=设置
  void _menuDown() {
    if (_menuHeld) return;
    _menuHeld = true;
    _menuLongFired = false;
    _menuLongTimer?.cancel();
    _menuLongTimer = Timer(const Duration(milliseconds: 500), () {
      _menuLongFired = true;
      _toggleSettings();
    });
  }

  /// 菜单键抬起：未到长按时长=短按，打开 EPG 节目单
  void _menuUp() {
    if (!_menuHeld) return;
    _menuHeld = false;
    _menuLongTimer?.cancel();
    if (!_menuLongFired) {
      _toggleDrawer(left: false);
    }
    _menuLongFired = false;
  }

  /// 媒体键（⏪/⏩）单步 seek ±60 秒：以当前播放位置为基准，
  /// 屏幕中央显示数字进度 OSD，不弹控制面板
  void _singleSeekStep(bool isLeft) {
    final c = context.read<PlayerController>();
    if (!c.isSeekable) return;
    final dur = c.duration;
    if (dur <= Duration.zero) return;
    var t = c.position + Duration(seconds: isLeft ? -60 : 60);
    if (t < Duration.zero) t = Duration.zero;
    if (t > dur) t = dur;
    c.seekTo(t);
    _showSeekOsd(target: t, duration: dur, forward: !isLeft);
    _armSeekOsdHide();
  }

  /// 显示屏幕中央数字进度 OSD（持续到松手后 1.2 秒）
  void _showSeekOsd({
    required Duration target,
    required Duration duration,
    required bool forward,
  }) {
    _seekOsdHideTimer?.cancel();
    setState(() {
      _seekOsdVisible = true;
      _seekOsdTarget = target;
      _seekOsdDuration = duration;
      _seekOsdForward = forward;
    });
  }

  /// 松手后让 seek OSD 停留片刻再淡出
  void _armSeekOsdHide() {
    _seekOsdHideTimer?.cancel();
    _seekOsdHideTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _seekOsdVisible = false);
    });
  }

  /// 在屏幕中央显示一条消息 OSD（截图/录制/关机等提示），
  /// 取代底部 SnackBar。[duration] 后自动淡出。
  void _showOsd(
    String text, {
    IconData icon = Icons.info_outline,
    Duration duration = const Duration(milliseconds: 2200),
  }) {
    if (!mounted) return;
    _msgOsdTimer?.cancel();
    setState(() {
      _msgOsdText = text;
      _msgOsdIcon = icon;
      _msgOsdVisible = true;
    });
    _msgOsdTimer = Timer(duration, () {
      if (mounted) setState(() => _msgOsdVisible = false);
    });
  }

  /// 深层 widget 通过 OsdBus 发来的消息 → 中央 OSD
  void _onBusOsd() {
    final m = OsdBus.message.value;
    if (m != null) _showOsd(m.text, icon: m.icon);
  }

  /// 屏幕中央消息 OSD：半透明深色圆角卡片 + 图标 + 文字，不拦截输入
  Widget _buildMessageOsd() {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _msgOsdVisible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 180),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 560),
              margin: const EdgeInsets.symmetric(horizontal: 48),
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.72),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white24),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_msgOsdIcon, color: Colors.blueAccent, size: 30),
                  const SizedBox(width: 14),
                  Flexible(
                    child: Text(
                      _msgOsdText,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w600,
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

  /// 时长格式化：不足 1 小时显示 m:ss，否则 h:mm:ss
  String _fmtClock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// 点播快进/快退数字进度浮层：方向图标 + 大号目标时间 + 总时长 + 进度条
  Widget _buildSeekOsd() {
    final totalMs = _seekOsdDuration.inMilliseconds;
    final ratio = totalMs > 0
        ? (_seekOsdTarget.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _seekOsdVisible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 150),
          child: Center(
            child: Container(
              width: 288,
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.68),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _seekOsdForward
                            ? Icons.fast_forward
                            : Icons.fast_rewind,
                        color: Colors.blueAccent,
                        size: 38,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _fmtClock(_seekOsdTarget),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 34,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '/ ${_fmtClock(_seekOsdDuration)}    每格 60 秒',
                    style: const TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 5,
                      backgroundColor: Colors.white24,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.blueAccent),
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
                        style: TextStyle(
                          color: Colors.blueAccent,
                          // 手机上 48 过大，缩到 30
                          fontSize: isPhone ? 30 : 48,
                          fontWeight: FontWeight.bold,
                          height: 1,
                        ),
                      ),
                      SizedBox(width: isPhone ? 8 : 12),
                      Text(
                        ch?.name ?? '',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: isPhone ? 15 : 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  // 第二行：正在直播 + 当前节目
                  if (program != null && program.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: isPhone ? 5 : 8),
                      child: Text(
                        '正在直播 · $program',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: isPhone ? 12 : 14,
                        ),
                      ),
                    ),
                  // 数字选台输入提示
                  if (_numBuffer.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: isPhone ? 5 : 8),
                      child: Text(
                        '输入: $_numBuffer',
                        style: TextStyle(
                          color: Colors.blueAccent,
                          fontSize: isPhone ? 12 : 14,
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
    // 不能用 state==playing 拦截，否则左右点击永远呼不出面板；
    // 暂停中也允许呼出（遥控器长按 OK 在暂停时同样要看进度/恢复播放）
    if (!c.webPageActive &&
        c.state != PlayerState.playing &&
        c.state != PlayerState.paused) {
      return;
    }
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

  /// 底部控制面板「手机扫码管理」按钮：弹出二维码
  void _showRemoteAdminQr(PlayerController controller) {
    final url = controller.remoteAdminUrl;
    if (url.isEmpty) return;
    showRemoteAdminQrDialog(context, url);
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

  /// 播放加载防抖：按下键到内核真正初始化完成期间，遥控器连按的
  /// 切台/切源动作全部忽略。防止"往下按了一下、松手后才加载完、
  /// 补按的 OK/方向键落到停在很后面的频道"这类竞态
  bool _throttled() {
    if (DateTime.now().isBefore(_loadingLockUntil)) return true;
    _loadingLockUntil = DateTime.now().add(_loadingLock);
    return false;
  }

  /// 方向键：←/→ 切换播放源，↑/↓ 切换频道
  void _onArrow(String action) {
    if (_settingsOpen || _leftDrawerOpen || _rightEpgOpen) return;
    if (_throttled()) return;
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

  /// 钩子按住期间系统会重复发 WM_KEYDOWN：记录已按下动作去重，
  /// 保证一次物理按下只派发一次按下边沿
  final Set<String> _nativeHeld = <String>{};

  /// 原生钩子转发的动作键（网页持有焦点时 HardwareKeyboard 收不到，
  /// 由 WH_KEYBOARD_LL 经 omplayer/win_hotkeys 通道送达）。
  /// isDown=true 按下边沿、false 抬起边沿，与 Flutter 路径共用
  /// 同一套短按/长按/面板导航逻辑。
  void _onNativeAction(String action, bool isDown) {
    if (!mounted) return;
    if (isDown) {
      if (!_nativeHeld.add(action)) return; // 自动重复，忽略
    } else {
      _nativeHeld.remove(action);
    }
    // 设置面板打开：仅返回键关面板，其余（字母键/空格等）忽略，
    // 此时钩子捕获本就由 setCapture(false) 关闭，这里是双保险
    if (_settingsOpen) {
      if (isDown && (action == 'esc' || action == 'back')) {
        _handleBackPressed();
      }
      return;
    }
    // 对话框（二维码/退出确认等）打开：统一收口；抬起边沿复位配对状态，
    // 绝不能落到 _handleBackPressed（否则会退全屏/缩小窗口）
    if (_modalRouteOpen) {
      if (!isDown) {
        if (action == 'ok') {
          _okHeld = false;
          _okLongTimer?.cancel();
          _okLongFired = false;
        } else if (action == 'left' || action == 'right') {
          _arrowDown = false;
          _arrowLongTimer?.cancel();
          _arrowLongFired = false;
        } else if (action == 'menu') {
          _menuHeld = false;
          _menuLongTimer?.cancel();
          _menuLongFired = false;
        }
        return;
      }
      // 退出确认对话框：←/→ 循环移动焦点，OK 确认，返回/菜单取消
      if (_exitDialogOpen) {
        if (action == 'left' || action == 'right') {
          final count = _exitOptionCount;
          final step = action == 'right' ? 1 : -1;
          _exitDialogFocusIndex = (_exitDialogFocusIndex + step) % count;
          if (_exitDialogFocusIndex < 0) _exitDialogFocusIndex += count;
          _exitDialogRefresh?.call(() {});
        } else if (action == 'ok') {
          // 一次性守卫：先摘标志再 pop，任何重复/残余事件都不会
          // 再弹一次（第二次 pop 会把播放器路由弹掉 → 黑屏）
          final idx = _exitDialogFocusIndex;
          _exitDialogOpen = false;
          Navigator.of(context).pop<int?>(idx == 0 ? null : idx);
        } else if (action == 'back' ||
            action == 'esc' ||
            action == 'menu') {
          _exitDialogOpen = false;
          Navigator.of(context).pop<int?>(null);
        }
        return;
      }
      if (action == 'ok' ||
          action == 'back' ||
          action == 'esc' ||
          action == 'menu') {
        Navigator.of(context).maybePop();
      }
      return;
    }
    // OK / 左右 / 菜单需要按下-抬起配对
    if (action == 'ok') {
      isDown ? _okDown() : _okUp();
      return;
    }
    if (action == 'left') {
      isDown ? _lrDown(true) : _lrUp(true);
      return;
    }
    if (action == 'right') {
      isDown ? _lrDown(false) : _lrUp(false);
      return;
    }
    if (action == 'menu') {
      isDown ? _menuDown() : _menuUp();
      return;
    }
    if (!isDown) return; // 其余动作只响应按下边沿
    final controller = context.read<PlayerController>();
    switch (action) {
      case 'up':
        _verticalKey(true);
      case 'down':
        _verticalKey(false);
      case 'esc':
      case 'back':
        _handleBackPressed();
      case 'space':
        controller.togglePlayPause();
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
      _showOsd(
        path != null ? '截图已保存: $path' : '截图失败',
        icon: Icons.photo_camera,
        duration: const Duration(seconds: 3),
      );
    }
  }

  Future<void> _toggleRecording(PlayerController controller) async {
    if (!controller.isDesktop) return;
    if (controller.isRecording) {
      final path = await controller.stopRecording();
      if (mounted) {
        _showOsd(
          path != null
              ? '录制已停止，保存至: $path'
              : '录制已停止（未捕获到视频数据）',
          icon: Icons.stop,
          duration: const Duration(seconds: 3),
        );
      }
    } else {
      final ok = await controller.startRecording();
      if (mounted) {
        _showOsd(
          ok
              ? (controller.webPageActive
                  ? '开始录制网页视频，保存到程序所在文件夹的 recordings 子文件夹'
                  : '开始录制，视频保存到程序所在文件夹的 recordings 子文件夹')
              : (controller.lastError ?? '录制失败'),
          icon: Icons.fiber_manual_record,
          duration: const Duration(seconds: 2),
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

  /// 禁用网页右键菜单（<video> 默认的“循环/复制视频地址/另存”等菜单
  /// 不该出现在播放应用里）。捕获阶段拦截 contextmenu，并对所有
  /// 同源 iframe 递归挂载；MutationObserver 处理后续动态插入的 iframe。
  /// 幂等：顶层与各文档各自打 __omNoCtx 标记，可重复注入。
  static const String _noContextMenuJs = r'''
(function(){
  function kill(e){ try { e.preventDefault(); e.stopImmediatePropagation(); } catch(_){} }
  function bindDoc(d){
    try {
      if (!d || d.__omNoCtx) return;
      d.__omNoCtx = true;
      d.addEventListener('contextmenu', kill, true);
      bindFrames(d);
    } catch(e) {}
  }
  function bindFrames(root){
    var fs;
    try { fs = root.querySelectorAll('iframe'); } catch(e) { return; }
    for (var i=0;i<fs.length;i++){
      try { bindDoc(fs[i].contentDocument); } catch(e) {}
    }
  }
  bindDoc(document);
  if (!window.__omNoCtxObs) {
    window.__omNoCtxObs = true;
    try {
      new MutationObserver(function(muts){
        for (var i=0;i<muts.length;i++){
          var added = muts[i].addedNodes;
          for (var j=0;j<added.length;j++){
            var n = added[j];
            if (n.nodeType !== 1) continue;
            if (n.tagName === 'IFRAME') { try { bindDoc(n.contentDocument); } catch(e) {} }
            else { try { bindFrames(n); } catch(e) {} }
          }
        }
      }).observe(document.documentElement, {childList:true, subtree:true});
    } catch(e) {}
  }
})();
''';

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
    // 加载进度，就证明运行时正常；25 秒内毫无进展才提示安装。
    // 放宽到 25 秒：慢站点 + 弱网下 15 秒易误判"未安装"，导致程序
    // 状态不一致、退出时 WebView 未正确释放进而崩溃。
    _runtimeTimer = Timer(const Duration(seconds: 25), () {
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
      await c.evaluateJavascript(source: _noContextMenuJs);
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
                  Text(
                    webEnvOfficialVersion != null
                        ? '已检测到 WebView2 $webEnvOfficialVersion，但环境创建失败\n可尝试重装 WebView2 Runtime 或重启程序'
                        : '未检测到 WebView2 运行环境\n网页频道需要 Microsoft Edge WebView2 Runtime',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  if (webEnvLastError.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    SelectableText(
                      webEnvLastError,
                      maxLines: 4,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 10),
                    ),
                  ],
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

/// 右上角系统时钟。
///
/// 完全独立自治：
/// - 显隐由 [PlayerController.clockVisible] 驱动（ValueListenableBuilder），
///   只重建时钟自身；
/// - 走时由内部定时器每秒刷新。
///
/// 因此切换「显示时间」不会触发 PlayerController.notifyListeners，整棵
/// 播放 Stack 不重建。旧实现复用 updateSettings，反复切换会反复整树重建，
/// 导致画面出现灰屏。
class ClockOverlay extends StatefulWidget {
  const ClockOverlay({super.key});

  @override
  State<ClockOverlay> createState() => _ClockOverlayState();
}

class _ClockOverlayState extends State<ClockOverlay> {
  Timer? _timer;
  String _text = '';

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    final t = DateFormat('HH:mm').format(DateTime.now());
    if (t != _text && mounted) setState(() => _text = t);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.read<PlayerController>();
    return Positioned(
      top: 0,
      right: 0,
      child: ValueListenableBuilder<bool>(
        valueListenable: controller.clockVisible,
        builder: (context, visible, child) =>
            visible ? child! : const SizedBox.shrink(),
        child: SafeArea(
          child: Padding(
            // 与屏幕上边、右边保持约一行距离（桌面无 SafeArea 边距，
            // 显式留白）
            padding: const EdgeInsets.only(top: 20, right: 28, bottom: 8),
            child: Text(
              _text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w500,
                shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
