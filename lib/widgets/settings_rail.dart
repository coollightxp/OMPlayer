import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/player_settings.dart';
import '../services/player_controller.dart';
import 'scaled_panel.dart';

/// 右侧设置中心：一级 5 行 + 5 个子页
/// 画面比例 / 超时换源 / 分类管理 / 列表管理 / 偏好设置
/// 遥控器：上下选择、右或 OK 进入、左/返回逐级回退
class SettingsRail extends StatefulWidget {
  final bool isOpen;
  final VoidCallback onClose;

  final VoidCallback? onHoverEnter;
  final VoidCallback? onHoverExit;
  final VoidCallback? onHoverMove;

  /// 列表管理：打开节目源 / EPG 源管理窗口（Task 6）
  final VoidCallback? onManagePlaylist;
  final VoidCallback? onManageEpg;

  const SettingsRail({
    super.key,
    required this.isOpen,
    required this.onClose,
    this.onHoverEnter,
    this.onHoverExit,
    this.onHoverMove,
    this.onManagePlaylist,
    this.onManageEpg,
  });

  @override
  State<SettingsRail> createState() => SettingsRailState();
}

class SettingsRailState extends State<SettingsRail> {
  static const double _designWidth = 380;

  static const _rootTitles = [
    ('画面比例', Icons.aspect_ratio),
    ('超时换源', Icons.swap_horiz),
    ('分类管理', Icons.category_outlined),
    ('列表管理', Icons.playlist_play),
    ('偏好设置', Icons.tune),
  ];

  /// null=一级；0..4=子页
  int? _sub;
  int _kbRootIndex = 0;
  int _kbItemIndex = 0;

  final ScrollController _rootScroll = ScrollController();
  final ScrollController _itemScroll = ScrollController();
  final Map<int, GlobalKey> _rootKeys = {};
  final Map<int, GlobalKey> _itemKeys = {};

  @override
  void dispose() {
    _rootScroll.dispose();
    _itemScroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SettingsRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isOpen && widget.isOpen) {
      // 重开回到一级
      _sub = null;
      _kbRootIndex = 0;
      _kbItemIndex = 0;
      _itemKeys.clear();
    }
  }

  /// 遥控器/键盘按键入口（PlayerScreen 统一分发）
  void handleRemoteKey(String action, {required bool isDown}) {
    if (!widget.isOpen || !mounted) return;
    if (action == 'back') {
      if (isDown) _back();
      return;
    }
    if (!isDown) return;
    final c = context.read<PlayerController>();
    final sub = _sub;
    if (sub == null) {
      switch (action) {
        case 'up':
          setState(() =>
              _kbRootIndex = (_kbRootIndex - 1).clamp(0, _rootTitles.length - 1));
          _ensureVisible(_rootScroll, _rootKeys, _kbRootIndex);
          break;
        case 'down':
          setState(() =>
              _kbRootIndex = (_kbRootIndex + 1).clamp(0, _rootTitles.length - 1));
          _ensureVisible(_rootScroll, _rootKeys, _kbRootIndex);
          break;
        case 'right':
        case 'ok':
          setState(() {
            _sub = _kbRootIndex;
            _kbItemIndex = 0;
          });
          break;
      }
      return;
    }

    // ===== 子页 =====
    final entries = _entriesFor(c, sub);
    if (entries.isEmpty) return;
    switch (action) {
      case 'up':
        setState(() =>
            _kbItemIndex = (_kbItemIndex - 1).clamp(0, entries.length - 1));
        _ensureVisible(_itemScroll, _itemKeys, _kbItemIndex, est: 64);
        break;
      case 'down':
        setState(() =>
            _kbItemIndex = (_kbItemIndex + 1).clamp(0, entries.length - 1));
        _ensureVisible(_itemScroll, _itemKeys, _kbItemIndex, est: 64);
        break;
      case 'left':
        setState(() => _sub = null);
        break;
      case 'right':
        break;
      case 'ok':
        final e = entries[_kbItemIndex.clamp(0, entries.length - 1)];
        if (e.enabled) {
          e.onOk?.call();
          // 时钟等走独立通知器的项：onOk 不会触发 Consumer rebuild，
          // 需要手动 setState 重建当前子页让开关图标即时更新
          if (e.refreshAfterOk && mounted) setState(() {});
        }
        break;
    }
  }

  void _back() {
    if (_sub != null) {
      setState(() => _sub = null);
    } else {
      widget.onClose();
    }
  }

  // ================= 子页条目模型 =================

  /// 统一行：toggle=开关行（[toggleValue] 非 null）；radio=单选项；
  /// 其余=动作行。enabled=false 置灰不可操作。
  static const _timeoutSeconds = [5, 10, 15, 20];
  static const _autoHideSeconds = [2, 3, 5, 8, 10];
  static const _uiScaleValues = [1.0, 1.25, 1.5, 2.0, 2.5, 3.0];

  List<_Entry> _entriesFor(PlayerController c, int sub) {
    final s = c.settings;
    final out = <_Entry>[];
    switch (sub) {
      case 0: // 画面比例（6 选 1）
        // 网页频道走 WebView，画面由站点页面自身排版控制，fvp 的
        // 纹理比例变换对其无效：六个选项一律置灰并给出说明
        final ratioEnabled = !c.webPageActive;
        for (final m in AspectRatioMode.values) {
          out.add(_Entry(
            label: m.label,
            radio: true,
            enabled: ratioEnabled,
            selected: s.aspectRatioMode == m,
            onOk: () => c.setAspectRatioMode(m),
          ));
        }
        if (!ratioEnabled) {
          out.add(_Entry(
            label: '网页频道不支持画面比例',
            subtitle: '网页画面由站点页面自身控制，无法在此调整',
            enabled: false,
          ));
        }
        break;
      case 1: // 超时换源
        // 持久化语义（无独立 bool）：sourceTimeoutSeconds == 0 表示关闭；
        // 开启时恢复为 5 秒；等待时间固定 5/10/15/20 秒四档。
        final enabled = s.sourceTimeoutSeconds > 0;
        out.add(_Entry(
          label: '超时自动换源',
          subtitle: '起播超时后自动尝试下一个播放源',
          toggleValue: enabled,
          onOk: () => c.updateSettings(
              s.copyWith(sourceTimeoutSeconds: enabled ? 0 : 5)),
        ));
        for (final sec in _timeoutSeconds) {
          out.add(_Entry(
            label: '$sec 秒',
            radio: true,
            enabled: enabled,
            selected: s.sourceTimeoutSeconds == sec,
            onOk: () =>
                c.updateSettings(s.copyWith(sourceTimeoutSeconds: sec)),
          ));
        }
        break;
      case 2: // 分类管理（真实分类显隐；「我的收藏」虚拟分类不参与）
        for (final cat in c.categories) {
          final hidden = c.isCategoryHidden(cat.id);
          out.add(_Entry(
            label: cat.name,
            subtitle: '${cat.channels.length} 个频道',
            toggleValue: !hidden,
            onOk: () => c.setCategoryHidden(cat.id, !hidden),
          ));
        }
        break;
      case 3: // 列表管理
        out.add(_Entry(
          label: '节目源设置',
          subtitle: 'M3U/TXT 直播播放列表',
          action: true,
          onOk: widget.onManagePlaylist,
        ));
        out.add(_Entry(
          label: 'EPG 源设置',
          subtitle: 'XMLTV 电子节目单',
          action: true,
          onOk: widget.onManageEpg,
        ));
        break;
      case 4: // 偏好设置
        out.add(_Entry(
          label: '开机自启动',
          toggleValue: s.launchAtStartup,
          onOk: () =>
              c.updateSettings(s.copyWith(launchAtStartup: !s.launchAtStartup)),
        ));
        out.add(_Entry(
          label: '窗口置顶',
          toggleValue: s.alwaysOnTop,
          onOk: () =>
              c.updateSettings(s.copyWith(alwaysOnTop: !s.alwaysOnTop)),
        ));
        out.add(_Entry(
          label: '启动即最大化',
          toggleValue: s.startFullscreen,
          onOk: () =>
              c.updateSettings(s.copyWith(startFullscreen: !s.startFullscreen)),
        ));
        out.add(_Entry(
          label: '显示时钟',
          toggleValue: s.showClock,
          onOk: () => c.setShowClock(!s.showClock),
          // 时钟走独立通知器不触发整树重建，强制重建行让开关即时更新
          refreshAfterOk: true,
        ));
        out.add(_Entry(
          label: '投屏接收',
          subtitle: '接收局域网 DLNA 投屏',
          toggleValue: s.dlnaEnabled,
          onOk: () => c.updateSettings(s.copyWith(dlnaEnabled: !s.dlnaEnabled)),
        ));
        out.add(_Entry(
          label: '手机扫码管理',
          subtitle: '开启后可在列表管理中扫码添加源',
          toggleValue: s.remoteAdminEnabled,
          onOk: () => c.updateSettings(
              s.copyWith(remoteAdminEnabled: !s.remoteAdminEnabled)),
        ));
        // 视频画质
        for (final q in VideoQuality.values) {
          out.add(_Entry(
            label: '画质 · ${q.label}',
            radio: true,
            selected: s.preferredQuality == q,
            onOk: () =>
                c.updateSettings(s.copyWith(preferredQuality: q)),
          ));
        }
        out.add(_Entry(
          label: '自动连播',
          subtitle: '当前节目结束后自动播放下一频道',
          toggleValue: s.autoPlayNext,
          onOk: () =>
              c.updateSettings(s.copyWith(autoPlayNext: !s.autoPlayNext)),
        ));
        // 面板自动隐藏：2/3/5/8/10 秒
        for (final sec in _autoHideSeconds) {
          out.add(_Entry(
            label: '面板自动隐藏 · $sec 秒',
            radio: true,
            selected: s.autoHideDelay == sec * 1000,
            onOk: () =>
                c.updateSettings(s.copyWith(autoHideDelay: sec * 1000)),
          ));
        }
        // 界面缩放
        out.add(_Entry(
          label: '界面缩放 · 自动适配',
          toggleValue: s.uiScaleAuto,
          onOk: () =>
              c.updateSettings(s.copyWith(uiScaleAuto: !s.uiScaleAuto)),
        ));
        for (final v in _uiScaleValues) {
          out.add(_Entry(
            label: '界面缩放 · ${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2)}x',
            radio: true,
            enabled: !s.uiScaleAuto,
            selected: !s.uiScaleAuto && s.uiScale == v,
            onOk: () {
              c.updateSettings(s.copyWith(uiScaleAuto: false, uiScale: v));
            },
          ));
        }
        break;
    }
    return out;
  }

  // ================= 滚动 =================

  void _ensureVisible(
      ScrollController sc, Map<int, GlobalKey> keys, int index,
      {double est = 56}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !sc.hasClients) return;
      final ctx = keys[index]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: 0.3);
        return;
      }
      final pos = sc.position;
      final rough =
          (index * est - pos.viewportDimension / 2).clamp(0.0, pos.maxScrollExtent);
      pos.jumpTo(rough);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !sc.hasClients) return;
        final c2 = keys[index]?.currentContext;
        if (c2 != null) {
          Scrollable.ensureVisible(c2,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              alignment: 0.3);
        }
      });
    });
  }

  // ================= 构建 =================

  @override
  Widget build(BuildContext context) {
    final scale = panelScaleOf(context);
    final w = _designWidth * scale;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
      right: widget.isOpen ? 0 : -w,
      top: 0,
      bottom: 0,
      width: w,
      child: MouseRegion(
        onEnter: (_) => widget.onHoverEnter?.call(),
        onExit: (_) => widget.onHoverExit?.call(),
        onHover: (_) => widget.onHoverMove?.call(),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: widget.isOpen ? 1.0 : 0.0,
          child: ScaledPanel(
            designWidth: _designWidth,
            alignment: Alignment.centerRight,
            scale: scale,
            child: Material(
              color: Colors.black87,
              elevation: 16,
              child: SafeArea(
                child: Consumer<PlayerController>(
                  builder: (context, c, _) {
                    final sub = _sub;
                    if (sub == null) return _buildRoot();
                    return _buildSub(c, sub);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(String title, {bool showBack = true}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          if (showBack)
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white70),
              onPressed: () => setState(() => _sub = null),
            )
          else
            const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70),
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _buildRoot() {
    return Column(
      children: [
        _buildHeader('设置', showBack: false),
        Expanded(
          child: ListView.builder(
            controller: _rootScroll,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: _rootTitles.length,
            itemBuilder: (context, index) {
              final (title, icon) = _rootTitles[index];
              final focused = index == _kbRootIndex && _sub == null;
              final key = _rootKeys[index] ??= GlobalKey();
              return Padding(
                key: key,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() {
                    _kbRootIndex = index;
                    _sub = index;
                    _kbItemIndex = 0;
                  }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 15),
                    decoration: BoxDecoration(
                      color: focused
                          ? Colors.white.withOpacity(0.10)
                          : Colors.white.withOpacity(0.03),
                      border: Border.all(
                        color: focused
                            ? Colors.white70
                            : Colors.transparent,
                        width: 1.4,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(icon,
                            color: focused ? Colors.white : Colors.white54,
                            size: 21),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(title,
                              style: TextStyle(
                                color:
                                    focused ? Colors.white : Colors.white70,
                                fontSize: 15,
                                fontWeight: focused
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              )),
                        ),
                        Icon(Icons.chevron_right,
                            color: focused ? Colors.white : Colors.white38),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSub(PlayerController c, int sub) {
    final entries = _entriesFor(c, sub);
    if (_kbItemIndex >= entries.length) {
      _kbItemIndex = entries.isEmpty ? 0 : entries.length - 1;
    }
    return Column(
      children: [
        _buildHeader(_rootTitles[sub].$1),
        Expanded(
          child: entries.isEmpty
              ? const Center(
                  child: Text('暂无内容',
                      style: TextStyle(color: Colors.white54)),
                )
              : ListView.builder(
                  controller: _itemScroll,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final e = entries[index];
                    final key = _itemKeys[index] ??= GlobalKey();
                    return _EntryTile(
                      key: key,
                      entry: e,
                      keyboardSelected: index == _kbItemIndex,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 设置行数据
class _Entry {
  final String label;
  final String? subtitle;

  /// 非 null=开关行
  final bool? toggleValue;

  /// 单选项样式
  final bool radio;

  /// 动作行样式
  final bool action;

  final bool selected;
  final bool enabled;
  final VoidCallback? onOk;

  /// OK 触发 onOk 后额外执行 setState 重建当前子页列表。
  /// 用于 setShowClock 这类走独立通知器、不触发 Consumer rebuild 的项。
  final bool refreshAfterOk;

  const _Entry({
    required this.label,
    this.subtitle,
    this.toggleValue,
    this.radio = false,
    this.action = false,
    this.selected = false,
    this.enabled = true,
    this.onOk,
    this.refreshAfterOk = false,
  });
}

class _EntryTile extends StatelessWidget {
  final _Entry entry;
  final bool keyboardSelected;

  const _EntryTile({
    super.key,
    required this.entry,
    required this.keyboardSelected,
  });

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final baseColor = e.enabled ? Colors.white : Colors.white30;
    // InkWell 包在最外层：点击行内任何位置（含 padding 空白）都触发 onOk，
    // 不会穿透到底层播放区导致误暂停/误切台
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: e.enabled ? e.onOk : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: keyboardSelected
                ? Colors.white.withOpacity(0.10)
                : Colors.white.withOpacity(0.03),
            border: Border.all(
              color:
                  keyboardSelected ? Colors.white70 : Colors.transparent,
              width: 1.4,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              if (e.radio)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Icon(
                    e.selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 20,
                    color: e.enabled
                        ? (e.selected ? Colors.blueAccent : Colors.white38)
                        : Colors.white24,
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: baseColor,
                          fontSize: 14,
                          fontWeight:
                              e.selected ? FontWeight.bold : FontWeight.normal,
                        )),
                    if (e.subtitle != null)
                      Text(e.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11)),
                  ],
                ),
              ),
              if (e.toggleValue != null)
                Switch(
                  value: e.toggleValue!,
                  onChanged:
                      e.enabled ? (_) => e.onOk?.call() : null,
                  activeColor: Colors.blueAccent,
                ),
              if (e.action)
                const Icon(Icons.chevron_right, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}
