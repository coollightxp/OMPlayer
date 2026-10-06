import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../models/epg_program.dart';
import '../services/player_controller.dart';
import 'scaled_panel.dart';

/// 左侧三级抽屉：分类 / 频道 / EPG 节目单
/// - L1 首位固定「我的收藏」虚拟分类，其后为未隐藏的真实分类
/// - L2 上下移动只刷新 L3 不播放；OK 短按播放并关闭，长按 500ms 收藏/取消
/// - L3 顶部日期选择条 + 当日节目列表；节目行五级状态：
///   直播 / 预约 / 已预约 / 已播放(灰) / 回看
class ChannelEpgDrawer extends StatefulWidget {
  final bool isOpen;
  final VoidCallback onClose;

  /// 鼠标悬停回调（悬停期间不自动隐藏面板）
  final VoidCallback? onHoverEnter;
  final VoidCallback? onHoverExit;
  final VoidCallback? onHoverMove;

  /// 播放频道后回调（重置光标隐藏定时器等）
  final VoidCallback? onChannelTap;

  /// 空源状态下「去设置添加」回调
  final VoidCallback? onOpenSettings;

  /// 中央 OSD 消息提示（收藏/预约/回看结果等），替代底部 SnackBar
  final void Function(String message)? onShowMessage;

  const ChannelEpgDrawer({
    super.key,
    required this.isOpen,
    required this.onClose,
    this.onHoverEnter,
    this.onHoverExit,
    this.onHoverMove,
    this.onChannelTap,
    this.onOpenSettings,
    this.onShowMessage,
  });

  @override
  State<ChannelEpgDrawer> createState() => ChannelEpgDrawerState();
}

class ChannelEpgDrawerState extends State<ChannelEpgDrawer> {
  // ===== 布局常量（设计尺寸，缩放交给 ScaledPanel）=====
  static const double _designWidth = 780;
  static const double _catColWidth = 112;
  static const double _chColWidth = 240;
  static const double _dateBarHeight = 54;

  /// 当前焦点层级：1 分类 / 2 频道 / 3 节目单
  int _level = 2;

  /// L1 选中索引：0=我的收藏，1..=visibleCategories[i-1]
  int _kbCatIndex = 0;
  int _kbChannelIndex = 0;

  /// L3 焦点是否在日期条（false=节目列表）
  bool _epgFocusDate = false;
  int _kbDateIndex = 0;
  int _kbProgIndex = 0;

  /// EPG 选中节目稳定标识（频道ID@开始时间毫秒），防 EPG 刷新漂移
  String? _kbProgKey;

  /// L3 已按哪个频道初始化（切换 L2 频道后置空以重置 今天/当前节目）
  String? _epgInitChannelId;

  // ===== 滚动与定位 =====
  final ScrollController _catScroll = ScrollController();
  final ScrollController _chScroll = ScrollController();
  final ScrollController _progScroll = ScrollController();
  final ScrollController _dateScroll = ScrollController();
  final List<GlobalKey> _catKeys = <GlobalKey>[];
  final List<GlobalKey> _chKeys = <GlobalKey>[];
  final List<GlobalKey> _progKeys = <GlobalKey>[];
  final List<GlobalKey> _dateKeys = <GlobalKey>[];

  // ===== L2 OK 短按/长按 =====
  Timer? _okLongTimer;
  bool _okLongFired = false;
  /// L2 是否收到过本次 OK 的按下沿：无配对 down 的孤立 up
  /// （如底部面板按 OK 打开抽屉后的抬起）不得触发播放
  bool _l2OkDown = false;
  DateTime? _lastPlayAt;

  // ===== L3 OK 按住去重 / 防抖 =====
  bool _epgOkHeld = false;
  DateTime? _lastEpgActionAt;

  static const _weekNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  static String _programKey(EpgProgram p) =>
      '${p.channelId}@${p.startTime.millisecondsSinceEpoch}';

  @override
  void dispose() {
    _okLongTimer?.cancel();
    _catScroll.dispose();
    _chScroll.dispose();
    _progScroll.dispose();
    _dateScroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ChannelEpgDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isOpen && widget.isOpen) {
      _initOnOpen();
    }
  }

  /// 打开时定位：当前分类 → 当前频道 → 今天 → 当前节目，焦点落在 L2
  void _initOnOpen() {
    _okLongTimer?.cancel();
    _okLongFired = false;
    _l2OkDown = false;
    _epgOkHeld = false;
    _catKeys.clear();
    _chKeys.clear();
    _progKeys.clear();
    _dateKeys.clear();

    final controller = context.read<PlayerController>();
    final cats = controller.visibleCategories;
    final cur = controller.currentChannel;

    var catIndex = cats.isEmpty ? 0 : 1;
    var chIndex = 0;
    if (cur != null) {
      // 收藏夹优先
      final favs = controller.buildFavoriteChannels();
      final fi = favs.indexWhere((ch) => ch.id == cur.id);
      if (fi >= 0) {
        catIndex = 0;
        chIndex = fi;
      } else {
        for (var ci = 0; ci < cats.length; ci++) {
          final idx = cats[ci].channels.indexWhere((ch) => ch.id == cur.id);
          if (idx >= 0) {
            catIndex = ci + 1;
            chIndex = idx;
            break;
          }
        }
      }
    }
    // 当前分类被隐藏且当前频道不在收藏：默认进第一个真实分类
    if (catIndex == 1 && cats.isEmpty) catIndex = 0;

    _level = 2;
    _kbCatIndex = catIndex;
    _kbChannelIndex = chIndex;
    _epgFocusDate = false;
    _kbDateIndex = 0;
    _kbProgIndex = 0;
    _kbProgKey = null;
    _epgInitChannelId = null;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureVisible(_catScroll, _catKeys, _kbCatIndex, est: 64);
      _ensureVisible(_chScroll, _chKeys, _kbChannelIndex, est: 64);
    });
  }

  // ================= 数据派生 =================

  List<Channel> _channelsOf(PlayerController c, int catIndex) {
    if (catIndex == 0) return c.buildFavoriteChannels();
    final cats = c.visibleCategories;
    final i = catIndex - 1;
    if (i < 0 || i >= cats.length) return const [];
    return cats[i].channels;
  }

  Channel? _focusedChannel(PlayerController c) {
    final channels = _channelsOf(c, _kbCatIndex);
    if (_kbChannelIndex < 0 || _kbChannelIndex >= channels.length) return null;
    return channels[_kbChannelIndex];
  }

  /// L3 可选日期：节目数据覆盖的自然日 ∪ 今天，受 catchup-days 回看窗口约束
  List<DateTime> _datesFor(Channel? channel, List<EpgProgram> programs) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime? lower;
    final days = channel?.catchupDays;
    if (days != null && days > 0) {
      lower = today.subtract(Duration(days: days));
    }
    final set = <DateTime>{today};
    for (final p in programs) {
      final d = DateTime(p.startTime.year, p.startTime.month, p.startTime.day);
      if (lower != null && d.isBefore(lower)) continue;
      set.add(d);
    }
    final list = set.toList()..sort();
    return list;
  }

  List<EpgProgram> _programsOfDay(List<EpgProgram> all, DateTime day) {
    final next = day.add(const Duration(days: 1));
    return all
        .where((p) =>
            !p.startTime.isBefore(day) && p.startTime.isBefore(next))
        .toList(growable: false);
  }

  /// L2 焦点变化：重置 L3（切频道/重开抽屉日期重置为今天）
  void _channelFocusChanged() {
    _epgInitChannelId = null;
    _epgFocusDate = false;
    _kbDateIndex = 0;
    _kbProgIndex = 0;
    _kbProgKey = null;
  }

  /// 鼠标悬停某个 L2 频道：与遥控器上下移动完全同效——框选频道、
  /// 焦点落到 L2、右侧 EPG 同步刷新，但不播放（点击才播放）
  void _hoverSelectChannel(List<Channel> channels, int index) {
    if (!mounted || channels.isEmpty) return;
    final target = index.clamp(0, channels.length - 1);
    if (_level == 2 && _kbChannelIndex == target) return;
    setState(() {
      _level = 2;
      _kbChannelIndex = target;
      _channelFocusChanged();
    });
    _ensureVisible(_chScroll, _chKeys, target, est: 64);
  }

  // ================= 按键入口 =================

  /// 遥控器/键盘按键入口（PlayerScreen 统一分发，Windows 低级钩子
  /// 与 HardwareKeyboard 走同一入口）。
  /// action: up/down/left/right/ok/back；ok 同时消费按下与抬起沿。
  void handleRemoteKey(String action, {required bool isDown}) {
    if (!widget.isOpen || !mounted) return;
    if (action == 'back') {
      if (isDown) _handleBack();
      return;
    }
    if (action == 'ok') {
      _handleOk(isDown);
      return;
    }
    if (!isDown) return;
    final c = context.read<PlayerController>();
    switch (_level) {
      case 1:
        _keyLevel1(action, c);
        break;
      case 2:
        _keyLevel2(action, c);
        break;
      default:
        _keyLevel3(action, c);
    }
  }

  void _handleBack() {
    _okLongTimer?.cancel();
    _l2OkDown = false;
    _epgOkHeld = false;
    if (_level == 3) {
      setState(() => _level = 2);
    } else if (_level == 2) {
      setState(() => _level = 1);
    } else {
      widget.onClose();
    }
  }

  void _handleOk(bool isDown) {
    final c = context.read<PlayerController>();
    if (_level == 1) {
      if (isDown) _enterCategory(c);
      return;
    }
    if (_level == 2) {
      final channels = _channelsOf(c, _kbCatIndex);
      if (channels.isEmpty) return;
      if (isDown) {
        // 长按 500ms：收藏/取消，不播放
        _l2OkDown = true;
        _okLongFired = false;
        _okLongTimer?.cancel();
        _okLongTimer = Timer(const Duration(milliseconds: 500), () {
          _okLongFired = true;
          final ch = channels[_kbChannelIndex.clamp(0, channels.length - 1)];
          _toggleFavorite(ch);
        });
      } else {
        final paired = _l2OkDown;
        _l2OkDown = false;
        _okLongTimer?.cancel();
        if (paired && !_okLongFired) _playFocusedChannel(c, channels);
      }
      return;
    }
    // L3：按下沿触发（预约/回看），按住去重 + 800ms 防抖
    if (!isDown) {
      _epgOkHeld = false;
      return;
    }
    if (_epgOkHeld) return;
    _epgOkHeld = true;
    if (_lastEpgActionAt != null &&
        DateTime.now().difference(_lastEpgActionAt!) <
            const Duration(milliseconds: 800)) {
      return;
    }
    _lastEpgActionAt = DateTime.now();
    _activateProgram(c);
  }

  void _keyLevel1(String action, PlayerController c) {
    final count = 1 + c.visibleCategories.length;
    switch (action) {
      case 'up':
        setState(() => _kbCatIndex = (_kbCatIndex - 1).clamp(0, count - 1));
        _ensureVisible(_catScroll, _catKeys, _kbCatIndex, est: 64);
        break;
      case 'down':
        setState(() => _kbCatIndex = (_kbCatIndex + 1).clamp(0, count - 1));
        _ensureVisible(_catScroll, _catKeys, _kbCatIndex, est: 64);
        break;
      case 'left':
        widget.onClose();
        break;
      case 'right':
        _enterCategory(c);
        break;
    }
  }

  void _enterCategory(PlayerController c) {
    final channels = _channelsOf(c, _kbCatIndex);
    // 进入分类默认选中当前播放频道，没有则第一条
    var idx = channels
        .indexWhere((ch) => ch.id == c.currentChannel?.id);
    if (idx < 0) idx = 0;
    setState(() {
      _level = 2;
      _kbChannelIndex = channels.isEmpty ? 0 : idx.clamp(0, channels.length - 1);
      _channelFocusChanged();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureVisible(_chScroll, _chKeys, _kbChannelIndex, est: 64);
      _scrollEpgToInitial();
    });
  }

  void _keyLevel2(String action, PlayerController c) {
    final channels = _channelsOf(c, _kbCatIndex);
    switch (action) {
      case 'up':
        if (channels.isEmpty) break;
        setState(() {
          _kbChannelIndex =
              (_kbChannelIndex - 1).clamp(0, channels.length - 1);
          _channelFocusChanged();
        });
        _ensureVisible(_chScroll, _chKeys, _kbChannelIndex, est: 64);
        break;
      case 'down':
        if (channels.isEmpty) break;
        setState(() {
          _kbChannelIndex =
              (_kbChannelIndex + 1).clamp(0, channels.length - 1);
          _channelFocusChanged();
        });
        _ensureVisible(_chScroll, _chKeys, _kbChannelIndex, est: 64);
        break;
      case 'left':
        _l2OkDown = false;
        setState(() => _level = 1);
        break;
      case 'right':
        if (channels.isEmpty) break;
        _l2OkDown = false;
        setState(() {
          _level = 3;
          _channelFocusChanged();
        });
        WidgetsBinding.instance.addPostFrameCallback(_scrollEpgToInitial);
        break;
    }
  }

  void _keyLevel3(String action, PlayerController c) {
    final ch = _focusedChannel(c);
    if (ch == null) return;
    final all = c.sourceManager.getProgramsForChannel(ch);
    final dates = _datesFor(ch, all);
    if (dates.isEmpty) return;
    if (_kbDateIndex < 0 || _kbDateIndex >= dates.length) {
      _kbDateIndex = 0;
    }
    final dayPrograms = _programsOfDay(all, dates[_kbDateIndex]);

    if (_epgFocusDate) {
      // ===== 日期条 =====
      switch (action) {
        case 'left':
          if (_kbDateIndex > 0) {
            setState(() {
              _kbDateIndex--;
              _resetProgForDay(
                  _programsOfDay(all, dates[_kbDateIndex]));
            });
            _ensureVisible(_dateScroll, _dateKeys, _kbDateIndex,
                est: 76);
          }
          break;
        case 'right':
          if (_kbDateIndex < dates.length - 1) {
            setState(() {
              _kbDateIndex++;
              _resetProgForDay(
                  _programsOfDay(all, dates[_kbDateIndex]));
            });
            _ensureVisible(_dateScroll, _dateKeys, _kbDateIndex,
                est: 76);
          }
          break;
        case 'down':
          if (dayPrograms.isNotEmpty) {
            setState(() => _epgFocusDate = false);
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _ensureVisible(
                    _progScroll, _progKeys, _kbProgIndex,
                    est: 64));
          }
          break;
        case 'up':
          break;
      }
      return;
    }

    // ===== 节目列表 =====
    switch (action) {
      case 'up':
        if (dayPrograms.isEmpty) break;
        // 向上跳过不支持回看的置灰节目；越过列表顶部 → 进入日期条
        var target = _kbProgIndex - 1;
        while (target >= 0 &&
            !_isProgramEnabled(c, ch, dayPrograms[target])) {
          target--;
        }
        if (target < 0) {
          setState(() => _epgFocusDate = true);
          WidgetsBinding.instance.addPostFrameCallback((_) => _ensureVisible(
              _dateScroll, _dateKeys, _kbDateIndex,
              est: 76));
        } else {
          setState(() => _kbProgIndex = target);
          _kbProgKey = _programKey(dayPrograms[target]);
          _ensureVisible(_progScroll, _progKeys, target, est: 64);
        }
        break;
      case 'down':
        if (dayPrograms.isEmpty) break;
        // 向下跳过不支持回看的置灰节目；到底则停住
        var target = _kbProgIndex + 1;
        while (target < dayPrograms.length &&
            !_isProgramEnabled(c, ch, dayPrograms[target])) {
          target++;
        }
        if (target < dayPrograms.length) {
          setState(() => _kbProgIndex = target);
          _kbProgKey = _programKey(dayPrograms[target]);
          _ensureVisible(_progScroll, _progKeys, target, est: 64);
        }
        break;
      case 'left':
        setState(() => _level = 2);
        break;
      case 'right':
        break;
    }
  }

  /// 切换日期后节目选中项重置：直播中→当前节目，否则首项
  void _resetProgForDay(List<EpgProgram> dayPrograms) {
    _kbProgIndex = 0;
    _kbProgKey = null;
    if (dayPrograms.isNotEmpty) {
      final nowIdx = dayPrograms.indexWhere((p) => p.isNowPlaying);
      if (nowIdx >= 0) _kbProgIndex = nowIdx;
      _kbProgKey = _programKey(dayPrograms[_kbProgIndex]);
    }
  }

  // ================= L2 动作 =================

  void _playFocusedChannel(PlayerController c, List<Channel> channels) {
    if (channels.isEmpty) return;
    // 播放内核重建期间防抖
    if (_lastPlayAt != null &&
        DateTime.now().difference(_lastPlayAt!) <
            const Duration(milliseconds: 800)) {
      return;
    }
    final idx = _kbChannelIndex.clamp(0, channels.length - 1);
    _lastPlayAt = DateTime.now();
    c.playChannel(channels[idx]);
    widget.onChannelTap?.call();
    widget.onClose();
  }

  /// 统一消息提示：优先走屏幕中央 OSD（由播放页注入），
  /// 未注入时回退到底部 SnackBar
  void _showMsg(String text) {
    final cb = widget.onShowMessage;
    if (cb != null) {
      cb(text);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _toggleFavorite(Channel ch) async {
    final c = context.read<PlayerController>();
    final nowFav = await c.toggleFavoriteChannel(ch.id);
    if (!mounted) return;
    _showMsg(nowFav ? '已收藏：${ch.name}' : '已取消收藏：${ch.name}');
  }

  // ================= L3 动作（五级状态）=================

  /// 已播节目是否可回看：能构造出回看地址，且在 catchup-days 窗口内
  bool _canCatchup(Channel ch, EpgProgram p) {
    final url = ch.buildCatchupUrl(
      start: p.startTime,
      end: p.endTime,
      epgCatchupSource: p.catchupUrl,
    );
    if (url == null || url.isEmpty) return false;
    final days = ch.catchupDays;
    if (days != null && days > 0) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final lower = today.subtract(Duration(days: days));
      final day =
          DateTime(p.startTime.year, p.startTime.month, p.startTime.day);
      if (day.isBefore(lower)) return false;
    }
    return true;
  }

  /// 节目行是否可选择/操作。不支持回看的已播节目返回 false（置灰、跳过）。
  bool _isProgramEnabled(PlayerController c, Channel ch, EpgProgram p) {
    if (!p.isPast) return true; // 直播中 / 未播预约
    if (c.isReservationTriggered(p)) return true; // 已播放（仅提示）
    return _canCatchup(ch, p);
  }

  /// 返回当天第一个可操作节目的索引（优先直播中），没有则 0
  int _firstEnabledIndex(
      PlayerController c, Channel ch, List<EpgProgram> day) {
    final nowIdx = day.indexWhere((p) => p.isNowPlaying);
    if (nowIdx >= 0) return nowIdx;
    final i = day.indexWhere((p) => _isProgramEnabled(c, ch, p));
    return i < 0 ? 0 : i;
  }

  void _activateProgram(PlayerController c) {
    final ch = _focusedChannel(c);
    if (ch == null) return;
    final all = c.sourceManager.getProgramsForChannel(ch);
    final dates = _datesFor(ch, all);
    if (_kbDateIndex >= dates.length) return;
    final dayPrograms = _programsOfDay(all, dates[_kbDateIndex]);
    if (dayPrograms.isEmpty) return;
    final idx = _kbProgIndex.clamp(0, dayPrograms.length - 1);
    final p = dayPrograms[idx];

    if (p.isNowPlaying) {
      // 直播徽标：不操作
      return;
    }
    if (!p.isPast) {
      // 未播：预约 / 取消预约
      final reserved = c.isProgramReserved(p);
      c.toggleReservation(p);
      _showMsg(reserved
          ? '已取消预约：${p.title}'
          : '已预约：${p.title}，到时间将自动播放');
      return;
    }
    // 已播且预约已触发：灰态不可操作
    if (c.isReservationTriggered(p)) {
      _showMsg('预约已执行');
      return;
    }
    // 源不支持回看：行已置灰，理论上选不到；兜底提示
    if (!_canCatchup(ch, p)) {
      _showMsg('该节目暂不支持回看');
      return;
    }
    // 其余已播：回看
    _playCatchup(c, ch, p);
  }

  Future<void> _playCatchup(
      PlayerController c, Channel ch, EpgProgram p) async {
    final ok = await c.playCatchup(ch, p);
    if (!mounted) return;
    if (ok) {
      widget.onChannelTap?.call();
      widget.onClose();
    } else {
      _showMsg('该节目暂不支持回看');
    }
  }

  // ================= 滚动定位 =================

  /// 两阶段定位：GlobalKey 可用时 ensureVisible；ListView 懒加载
  /// 未构建时先按估算高度粗跳，下一帧再精准定位。
  void _ensureVisible(
    ScrollController sc,
    List<GlobalKey> keys,
    int index, {
    double est = 64,
    Duration duration = const Duration(milliseconds: 200),
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !sc.hasClients || index < 0 || index >= keys.length) {
        return;
      }
      final ctx = keys[index].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: duration, curve: Curves.easeOut, alignment: 0.5);
        return;
      }
      final pos = sc.position;
      final rough =
          (index * est - pos.viewportDimension / 2)
              .clamp(0.0, pos.maxScrollExtent);
      pos.jumpTo(rough);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !sc.hasClients || index >= keys.length) return;
        final c2 = keys[index].currentContext;
        if (c2 != null) {
          Scrollable.ensureVisible(c2,
              duration: duration, curve: Curves.easeOut, alignment: 0.5);
        }
      });
    });
  }

  /// 切频道/进入 L3 后：今天 + 当前节目定位
  void _scrollEpgToInitial([Object? _]) {
    if (!mounted) return;
    _ensureVisible(_dateScroll, _dateKeys, _kbDateIndex, est: 76);
    _ensureVisible(_progScroll, _progKeys, _kbProgIndex,
        est: 64, duration: const Duration(milliseconds: 300));
  }

  // ================= 构建 =================

  @override
  Widget build(BuildContext context) {
    final scale = panelScaleOf(context);
    final drawerW = _designWidth * scale;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
      left: widget.isOpen ? 0 : -drawerW,
      top: 0,
      bottom: 0,
      width: drawerW,
      child: MouseRegion(
        onEnter: (_) => widget.onHoverEnter?.call(),
        onExit: (_) => widget.onHoverExit?.call(),
        onHover: (_) => widget.onHoverMove?.call(),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: widget.isOpen ? 1.0 : 0.0,
          child: ScaledPanel(
            designWidth: _designWidth,
            alignment: Alignment.centerLeft,
            scale: scale,
            child: Material(
              color: Colors.black87,
              elevation: 16,
              child: SafeArea(
                child: Consumer<PlayerController>(
                  builder: (context, controller, _) => _buildBody(controller),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(PlayerController controller) {
    final cats = controller.visibleCategories;
    final channels = _channelsOf(controller, _kbCatIndex);
    // 索引钳制（收藏取消/源刷新后列表可能缩短）
    if (_kbChannelIndex > 0 && _kbChannelIndex >= channels.length) {
      _kbChannelIndex = channels.isEmpty ? 0 : channels.length - 1;
      _channelFocusChanged();
    }
    final catCount = 1 + cats.length;
    if (_kbCatIndex >= catCount) _kbCatIndex = catCount - 1;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ===== L1 分类 =====
        SizedBox(
          width: _catColWidth,
          child: _buildCategoryColumn(controller, cats, catCount),
        ),
        const VerticalDivider(width: 1, color: Colors.white12),
        // ===== L2 频道 =====
        SizedBox(
          width: _chColWidth,
          child: _buildChannelColumn(controller, channels),
        ),
        const VerticalDivider(width: 1, color: Colors.white12),
        // ===== L3 EPG =====
        Expanded(child: _buildEpgColumn(controller, channels)),
      ],
    );
  }

  // ---------- L1 ----------

  Widget _buildCategoryColumn(
      PlayerController c, List<ChannelCategory> cats, int count) {
    while (_catKeys.length < count) {
      _catKeys.add(GlobalKey());
    }
    if (_catKeys.length > count) _catKeys.removeRange(count, _catKeys.length);
    return ColoredBox(
      color: Colors.black.withOpacity(0.25),
      child: ListView.builder(
        controller: _catScroll,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: count,
        itemBuilder: (context, index) {
          final isFav = index == 0;
          final cat = isFav ? null : cats[index - 1];
          final name = isFav ? '我的收藏' : cat!.name;
          final n = isFav ? c.buildFavoriteChannels().length : cat!.channels.length;
          final selected = index == _kbCatIndex;
          final focused = selected && _level == 1;
          return _CatTile(
            key: _catKeys[index],
            icon: isFav ? Icons.favorite : Icons.category,
            iconColor: isFav ? Colors.redAccent : Colors.blueAccent,
            name: name,
            count: n,
            selected: selected,
            focused: focused,
            onTap: () {
              setState(() {
                _kbCatIndex = index;
                _level = 1;
              });
            },
          );
        },
      ),
    );
  }

  // ---------- L2 ----------

  Widget _buildChannelColumn(PlayerController c, List<Channel> channels) {
    if (_kbCatIndex == 0 && channels.isEmpty) {
      return const _EmptyHint(
        icon: Icons.favorite_border,
        text: '还没有收藏频道',
        sub: '在频道上长按 OK 键即可收藏',
      );
    }
    if (channels.isEmpty) {
      return _EmptyHint(
        icon: Icons.playlist_add,
        text: '该分类暂无频道',
        sub: '请在设置中添加节目源',
        actionLabel: '去设置添加',
        onAction: widget.onOpenSettings,
      );
    }
    while (_chKeys.length < channels.length) {
      _chKeys.add(GlobalKey());
    }
    if (_chKeys.length > channels.length) {
      _chKeys.removeRange(channels.length, _chKeys.length);
    }
    final cat = _kbCatIndex == 0 ? null : c.visibleCategories[_kbCatIndex - 1];
    // 跨可见分类全局序号偏移（与数字选台 flatChannels 口径一致）
    var globalOffset = 0;
    if (cat != null) {
      for (final cc in c.visibleCategories) {
        if (cc.id == cat.id) break;
        globalOffset += cc.channels.length;
      }
    }
    return ListView.builder(
      controller: _chScroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: channels.length,
      itemBuilder: (context, index) {
        final ch = channels[index];
        final number = _kbCatIndex == 0 ? index + 1 : globalOffset + index + 1;
        return MouseRegion(
          key: _chKeys[index],
          // 鼠标移入与遥控器上下同效：框选该频道并同步右侧 EPG（不播放）
          onEnter: (_) => _hoverSelectChannel(channels, index),
          child: _ChannelTile(
            channel: ch,
            number: number,
            isCurrent: c.currentChannel?.id == ch.id,
            isFavorite: c.isFavoriteChannel(ch.id),
            keyboardSelected: index == _kbChannelIndex && _level == 2,
            onTap: () {
              _kbChannelIndex = index;
              _playFocusedChannel(c, channels);
            },
            onLongPress: () => _toggleFavorite(ch),
          ),
        );
      },
    );
  }

  // ---------- L3 ----------

  Widget _buildEpgColumn(PlayerController c, List<Channel> channels) {
    final ch = channels.isEmpty ? null : channels[_kbChannelIndex.clamp(0, channels.length - 1)];
    if (ch == null) {
      return const ColoredBox(
        color: Colors.black26,
        child: _EmptyHint(icon: Icons.schedule, text: '暂无节目单'),
      );
    }
    final all = c.sourceManager.getProgramsForChannel(ch);
    final dates = _datesFor(ch, all);

    // 首次为该频道构建：默认今天 + 当前节目
    if (_epgInitChannelId != ch.id) {
      _epgInitChannelId = ch.id;
      _kbDateIndex = dates.indexWhere((d) =>
          d.year == DateTime.now().year &&
          d.month == DateTime.now().month &&
          d.day == DateTime.now().day);
      if (_kbDateIndex < 0) _kbDateIndex = 0;
      final dayPrograms =
          _programsOfDay(all, dates.isEmpty ? DateTime.now() : dates[_kbDateIndex]);
      _resetProgForDay(dayPrograms);
      WidgetsBinding.instance.addPostFrameCallback(_scrollEpgToInitial);
    }
    if (_kbDateIndex >= dates.length) _kbDateIndex = dates.length - 1;
    final day = dates[_kbDateIndex];
    final dayPrograms = _programsOfDay(all, day);

    // 选中节目按稳定身份对齐（EPG 刷新/裁剪防漂移）
    if (dayPrograms.isNotEmpty) {
      if (_kbProgKey != null) {
        final found =
            dayPrograms.indexWhere((p) => _programKey(p) == _kbProgKey);
        _kbProgIndex = found >= 0
            ? found
            : _kbProgIndex.clamp(0, dayPrograms.length - 1);
      }
      if (_kbProgIndex >= dayPrograms.length) {
        _kbProgIndex = dayPrograms.length - 1;
      }
      // 落在不支持回看的置灰节目上时，跳到当天首个可操作节目
      // （换日期/数据刷新后的兜底，保证选中项始终可选）
      if (!_isProgramEnabled(c, ch, dayPrograms[_kbProgIndex])) {
        _kbProgIndex = _firstEnabledIndex(c, ch, dayPrograms);
      }
      _kbProgKey = _programKey(dayPrograms[_kbProgIndex]);
    } else {
      _kbProgIndex = 0;
      _kbProgKey = null;
    }

    while (_dateKeys.length < dates.length) {
      _dateKeys.add(GlobalKey());
    }
    if (_dateKeys.length > dates.length) {
      _dateKeys.removeRange(dates.length, _dateKeys.length);
    }
    while (_progKeys.length < dayPrograms.length) {
      _progKeys.add(GlobalKey());
    }
    if (_progKeys.length > dayPrograms.length) {
      _progKeys.removeRange(dayPrograms.length, _progKeys.length);
    }

    return ColoredBox(
      color: Colors.black.withOpacity(0.18),
      child: Column(
        children: [
          _buildDateBar(dates),
          const Divider(height: 1, color: Colors.white12),
          Expanded(
            child: dayPrograms.isEmpty
                ? const _EmptyHint(
                    icon: Icons.event_busy,
                    text: '该日期暂无节目单',
                  )
                : _buildProgramList(c, ch, dayPrograms),
          ),
        ],
      ),
    );
  }

  Widget _buildDateBar(List<DateTime> dates) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    return SizedBox(
      height: _dateBarHeight,
      child: ListView.builder(
        controller: _dateScroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        itemCount: dates.length,
        itemBuilder: (context, index) {
          final d = dates[index];
          final isToday = d == today;
          final isTomorrow = d == tomorrow;
          final selected = index == _kbDateIndex;
          final focused = selected && _epgFocusDate && _level == 3;
          final mmdd =
              '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
          final label = isToday
              ? '今天'
              : isTomorrow
                  ? '明天'
                  : _weekNames[d.weekday - 1];
          return Padding(
            key: _dateKeys[index],
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onTap: () => setState(() {
                _kbDateIndex = index;
                _epgFocusDate = true;
                _level = 3;
              }),
              child: Container(
                width: 72,
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  color: selected
                      ? (isToday
                          ? Colors.redAccent.withOpacity(0.22)
                          : Colors.white.withOpacity(0.10))
                      : Colors.white.withOpacity(0.03),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: focused
                        ? Colors.white70
                        : (selected ? Colors.white38 : Colors.transparent),
                    width: focused ? 1.4 : 1,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(label,
                        style: TextStyle(
                          color: isToday && selected
                              ? Colors.redAccent
                              : Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        )),
                    const SizedBox(height: 1),
                    Text(mmdd,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildProgramList(
      PlayerController c, Channel ch, List<EpgProgram> programs) {
    return ListView.builder(
      controller: _progScroll,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: programs.length,
      itemBuilder: (context, index) {
        final p = programs[index];
        return _ProgramTile(
          key: _progKeys[index],
          program: p,
          keyboardSelected:
              index == _kbProgIndex && !_epgFocusDate && _level == 3,
          reserved: c.isProgramReserved(p),
          triggered: c.isReservationTriggered(p),
          enabled: _isProgramEnabled(c, ch, p),
          onAction: () {
            _kbProgIndex = index;
            _kbProgKey = _programKey(p);
            _activateProgram(c);
          },
        );
      },
    );
  }
}

// ================= 子组件 =================

class _CatTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String name;
  final int count;
  final bool selected;
  final bool focused;
  final VoidCallback onTap;

  const _CatTile({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.name,
    required this.count,
    required this.selected,
    required this.focused,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? Colors.white.withOpacity(0.10)
                : Colors.transparent,
            border: focused
                ? Border.all(color: Colors.white70, width: 1.4)
                : Border.all(
                    color: selected ? Colors.white24 : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              Icon(icon, size: 22, color: selected ? iconColor : Colors.white54),
              const SizedBox(height: 6),
              Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: selected ? Colors.white : Colors.white70,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              const SizedBox(height: 2),
              Text('$count',
                  style: const TextStyle(color: Colors.white38, fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final Channel channel;
  final int number;
  final bool isCurrent;
  final bool isFavorite;
  final bool keyboardSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ChannelTile({
    super.key,
    required this.channel,
    required this.number,
    required this.isCurrent,
    required this.isFavorite,
    required this.keyboardSelected,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: isCurrent
                ? Colors.blueAccent.withOpacity(0.20)
                : (keyboardSelected
                    ? Colors.white.withOpacity(0.10)
                    : Colors.white.withOpacity(0.03)),
            border: Border.all(
              color: keyboardSelected
                  ? Colors.white70
                  : (isCurrent ? Colors.blueAccent : Colors.transparent),
              width: keyboardSelected ? 1.4 : 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                child: Text(
                  number.toString().padLeft(2, '0'),
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    color: isCurrent ? Colors.blueAccent : Colors.white38,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // 所有频道统一使用程序图标（新版取景框），不再加载各源杂乱的
              // 网络台标（加载失败/比例不一导致列表图标参差不齐）
              Container(
                width: 34,
                height: 34,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: (keyboardSelected || isCurrent)
                        ? Colors.blueAccent
                        : Colors.white24,
                  ),
                ),
                child: Image.asset(
                  'branding/icon_1024.png',
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  channel.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isCurrent ? Colors.blueAccent : Colors.white,
                    fontSize: 13,
                    fontWeight:
                        isCurrent ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
              if (isFavorite)
                const Icon(Icons.favorite, color: Colors.redAccent, size: 15),
            ],
          ),
        ),
      ),
    );
  }
}

/// EPG 节目行：前置日期列 + 时间段 + 标题 + 状态徽标
class _ProgramTile extends StatelessWidget {
  final EpgProgram program;
  final bool keyboardSelected;
  final bool reserved;
  final bool triggered;

  /// 是否可操作（不支持回看的已播节目为 false：置灰、不可点、遥控器跳过）
  final bool enabled;
  final VoidCallback onAction;

  const _ProgramTile({
    super.key,
    required this.program,
    required this.keyboardSelected,
    required this.reserved,
    required this.triggered,
    required this.enabled,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final isNow = program.isNowPlaying;
    final isPast = program.isPast;
    final grey = triggered && isPast;
    // 源不支持回看的已播节目：整行置灰、无交互
    final unsupported = isPast && !triggered && !enabled;
    final dim = grey || unsupported;
    final tappable = !isNow && !grey && !unsupported;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: InkWell(
        onTap: tappable ? onAction : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: unsupported
                ? Colors.white.withOpacity(0.015)
                : isNow
                    ? Colors.redAccent.withOpacity(0.16)
                    : (keyboardSelected
                        ? Colors.white.withOpacity(0.10)
                        : Colors.white.withOpacity(0.03)),
            border: Border.all(
              color: unsupported
                  ? Colors.white10
                  : keyboardSelected
                      ? Colors.white70
                      : (isNow
                          ? Colors.redAccent.withOpacity(0.6)
                          : Colors.transparent),
              width: keyboardSelected && !unsupported ? 1.4 : 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              // 前置日期列
              SizedBox(
                width: 52,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ChannelEpgDrawerState._weekNames[
                          program.startTime.weekday - 1],
                      style: TextStyle(
                        color: isNow
                            ? Colors.redAccent
                            : (dim ? Colors.white24 : Colors.white54),
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      '${program.startTime.month.toString().padLeft(2, '0')}-${program.startTime.day.toString().padLeft(2, '0')}',
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 92,
                child: Text(
                  program.timeRange,
                  style: TextStyle(
                    color: isNow
                        ? Colors.redAccent
                        : (dim ? Colors.white24 : Colors.white60),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  program.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: unsupported
                        ? Colors.white24
                        : grey
                            ? Colors.white30
                            : (isPast ? Colors.white54 : Colors.white),
                    fontSize: 13,
                    fontWeight: isNow ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _buildStatus(unsupported),
            ],
          ),
        ),
      ),
    );
  }

  Widget _badge(String text, Color color, {bool filled = false}) {
    return Container(
      width: 56,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: filled ? color : color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withOpacity(filled ? 1 : 0.6)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: filled ? Colors.white : color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildStatus(bool unsupported) {
    // 优先级：直播 > 未播已预约 > 未播未预约 > 已播且已触发 > 无回看(灰) > 回看
    if (program.isNowPlaying) {
      return _badge('直播', Colors.redAccent, filled: true);
    }
    if (!program.isPast) {
      return reserved
          ? _badge('已预约', Colors.amber)
          : _badge('预约', Colors.white70);
    }
    if (triggered) {
      return _badge('已播放', Colors.white24);
    }
    if (unsupported) {
      return _badge('无回看', Colors.white12);
    }
    return _badge('回看', Colors.blueAccent);
  }
}

class _EmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? sub;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _EmptyHint({
    required this.icon,
    required this.text,
    this.sub,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.white38),
            const SizedBox(height: 12),
            Text(text,
                style: const TextStyle(color: Colors.white60, fontSize: 14)),
            if (sub != null) ...[
              const SizedBox(height: 6),
              Text(sub!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.settings, size: 17),
                label: Text(actionLabel!),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
