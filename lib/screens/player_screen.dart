import 'dart:async';
import 'dart:collection';
import 'dart:convert';
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
  static const String _appVersion = '1.0.154';

  // 退出确认对话框的遥控器友好句柄：左右键移动焦点，OK 确认当前按钮
  int _exitDialogFocusIndex = 0; // 0=返回, 1=退出, 2=关机
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
                                              '正在打开网页频道，请稍候...',
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

                  // 移动端：屏幕分三区，单击左/中/右分别呼出频道菜单/
                  // 控制面板/EPG（见 _buildGestureLayer），不再使用贴边
                  // 窄热区；桌面端保留 hover 边缘自动弹出

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
                    onSwitchWebNative: () =>
                        controller.switchWebNativePlayback(),
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
            // 自绘退出面板：不显示程序图标，内容全部居中，
            // 紧凑布局（短小精悍）：程序名称/版本两行 +
            // 「返回/退出/关机」三个方块图标按钮（无文字，
            // 鼠标悬停或遥控器框选时在方块下方显示对应文字）。
            // 安卓电视逻辑分辨率较小（常见 960x540），按屏宽等比缩小面板
            final double panelScale =
                (MediaQuery.sizeOf(ctx).width / 1280).clamp(0.55, 1.0);
            final options = <_ExitOption>[
              const _ExitOption(
                  Icons.arrow_back, '返回', Colors.blueAccent),
              const _ExitOption(Icons.logout, '退出', Colors.redAccent),
              // 关闭系统仅 Windows/Linux 原生显示
              if (_canShutdownSystem)
                const _ExitOption(
                    Icons.power_settings_new, '关机', Colors.orangeAccent),
            ];
            return Dialog(
              backgroundColor: const Color(0xFF12151A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Colors.white24),
              ),
              child: SizedBox(
                width: 380 * panelScale,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 34, vertical: 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Text(
                          'OMPlayer',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '版本 $_appVersion',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (var i = 0; i < options.length; i++)
                              Padding(
                                padding: EdgeInsets.only(
                                    right:
                                        i == options.length - 1 ? 0 : 22),
                                child: _buildExitIconOption(
                                    ctx, i, options[i]),
                              ),
                          ],
                        ),
                      ],
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

  /// 构建退出框中的一个方块图标按钮（不取键盘焦点，高亮由全局按键维护）。
  /// 方块仅显示图标；鼠标悬停或遥控器框选时，方块下方显示文字标签。
  Widget _buildExitIconOption(
      BuildContext ctx, int index, _ExitOption opt) {
    final selected = _exitDialogFocusIndex == index;
    final color = opt.color;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        // 鼠标移入即框选该项（与遥控器左右移动等效），下方显示文字
        if (_exitDialogFocusIndex != index) {
          _exitDialogFocusIndex = index;
          _exitDialogRefresh?.call(() {});
        }
      },
      child: GestureDetector(
        // 一次性守卫：先摘标志再 pop，鼠标点击与遥控器 OK 都不会双 pop
        onTap: () {
          _exitDialogOpen = false;
          Navigator.of(ctx).pop<int?>(index == 0 ? null : index);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: selected
                    ? color.withOpacity(0.22)
                    : Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected ? color : Colors.white24,
                  width: selected ? 2.0 : 1.0,
                ),
              ),
              child: Icon(
                opt.icon,
                color: selected ? color : Colors.white70,
                size: 28,
              ),
            ),
            // 标签行固定高度：仅框选/悬停项显示文字，避免布局跳动
            SizedBox(
              height: 20,
              child: Center(
                child: selected
                    ? Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          opt.label,
                          style: TextStyle(
                            color: color,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
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

  // ==================== 抽屉控制 ====================

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
            // 左侧：上下滑动调亮度、左边缘右滑/单击开频道菜单
            Expanded(
              child: GestureDetector(
                // 移动端左三分之一：单击开/关频道菜单（不必贴左边缘）
                onTap: controller.isDesktop
                    ? null
                    : () => _toggleDrawer(left: true),
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
            // 右侧：音量调节 + 右边缘滑出 EPG；移动端右三分之一
            // 单击开/关 EPG 菜单（不必贴右边缘）
            Expanded(
              child: GestureDetector(
                onTap: controller.isDesktop
                    ? null
                    : () => _toggleDrawer(left: false),
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
  /// 不能永远黑屏把用户卡死——8 秒后若网页自身也没起播，
  /// 直接把网页推到前台（网页已起播则等嗅探决策出结论）
  Timer? _forceForegroundTimer;

  /// 最终决策窗口（15 秒）：期间没识别出可直连直播主流，
  /// 判定加密/无流，直接网页全屏播放（不提示、不跳内置）
  Timer? _decisionTimer;

  /// 网页自身起播后的宽限定时器：再给嗅探 6 秒确认直播主流，
  /// 仍无结论则立刻网页全屏（加密页用户不用黑屏等满总窗口）
  Timer? _webReadyGraceTimer;

  /// 页面 <video> 是否已报告起播（决定兜底窗口结束时
  /// 一次性嗅探候选是否值得接管）
  bool _webPlayReady = false;

  /// 15 秒内 WebView 毫无加载进度：判定为缺少 WebView2 运行时
  Timer? _runtimeTimer;

  /// XHR/fetch 嗅探到的媒体流候选：自动聚合 + 服务端预检，
  /// 可直连则自动切内置播放器全屏播放；加密/不可直连则留在网页
  /// 全屏播放，不弹任何常驻提示
  final Map<String, _SniffCandidate> _sniffCandidates = {};
  Timer? _sniffAggTimer;
  Timer? _sniffDeadline;
  bool _sniffChecking = false;
  bool _sniffDone = false;
  bool _sniffAbandoned = false;

  static int _sniffKindPri(String kind) =>
      kind == 'hls' ? 3 : (kind == 'dash' ? 2 : 1);

  void _onSniffedStream(dynamic raw) {
    if (_sniffAbandoned || _sniffDone) return;
    try {
      final s = raw is String ? raw : raw.toString();
      final m = jsonDecode(s) as Map<dynamic, dynamic>;
      final url = (m['u'] as String?) ?? '';
      if (url.isEmpty || !mounted) return;
      final kind = (m['k'] as String?) ?? 'hls';
      final now = DateTime.now();
      final c = _sniffCandidates.putIfAbsent(
          url,
          () => _SniffCandidate(
                url: url,
                kind: kind,
                referer: (m['r'] as String?) ?? widget.url,
                ua: m['ua'] as String?,
              ));
      c.count++;
      c.last = now;
      // 更高优先级类型可升级标注
      if (_sniffKindPri(kind) > _sniffKindPri(c.kind)) c.kind = kind;
      // 首个候选出现后 15 秒兜底：强制执行最后一轮选择，仍不可接管
      // 就留在网页全屏播放（_decisionTimer 是无候选时的总兜底）
      _sniffDeadline ??= Timer(const Duration(seconds: 15), () {
        if (!_sniffDone) _autoPick(force: true);
      });
      // 请求持续到达期间反复安排聚合选择；正在预检时不重入
      if (!_sniffChecking && _sniffAggTimer == null) {
        _sniffAggTimer = Timer(const Duration(seconds: 4), () {
          _sniffAggTimer = null;
          _autoPick(force: false);
        });
      }
    } catch (_) {}
  }

  /// 网页自身播放器起播：正常页不立即显露网页，再给嗅探 6 秒确认
  /// 是否存在可直连直播主流；确认不到就网页全屏（加密 MSE 页）。
  /// 只安排一次。
  void _markWebPlayReady() {
    if (_webPlayReady || _sniffDone) return;
    _webPlayReady = true;
    _webReadyGraceTimer ??= Timer(const Duration(seconds: 6), () {
      if (mounted && !_sniffDone) _autoPick(force: true);
    });
  }

  /// 决策结束：不再尝试接管，直接让网页全屏播放（加密/DRM/无流，
  /// 或网页自身已在播而嗅探候选只是侧栏推荐）。全程不弹提示。
  void _finishWithWeb() {
    if (_sniffDone) return;
    _sniffDone = true;
    _sniffDeadline?.cancel();
    _sniffAggTimer?.cancel();
    _forceForegroundTimer?.cancel();
    _webReadyGraceTimer?.cancel();
    if (mounted && !widget.foreground) widget.onForeground();
  }

  Future<void> _autoPick({required bool force}) async {
    if (_sniffDone || _sniffChecking || !mounted) return;
    final now = DateTime.now();
    var list = _sniffCandidates.values.toList();
    // 近 10 秒仍在被请求的才是当前播放的主流（直播清单持续轮询；
    // 页面上的推荐位/其他频道/广告片段只请求一两次）
    var alive =
        list.where((c) => now.difference(c.last).inSeconds <= 10).toList();
    if (alive.isEmpty) {
      if (!force) return; // 聚合太早，等后续真实请求或兜底窗口
      alive = list;
    }
    if (alive.isEmpty) {
      if (force) _finishWithWeb();
      return;
    }
    alive.sort((a, b) {
      final p = _sniffKindPri(b.kind).compareTo(_sniffKindPri(a.kind));
      if (p != 0) return p;
      return b.count.compareTo(a.count);
    });
    _sniffChecking = true;
    final pc = context.read<PlayerController>();
    for (final c in alive.take(3)) {
      // 非强制轮次：只认被持续轮询（count>=2）的直播清单主流，
      // 页面刚打开时一次性请求的广告/侧栏推荐流不接管；
      // 强制兜底时：若网页自身已经在播（MSE/blob 加密流），一次性
      // 候选也不接管——正片显然已由网页播放器处理，安心留网页；
      // 网页没起播时才允许用唯一候选尝试内置接管
      if (c.count < 2 && (!force || _webPlayReady)) continue;
      final ok = await pc.checkSniffedStreamPlayable(
        url: c.url,
        kind: c.kind,
        referer: c.referer ?? widget.url,
        userAgent: (c.ua != null && c.ua!.trim().isNotEmpty)
            ? c.ua!.trim()
            : '',
      );
      if (!mounted) return;
      if (ok) {
        _sniffDone = true;
        _sniffChecking = false;
        _sniffDeadline?.cancel();
        _decisionTimer?.cancel();
        _forceForegroundTimer?.cancel();
        _webReadyGraceTimer?.cancel();
        // 后台静默接管：网页从未显露，直接内置播放器全屏，
        // 左上角切台 OSD 会照常显示，不额外弹提示
        await pc.playSniffedWebStream(
          url: c.url,
          referer: c.referer ?? widget.url,
          userAgent: c.ua,
        );
        return;
      }
    }
    _sniffChecking = false;
    // 预检全部不通过：兜底窗口结束则留网页全屏（加密/DRM，不提示）；
    // 未到点则等页面后续请求触发下一轮
    if (force) _finishWithWeb();
  }

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

  /// CSS：把页面里的 <video> 伪全屏铺满窗口；隐藏主流网页播放器的
  /// 控制条/信息浮层（借鉴 TVBox 系 live.webview.js 的选择器表），
  /// 让网页兜底播放看起来接近原生全屏。注意不隐藏大播放按钮/海报，
  /// 否则自动开播逻辑（getBoundingClientRect 尺寸判定）会失效。
  static const String _cssJs = r'''
(function(){
  var CSS_TEXT = 'html,body{margin:0!important;padding:0!important;background:#000!important;overflow:hidden!important;height:100%!important;width:100%!important}'
      + '*{-webkit-user-select:none!important;user-select:none!important}'
      + 'input,textarea{-webkit-user-select:text!important;user-select:text!important}'
      + 'video{position:fixed!important;top:0!important;left:0!important;width:100vw!important;height:100vh!important;object-fit:contain!important;z-index:2147483647!important;background:#000!important;outline:none!important}'
      + '.xg-controls,.xgplayer-controls,.prism-controlbar,.prism-detect-info,.prism-info-display,'
      + '.vjs-control-bar,.dplayer-controller,.dplayer-bezel,.dplayer-menu,#control_bar_player,#pic_in_pic_player{display:none!important}'
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
    // kick() 每 700ms 调用一次，必须轻量：只递归同源 iframe，
    // 不做 querySelectorAll('*') 的 Shadow DOM 全遍历（弹幕重页面会掉帧）
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
  // 每秒轮询一次，必须轻量：只递归同源 iframe
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

  /// 媒体流深度嗅探（借鉴 TVBox 系 live.parse.js 方案）：
  /// 除劫持 XHR/fetch 请求地址外，还扫描响应体（JSON/清单文本）、
  /// WebSocket 帧、URL.createObjectURL(Blob) 合成清单、TextDecoder、
  /// String.fromCharCode / Array.join / indexOf / atob 拼装、
  /// HTMLMediaElement.src / setAttribute('src')、Shadow DOM 轮询、
  /// 内联 <script> 硬编码地址，并劫持 Worker 构造函数把嗅探器前置
  /// 注入 worker 线程（清单解析/解密在 worker 里做的播放器）。
  /// 捕获到的真实流地址（m3u8/mpd/http-flv）统一走既有 omStream
  /// JSON 协议上报，Dart 侧聚合决策自动切内置播放器全屏播放。
  /// 必须在页面其他 JS 之前注入（AT_DOCUMENT_START UserScript），
  /// 否则页面已持有原始 fetch/JSON.parse 引用，hook 无效；
  /// __omSniffed 哨兵保证只安装一次，运行时 _inject() 重注入是兜底。
  static const String _sniffJs = r'''
(function(){
  if (window.__omSniffed) return;
  window.__omSniffed = true;

  var MEDIA = /\.(m3u8|m3u|mpd|flv)(?:$|[?#/])/i;
  // 明显是广告/统计/日志的地址不采用
  var NOISE = /\/(ad|ads|advert|dsp|stat|stats|track|tracking|log|logs|report|metrics)(?:\/|$)/i;
  var MAX_SCAN = 512 * 1024;

  // ---- 主文档上报出口：保持 omStream 既有 JSON 协议 {u,k,via,ua,r} ----
  var lastEmit = Object.create(null);
  var emitCount = 0;
  function report(u, via, base){
    try {
      if (!u || typeof u !== 'string') return;
      if (/^(blob:|data:|about:|javascript:|chrome-extension:)/i.test(u)) return;
      base = base || location.href;
      var abs;
      try { abs = new URL(u, base).href; } catch(e) { return; }
      if (!/^https?:\/\//i.test(abs)) return;
      var p = abs.split('#')[0].split('?')[0];
      if (!MEDIA.test(p) || NOISE.test(p)) return;
      var m = p.match(/\.(m3u8|m3u|mpd|flv)$/i);
      var ext = (m && m[1] || '').toLowerCase();
      var kind = (ext === 'mpd') ? 'dash' : (ext === 'flv' ? 'flv' : 'hls');
      var now = Date.now();
      // 直播清单会被持续轮询：3 秒节流去重（不永久去重，
      // Dart 侧靠重复计数识别当前正在播放的主流，一次性噪声沉底）
      if (now - (lastEmit[abs] || 0) < 3000) return;
      lastEmit[abs] = now;
      if (++emitCount > 4096) { lastEmit = Object.create(null); emitCount = 0; }
      var payload = JSON.stringify({
        u: abs, k: kind, via: via || '',
        ua: navigator.userAgent || '',
        r: base
      });
      try {
        window.top.flutter_inappwebview.callHandler('omStream', payload);
      } catch(e) {
        try { window.flutter_inappwebview.callHandler('omStream', payload); }
          catch(e2) {}
      }
    } catch(e) {}
  }

  // ==================== 深度嗅探安装器（主文档与 Worker 复用） ====================
  // reportFn(u, via) 由调用方按上下文注入：
  //   主文档 → omStream 桥；Worker → self.postMessage 回主线程转发
  //   （worker 作用域没有 flutter_inappwebview 桥）。
  // installSource 为本函数源码字符串，供（嵌套）Worker 复制安装。
  // origBase 仅 Worker 场景传入：本 worker 原始脚本的绝对 URL，
  // 用于修复 blob 重建后相对地址（fetch/XHR/importScripts）的解析基准。
  function installDeep(reportFn, installSource, origBase) {
    var scope = (typeof self !== 'undefined') ? self : this;
    if (scope.__omDeepInstalled) return;
    scope.__omDeepInstalled = true;

    // 捕获原始引用（务必在覆盖前，内部一律用这些引用，避免 hook 自触发递归）
    var _JSONparse = JSON.parse;
    var _atob = (typeof scope.atob === 'function') ? scope.atob : null;
    var _fromCharCode = String.fromCharCode;
    var _arrJoin = Array.prototype.join;
    var _strIndexOf = String.prototype.indexOf;

    var RE_URL = /(?:https?:)?\/\/[^\s"'<>\\]+\.(?:m3u8|m3u|mpd|flv)(?:[?#][^\s"'<>\\]*)?/gi;
    var reHasScheme = /^[a-z][a-z0-9+.\-]*:/i;

    function isUrl(s){ return typeof s === 'string' && /^https?:\/\/.+/i.test(s); }
    function toAbs(u){
      // worker 场景把相对 url 修回绝对（origBase 为空则原样，主文档不受影响）
      if (!origBase || typeof u !== 'string' || u === '' || reHasScheme.test(u)) return u;
      try { return new URL(u, origBase).href; } catch(e) { return u; }
    }
    // 文本里的绝对/协议相对媒体地址全部捞出上报
    function extractUrls(text, via){
      if (!text || typeof text !== 'string') return;
      var m;
      RE_URL.lastIndex = 0;
      while ((m = RE_URL.exec(text)) !== null) {
        var u = m[0];
        if (u.substring(0, 2) === '//') {
          var proto = 'https:';
          try { proto = (scope.location && scope.location.protocol) || 'https:'; } catch(e) {}
          u = proto + u;
        }
        reportFn(u, via || 'scan');
      }
    }
    function scanText(text, method, srcUrl){
      if (!text || typeof text !== 'string') return;
      if (text.length > MAX_SCAN) text = text.substring(0, MAX_SCAN);
      // GET 响应本身是清单：直接上报来源地址（播放器按来源解析相对分片，最稳）
      if (srcUrl && (method === undefined || method === 'GET')) {
        if (text.substring(0, 7) === '#EXTM3U' ||
            text.toLowerCase().indexOf('urn:mpeg:dash:schema:mpd') >= 0) {
          reportFn(srcUrl, 'resp');
          return;
        }
      }
      extractUrls(text, 'scan');
      if (text.charAt(0) === '{' || text.charAt(0) === '[') {
        var j = null;
        try { j = _JSONparse(text); } catch(e) {}
        if (j) walkJson(j, 0);
      }
    }
    function walkJson(data, depth){
      if (!data || typeof data !== 'object' || depth > 12) return;
      for (var key in data) {
        var v;
        try { v = data[key]; } catch(e) { continue; }
        if (typeof v === 'object' && v !== null) { walkJson(v, depth + 1); continue; }
        if (typeof v === 'string') {
          if (isUrl(v) || v.substring(0, 2) === '//') { reportFn(v, 'json'); continue; }
          if (v.indexOf('#EXTM3U') >= 0 ||
              v.toLowerCase().indexOf('urn:mpeg:dash:schema:mpd') >= 0) {
            extractUrls(v, 'json');
          }
        }
      }
    }
    // 廉价二进制前缀判定：快速淘汰媒体分片（TS 同步字节 0x47 不在白名单）
    function looksTextual(ab){
      try {
        var n = ab.byteLength < 64 ? ab.byteLength : 64;
        var head = new Uint8Array(ab, 0, n);
        var c = -1;
        for (var i = 0; i < head.length; i++) {
          var b = head[i];
          if (b === 9 || b === 10 || b === 13 || b === 32 || b === 0xEF || b === 0xBB || b === 0xBF) continue;
          c = b; break;
        }
        if (c < 0) return false;
        return c === 35 || c === 123 || c === 91 || c === 60 ||
               c === 104 || c === 72 || c === 100 || c === 68 || c === 117 || c === 85;
      } catch(e) { return false; }
    }
    function scanArrayBuffer(ab, method, srcUrl){
      try {
        if (!ab || typeof ab.byteLength !== 'number') return;
        if (ab.byteLength === 0 || ab.byteLength > MAX_SCAN || !looksTextual(ab)) return;
        scanText(new TextDecoder().decode(ab), method, srcUrl);
      } catch(e) {}
    }
    function readBlob(blob, method, srcUrl){
      try {
        if (blob && typeof blob.arrayBuffer === 'function') {
          var b = (blob.size && blob.size > MAX_SCAN && typeof blob.slice === 'function')
              ? blob.slice(0, MAX_SCAN) : blob;
          b.arrayBuffer().then(function(ab){ scanArrayBuffer(ab, method, srcUrl); }).catch(function(){});
        }
      } catch(e) {}
    }
    function spoof(fn, original){
      try { fn.toString = function(){ return original.toString(); }; } catch(e) {}
    }

    // ==================== hook: JSON.parse ====================
    JSON.parse = function(){
      var data = _JSONparse.apply(this, arguments);
      try { walkJson(data, 0); } catch(e) {}
      return data;
    };
    spoof(JSON.parse, _JSONparse);

    // ==================== hook: XMLHttpRequest ====================
    if (typeof XMLHttpRequest !== 'undefined') {
      var _xhrOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url){
        try {
          if (typeof url === 'string') reportFn(toAbs(url), 'xhr');
          var upMethod = (method || 'GET').toUpperCase();
          this.addEventListener('readystatechange', function(){
            try {
              if (this.readyState !== 4 || this.status !== 200) return;
              var src = this.responseURL || undefined;
              var rt = this.responseType;
              if (rt === 'arraybuffer' && this.response) { scanArrayBuffer(this.response, upMethod, src); return; }
              if (rt === 'blob' && this.response) { readBlob(this.response, upMethod, src); return; }
              if (typeof this.response === 'string' && this.response !== '') {
                scanText(this.response, upMethod, src);
              }
            } catch(e) {}
          });
        } catch(e) {}
        if (origBase && arguments.length >= 2) arguments[1] = toAbs(url);
        return _xhrOpen.apply(this, arguments);
      };
      spoof(XMLHttpRequest.prototype.open, _xhrOpen);
    }

    // ==================== hook: fetch ====================
    // 克隆门控必须保守：直播分段/无限流（http-flv）一旦 clone().arrayBuffer()
    // 会被整段缓冲导致内存爆炸、页面卡死。只放行清单/JSON/文本类型；
    // octet-stream 仅在 content-length 明确且够小（可能是清单）时才克隆。
    function worthReading(response){
      try {
        var h = response.headers;
        if (!h || typeof h.get !== 'function') return false;
        var ct = (h.get('content-type') || '').toLowerCase();
        if (ct.indexOf('mpegurl') >= 0 || ct.indexOf('dash') >= 0 ||
            ct.indexOf('json') >= 0 || ct.indexOf('text') >= 0 ||
            ct.indexOf('xml') >= 0 || ct.indexOf('javascript') >= 0) return true;
        if (ct.indexOf('video/') >= 0 || ct.indexOf('audio/') >= 0 ||
            ct.indexOf('image/') >= 0 || ct.indexOf('font') >= 0 ||
            ct.indexOf('mp2t') >= 0) return false;
        var cl = parseInt(h.get('content-length') || '0', 10);
        return cl > 0 && cl <= MAX_SCAN;
      } catch(e) { return false; }
    }
    var _fetch = scope.fetch;
    if (typeof _fetch === 'function') {
      scope.fetch = function(input, init){
        try {
          var u = (typeof input === 'string') ? input : (input && input.url) ? input.url : null;
          if (u) reportFn(toAbs(u), 'fetch');
          if (origBase && typeof input === 'string') {
            var abs = toAbs(input);
            if (abs !== input) { input = abs; arguments[0] = abs; }
          }
        } catch(e) {}
        var p = _fetch.apply(this, arguments);
        try {
          p.then(function(response){
            try {
              if (!worthReading(response)) return;
              var src = response.url || (typeof input === 'object' ? input.url : input);
              var method = (init && init.method) ? init.method.toUpperCase() : 'GET';
              response.clone().arrayBuffer().then(function(ab){ scanArrayBuffer(ab, method, src); }).catch(function(){});
            } catch(e) {}
          }).catch(function(){});
        } catch(e) {}
        return p;
      };
      spoof(scope.fetch, _fetch);
    }

    // ==================== hook: WebSocket（部分站点用 WS 下发清单）====================
    try {
      var _WS = scope.WebSocket;
      if (_WS && !_WS.__omDeepHooked) {
        var handleWsData = function(d){
          try {
            if (typeof d === 'string') scanText(d, 'GET');
            else if (d instanceof ArrayBuffer) scanArrayBuffer(d, 'GET');
            else if (typeof Blob !== 'undefined' && d instanceof Blob) readBlob(d, 'GET');
          } catch(e) {}
        };
        var NewWS = function(url, protocols){
          var ws = arguments.length > 1 ? new _WS(url, protocols) : new _WS(url);
          try { ws.addEventListener('message', function(ev){ handleWsData(ev.data); }); } catch(e) {}
          return ws;
        };
        NewWS.prototype = _WS.prototype;
        NewWS.__omDeepHooked = true;
        ['CONNECTING','OPEN','CLOSING','CLOSED'].forEach(function(k){
          try { NewWS[k] = _WS[k]; } catch(e) {}
        });
        scope.WebSocket = NewWS;
        spoof(NewWS, _WS);
      }
    } catch(e) {}

    // ==================== hook: URL.createObjectURL(Blob) 前端合成清单 ====================
    try {
      if (typeof URL !== 'undefined' && URL.createObjectURL && !URL.createObjectURL.__omDeepHooked) {
        var _createObjURL = URL.createObjectURL;
        var wrapCreate = function(obj){
          try {
            if (typeof Blob !== 'undefined' && obj instanceof Blob) {
              var t = (obj.type || '').toLowerCase();
              if (t === '' || t.indexOf('mpegurl') >= 0 || t.indexOf('dash') >= 0 ||
                  t.indexOf('octet-stream') >= 0 || t.indexOf('video') >= 0 ||
                  t.indexOf('mp2t') >= 0) {
                readBlob(obj, 'GET');
              }
            }
          } catch(e) {}
          return _createObjURL.apply(this, arguments);
        };
        wrapCreate.__omDeepHooked = true;
        URL.createObjectURL = wrapCreate;
        spoof(wrapCreate, _createObjURL);
      }
    } catch(e) {}

    // ==================== hook: HTMLMediaElement.src / setAttribute（仅主文档有 DOM）====================
    function handleMediaSrc(v){
      if (!v || typeof v !== 'string') return;
      if (v.substring(0, 5) === 'blob:' || v.substring(0, 11) === 'javascript:') return;
      reportFn(v, 'video');
    }
    try {
      if (typeof HTMLMediaElement !== 'undefined') {
        var proto = HTMLMediaElement.prototype;
        var desc = Object.getOwnPropertyDescriptor(proto, 'src');
        if (desc && desc.set && !proto.__omDeepSrcHooked) {
          Object.defineProperty(proto, 'src', {
            configurable: true, enumerable: desc.enumerable, get: desc.get,
            set: function(v){ try { handleMediaSrc(v); } catch(e) {} return desc.set.call(this, v); }
          });
          proto.__omDeepSrcHooked = true;
        }
      }
      if (typeof Element !== 'undefined' && Element.prototype.setAttribute && !Element.prototype.__omDeepSetAttrHooked) {
        var _setAttr = Element.prototype.setAttribute;
        Element.prototype.setAttribute = function(name, value){
          try {
            if (name && name.toLowerCase() === 'src') {
              var tag = this.tagName;
              if (tag === 'VIDEO' || tag === 'SOURCE' || tag === 'AUDIO') handleMediaSrc(value);
            }
          } catch(e) {}
          return _setAttr.apply(this, arguments);
        };
        Element.prototype.__omDeepSetAttrHooked = true;
        spoof(Element.prototype.setAttribute, _setAttr);
      }
    } catch(e) {}

    // ==================== hook: TextDecoder.decode（清单流式解码）====================
    try {
      if (typeof TextDecoder !== 'undefined' && !TextDecoder.prototype.__omDeepHooked) {
        var _decode = TextDecoder.prototype.decode;
        TextDecoder.prototype.decode = function(){
          var result = _decode.apply(this, arguments);
          try {
            if (typeof result === 'string' && result.substring(0, 7) === '#EXTM3U') {
              extractUrls(result, 'decode');
            }
          } catch(e) {}
          return result;
        };
        TextDecoder.prototype.__omDeepHooked = true;
        spoof(TextDecoder.prototype.decode, _decode);
      }
    } catch(e) {}

    // ==================== hook: String.fromCharCode（逐字符拼清单）====================
    try {
      var m3u8Buf = '';
      String.fromCharCode = function(){
        var data = _fromCharCode.apply(null, arguments);
        var L = data.length;
        if (L >= 7) {
          var isM3u = (data.charCodeAt(0) === 35 && data.substring(0, 7) === '#EXTM3U')
              || data.indexOf('#EXTINF:') >= 0;
          if (isM3u) {
            try {
              m3u8Buf += data;
              if (m3u8Buf.indexOf('#EXT-X-ENDLIST') >= 0) {
                extractUrls(m3u8Buf.split('#EXT-X-ENDLIST')[0], 'fcc');
                m3u8Buf = '';
              } else if (m3u8Buf.length > 2 * 1024 * 1024) {
                // 直播清单无 ENDLIST：达上限发一次再清空，防内存泄漏
                extractUrls(m3u8Buf, 'fcc');
                m3u8Buf = '';
              }
            } catch(e) {}
          }
        }
        return data;
      };
      spoof(String.fromCharCode, _fromCharCode);
    } catch(e) {}

    // ==================== hook: Array.prototype.join（拼装清单）====================
    try {
      Array.prototype.join = function(sep){
        var data = _arrJoin.call(this, sep);
        if (data.length >= 7 && data.charCodeAt(0) === 35 && data.substring(0, 7) === '#EXTM3U') {
          try { extractUrls(data, 'join'); } catch(e) {}
        }
        return data;
      };
      spoof(Array.prototype.join, _arrJoin);
    } catch(e) {}

    // ==================== hook: String.prototype.indexOf（页面自查 '#EXTM3U'）====================
    try {
      String.prototype.indexOf = function(searchValue, fromIndex){
        var out = _strIndexOf.call(this, searchValue, fromIndex);
        if (out !== -1 && searchValue === '#EXTM3U') {
          try { extractUrls(this.substring(out), 'idx'); } catch(e) {}
        }
        return out;
      };
      spoof(String.prototype.indexOf, _strIndexOf);
    } catch(e) {}

    // ==================== hook: atob（base64 解码出清单/地址）====================
    try {
      if (_atob) {
        scope.atob = function(){
          var data = _atob.apply(this, arguments);
          try {
            if (typeof data === 'string' && data.length < MAX_SCAN &&
                (data.indexOf('#EXTM3U') >= 0 || data.indexOf('//') >= 0)) {
              extractUrls(data, 'atob');
            }
          } catch(e) {}
          return data;
        };
        spoof(scope.atob, _atob);
      }
    } catch(e) {}

    // ==================== hook: Worker（清单解析/解密在 worker 线程的播放器）====================
    try {
      if (typeof scope.Worker === 'function' && !scope.Worker.__omDeepHooked && installSource) {
        var _Worker = scope.Worker;
        var resolveBase = origBase || (scope.location && scope.location.href) || undefined;
        var absOf = function(u){
          try { return new URL(u, resolveBase).href; } catch(e) { return '' + u; }
        };
        var reporterSrc = "function(u,v){try{self.postMessage({__omDeepMsg:1,u:u,via:v});}catch(_){}}";
        // importScripts 修复 shim：blob 重建后 self.location 变 blob:，
        // 相对 importScripts 会 404，按原始脚本目录解析成绝对地址
        var buildPrelude = function(absUrl){
          var shim = "(function(){try{var _i=self.importScripts;" +
            "if(typeof _i==='function'&&!self.importScripts.__omFixed){" +
            "var B=" + JSON.stringify(absUrl) + ";" +
            "var f=function(){var a=[];for(var i=0;i<arguments.length;i++){" +
            "try{a.push(new URL(arguments[i],B).href);}catch(e){a.push(arguments[i]);}}" +
            "return _i.apply(self,a);};f.__omFixed=1;self.importScripts=f;}}catch(e){}})();";
          return shim + "(" + installSource + ")(" + reporterSrc + "," +
            JSON.stringify(installSource) + "," + JSON.stringify(absUrl) + ");\n";
        };
        var forward = function(worker){
          try {
            worker.addEventListener('message', function(ev){
              var m = ev && ev.data;
              if (m && m.__omDeepMsg === 1) {
                try { reportFn(m.u, m.via); } catch(_) {}
              }
            });
          } catch(e) {}
        };
        var NewWorker = function(scriptURL, options){
          // module worker 无法用 blob 重建保留导入说明符 → 回退原生（不注入）
          if (options && options.type === 'module') {
            return arguments.length > 1 ? new _Worker(scriptURL, options) : new _Worker(scriptURL);
          }
          try {
            var absUrl = absOf(scriptURL);
            var xhr = new XMLHttpRequest();
            xhr.open('GET', absUrl, false);
            xhr.send();
            if (xhr.status === 200 || xhr.status === 0) {
              var blob = new Blob([buildPrelude(absUrl), xhr.responseText || xhr.response || ''],
                  {type: 'text/javascript'});
              var w = new _Worker(URL.createObjectURL(blob), options);
              forward(w);
              return w;
            }
          } catch(e) {}
          // 跨域/同步取脚本失败：回退原生 Worker（不注入，仅挂转发监听，无副作用）
          var raw = arguments.length > 1 ? new _Worker(scriptURL, options) : new _Worker(scriptURL);
          forward(raw);
          return raw;
        };
        try { NewWorker.prototype = _Worker.prototype; } catch(e) {}
        NewWorker.__omDeepHooked = true;
        scope.Worker = NewWorker;
        spoof(NewWorker, _Worker);
      }
    } catch(e) {}

    // ==================== 扫内联 <script> 里的硬编码地址（仅主文档）====================
    try {
      if (typeof document !== 'undefined' && typeof document.querySelectorAll === 'function') {
        var scanInlineScripts = function(){
          try {
            var scripts = document.querySelectorAll('script:not([src])');
            for (var i = 0; i < scripts.length; i++) {
              var txt = scripts[i].textContent;
              if (txt) extractUrls(txt, 'inline');
            }
          } catch(e) {}
        };
        if (document.readyState === 'interactive' || document.readyState === 'complete') {
          scanInlineScripts();
        } else if (typeof document.addEventListener === 'function') {
          document.addEventListener('DOMContentLoaded', scanInlineScripts);
        }
      }
    } catch(e) {}
  }

  // 主文档安装：注入 omStream 上报出口 + 安装器自身源码（供 Worker 复制）
  installDeep(function(u, via){ report(u, via); }, installDeep.toString(), null);

  // ==================== 主文档补充：Shadow DOM video / 资源计时 / iframe 兜底 ====================
  function collectMediaEl(el){
    try {
      var s = el.currentSrc || el.src;
      if (s) report(s, 'video');
      if (!el.querySelectorAll) return;
      var sources = el.querySelectorAll('source');
      for (var i = 0; i < sources.length; i++) {
        report(sources[i].src || sources[i].getAttribute('src'), 'video');
      }
    } catch(e) {}
  }
  function walkShadow(root){
    if (!root || !root.querySelectorAll) return;
    try {
      var media = root.querySelectorAll('video, audio');
      for (var i = 0; i < media.length; i++) collectMediaEl(media[i]);
      var all = root.querySelectorAll('*');
      for (var j = 0; j < all.length; j++) {
        if (all[j].shadowRoot) walkShadow(all[j].shadowRoot);
      }
    } catch(e) {}
  }
  function scanDom(){ try { walkShadow(document); } catch(e) {} }
  // 嗅探脚本安装之前页面已发出的媒体请求：从资源计时补捞
  function scanPerf(){
    try {
      var es = performance.getEntriesByType('resource');
      for (var i = 0; i < es.length; i++) report(es[i].name, 'perf');
    } catch(e) {}
  }
  if (document.readyState === 'interactive' || document.readyState === 'complete') {
    scanDom();
  } else {
    document.addEventListener('DOMContentLoaded', scanDom);
  }
  scanPerf();
  setInterval(scanPerf, 1500);
  // <video> 可能晚于本脚本创建（含 Shadow DOM），但 Shadow 全遍历
  // （querySelectorAll('*')）开销大，只在加载后 60 秒窗口内做；
  // 之后退回轻量的 video-only 扫描（与旧版一致），避免弹幕/动态页
  // 长期触发全量遍历导致掉帧卡死
  function scanVideosLight(){
    try {
      var vs = document.querySelectorAll('video');
      for (var i = 0; i < vs.length; i++) collectMediaEl(vs[i]);
      var fs = document.querySelectorAll('iframe');
      for (var j = 0; j < fs.length; j++) {
        try {
          var d = fs[j].contentDocument;
          if (d) {
            var ivs = d.querySelectorAll('video');
            for (var k = 0; k < ivs.length; k++) collectMediaEl(ivs[k]);
          }
        } catch(e) {}
      }
    } catch(e) {}
  }
  var domScans = 0;
  var mo = null;
  var domTimer = setInterval(function(){
    domScans++;
    if (domScans >= 60) {
      try { clearInterval(domTimer); } catch(e) {}
      try { if (mo) mo.disconnect(); } catch(e) {}
      // 窗口期结束：切换为轻量扫描，长期运行
      setInterval(scanVideosLight, 2000);
      scanVideosLight();
      return;
    }
    scanDom();
  }, 1000);
  try {
    if (typeof MutationObserver === 'function' && document.documentElement) {
      var moPending = false;
      mo = new MutationObserver(function(){
        if (moPending) return;
        moPending = true;
        setTimeout(function(){ moPending = false; scanDom(); }, 300);
      });
      mo.observe(document.documentElement,
          {childList: true, subtree: true, attributes: true, attributeFilter: ['src']});
    }
  } catch(e) {}

  // 同源 iframe 兜底：document-start 注入在不支持的平台上可能只进主框架，
  // 从父侧给子框架补装轻量 XHR/fetch 钩子（完整安装由各框架自身的
  // document-start 注入完成，__omSniffed 哨兵防重；跨域访问即抛异常，静默跳过）
  function installFrame(iw){
    try {
      if (!iw || iw.__omSniffed) return;
      iw.__omSniffed = true;
      var XO = iw.XMLHttpRequest && iw.XMLHttpRequest.prototype.open;
      if (XO) {
        iw.XMLHttpRequest.prototype.open = function(method, url){
          try { report(url, 'xhr', iw.location.href); } catch(e) {}
          return XO.apply(this, arguments);
        };
      }
      var of = iw.fetch;
      if (of) {
        iw.fetch = function(input, init){
          try {
            var u = (typeof input === 'string') ? input
                : (input && input.url) ? input.url : null;
            if (u) report(u, 'fetch', iw.location.href);
          } catch(e) {}
          return of.apply(this, arguments);
        };
      }
    } catch(e) {}
  }
  function walkFrames(){
    try {
      var fs = document.querySelectorAll('iframe,frame');
      for (var i = 0; i < fs.length; i++) {
        try { var iw = fs[i].contentWindow; if (iw) installFrame(iw); } catch(e) {}
      }
    } catch(e) {}
  }
  walkFrames();
  setInterval(walkFrames, 2000);
})();
''';

  @override
  void initState() {
    super.initState();
    // 每次打开网页频道前清理 WebView2 缓存，避免旧频道的 Service Worker
    // 或残留状态导致新频道黑屏/长时间不播放
    cleanWebView2Cache();
    // 后台缓冲期间持续探测；正常页起播后不立即推前台，等嗅探决策
    _probeTimer = Timer.periodic(const Duration(seconds: 1), (_) => _probe());
    // 8 秒兜底：已知放弃页直接推网页；正常页若网页自身也没起播
    //（站点需手动点播放/卡住），提前推网页避免长时间黑屏；
    // 网页已起播则继续等嗅探决策
    _forceForegroundTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || widget.foreground) return;
      if (_sniffAbandoned || !_webPlayReady) widget.onForeground();
    });
    // 最终决策窗口：15 秒仍无可直连主流 → 加密/无流，直接网页全屏
    _decisionTimer = Timer(const Duration(seconds: 15), _finishWithWeb);
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
    _decisionTimer?.cancel();
    _webReadyGraceTimer?.cancel();
    _runtimeTimer?.cancel();
    _sniffAggTimer?.cancel();
    _sniffDeadline?.cancel();
    super.dispose();
  }

  Future<void> _inject() async {
    final c = _webController;
    if (c == null) return;
    try {
      await c.evaluateJavascript(source: _noContextMenuJs);
      await c.evaluateJavascript(source: _cssJs);
      await c.evaluateJavascript(source: _bootJs);
      await c.evaluateJavascript(source: _sniffJs);
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
        if (_sniffAbandoned) {
          // 已知放弃页：起播即推网页
          widget.onForeground();
        } else {
          // 正常页：先记录起播，由嗅探决策决定内置接管还是网页全屏，
          // 不提前显露网页，避免「先网页再跳内置」的多余切换
          _markWebPlayReady();
        }
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
          // 深度嗅探脚本必须在页面其他 JS 之前注入，否则页面已持有
          // 原始 fetch/JSON.parse 引用，hook 无效；运行时 _inject()
          // 重注入作为不支持 document-start 平台的兜底（哨兵防重）
          initialUserScripts: UnmodifiableListView<UserScript>([
            UserScript(
              source: _sniffJs,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              forMainFrameOnly: false,
            ),
          ]),
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
            // 内置播放失败回退过、或用户手动选择网页观看的页面，
            // 本次运行不再尝试自动接管（起播即推网页前台）
            _sniffAbandoned = context
                .read<PlayerController>()
                .shouldSkipAutoSniff(widget.url);
            // 把 controller 存到 PlayerController，供 Dart 侧调用网页 JS
            context.read<PlayerController>().webController = controller;
            // JS bridge 通道
            controller.addJavaScriptHandler(
              handlerName: 'omPlaying',
              callback: (_) {
                if (!mounted || widget.foreground) return;
                if (_sniffAbandoned) {
                  widget.onForeground();
                } else {
                  _markWebPlayReady();
                }
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
            // 网页 XHR/fetch 嗅探到的真实媒体流（芒果TV 等）
            controller.addJavaScriptHandler(
              handlerName: 'omStream',
              callback: (args) {
                if (args.isNotEmpty) _onSniffedStream(args.first);
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

/// 退出确认面板的一个操作项（方块图标按钮）
class _ExitOption {
  final IconData icon;
  final String label;
  final Color color;
  const _ExitOption(this.icon, this.label, this.color);
}

/// 网页嗅探到的媒体流候选（XHR/fetch 命中聚合）
class _SniffCandidate {
  final String url;
  String kind; // hls / dash / flv
  final String? referer;
  final String? ua;
  int count = 0;
  DateTime last;
  _SniffCandidate({
    required this.url,
    required this.kind,
    required this.referer,
    required this.ua,
  }) : last = DateTime.now();
}
