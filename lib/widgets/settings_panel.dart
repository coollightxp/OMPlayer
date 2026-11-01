import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '../models/epg_source.dart';
import '../models/player_settings.dart';
import '../models/playlist_source.dart';
import '../services/osd_bus.dart';
import '../services/player_controller.dart';
import '../services/web_diag.dart';
import 'scaled_panel.dart';

/// 选择本地文件。
/// Windows 上主窗口默认置顶（全屏时强制置顶），而 file_picker 的系统
/// 文件对话框（IFileDialog）不会自动成为置顶窗口，会被压在主窗口
/// 后面、任务栏也只闪图标。弹出前临时取消置顶，对话框关闭后恢复。
Future<PlatformFile?> _pickLocalFileWithTopmostFix() async {
  bool wasTopmost = false;
  try {
    wasTopmost = await windowManager.isAlwaysOnTop();
    if (wasTopmost) {
      await windowManager.setAlwaysOnTop(false);
      // 等窗口管理器应用完层级变更，避免对话框仍被盖住
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  } catch (_) {
    wasTopmost = false;
  }
  try {
    return await FilePicker.pickFile(type: FileType.any);
  } finally {
    if (wasTopmost) {
      try {
        await windowManager.setAlwaysOnTop(true);
      } catch (_) {}
    }
  }
}

/// Windows 输入框 IME 保险：在两个输入框之间切换焦点后，Windows 引擎的
/// 输入法（TSF）连接偶发失效——表现为无法键入字符、程序对按键不响应
/// （系统相关，部分系统没有；其他 Flutter 程序同样存在）。
/// 点击时先卸载焦点再延时补挂，强制重建 IME 连接，规避该引擎缺陷。
class _ImeSafeTextField extends StatefulWidget {
  final TextEditingController controller;
  final InputDecoration? decoration;
  final TextStyle? style;

  const _ImeSafeTextField({
    required this.controller,
    this.decoration,
    this.style,
  });

  @override
  State<_ImeSafeTextField> createState() => _ImeSafeTextFieldState();
}

class _ImeSafeTextFieldState extends State<_ImeSafeTextField> {
  late final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      focusNode: _focus,
      style: widget.style,
      decoration: widget.decoration,
      onTap: () {
        _focus.unfocus();
        Future.delayed(const Duration(milliseconds: 30), () {
          if (mounted && !_focus.hasFocus) _focus.requestFocus();
        });
      },
    );
  }
}

/// 设置面板 - 从底部弹出的设置菜单
/// 包含三个标签页：播放列表、EPG、播放器设置
class SettingsPanel extends StatefulWidget {
  final bool isOpen;
  final VoidCallback onClose;

  const SettingsPanel({
    super.key,
    required this.isOpen,
    required this.onClose,
  });

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  /// 顶部页签的焦点节点：上下键可以落到这里，左右键在这里切页签
  final FocusNode _tabFocus = FocusNode(debugLabel: 'settingsTabBar');

  /// 设置内容根节点：判断当前焦点是否已在面板内
  final GlobalKey _panelKey = GlobalKey();

  /// 面板根焦点节点：上下键在这里统一处理。它自己不取焦点、不参与遍历，
  /// 只是包住全部内容，让按键一定能先在面板内处理掉（不依赖
  /// HardwareKeyboard 处理器顺序）
  final FocusNode _panelFocusNode = FocusNode(
    debugLabel: 'settingsPanelRoot',
    skipTraversal: true,
    canRequestFocus: false,
  );

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    // 只构建当前页签内容，切页时需要重建
    _tabController.addListener(_onTabIndexChanged);
    // 上下方向键统一由面板自己接管（见 _onVerticalKey）
    HardwareKeyboard.instance.addHandler(_onVerticalKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onVerticalKey);
    _tabController.removeListener(_onTabIndexChanged);
    _tabFocus.dispose();
    _panelFocusNode.dispose();
    _tabController.dispose();
    super.dispose();
  }

  int _lastTabIndex = 0;

  void _onTabIndexChanged() {
    if (_tabController.index == _lastTabIndex) return;
    _lastTabIndex = _tabController.index;
    if (mounted) setState(() {});
  }

  /// 当前页签内容（只构建选中的那一页，避免隐藏页的控件进入焦点遍历）
  Widget _tabPage(int index) {
    switch (index) {
      case 1:
        return _EpgTab();
      case 2:
        return _PlayerSettingsTab();
      case 3:
        return _SystemSettingsTab();
      case 4:
        return _HelpTab();
      default:
        return _PlaylistTab();
    }
  }

  /// 上下键改为在设置内容里纵向移动焦点。
  ///
  /// 不使用几何方向计算（focusInDirection）也不依赖 WidgetOrder 遍历：
  /// 直接取「面板根节点下所有可聚焦节点」的树顺序（即界面自上而下的顺序），
  /// 上一格/下一格走一步。这样不会隔行跳、也不会穿到播放页其它面板。
  /// 到最上面落到页签栏，页签栏上用左右键切页。
  bool _onVerticalKey(KeyEvent event) {
    if (!widget.isOpen) return false;
    // 设置里弹出对话框（编辑源、二维码等）时放行：焦点属于对话框，
    // 不能把焦点抢回设置面板
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    return _handleVertical(event);
  }

  /// 面板根焦点上的按键：与上面的全局处理器共用同一套逻辑，
  /// 保证焦点在面板内时按键一定先在这里被吃掉
  KeyEventResult _onPanelKeyEvent(FocusNode node, KeyEvent event) =>
      _handleVertical(event)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;

  bool _handleVertical(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final key = event.logicalKey;
    final isUp = key == LogicalKeyboardKey.arrowUp;
    if (!isUp && key != LogicalKeyboardKey.arrowDown) return false;

    // 面板内所有可聚焦节点的树顺序（页签栏在最前，内容自上而下）
    final stops = <FocusNode>[];
    for (final n in _panelFocusNode.traversalDescendants) {
      if (n.attached && n.canRequestFocus && n.context != null) stops.add(n);
    }
    if (stops.isEmpty) return false;

    final focus = FocusManager.instance.primaryFocus;
    final idx = stops.indexWhere((n) => n == focus || n.hasFocus);
    if (idx < 0) {
      // 焦点还停在面板外（刚打开时）：从页签栏进入
      _tabFocus.requestFocus();
      return true;
    }
    final target = idx + (isUp ? -1 : 1);
    if (target < 0 || target >= stops.length) {
      // 已到顶/到底：吞掉按键，停在原处
      return true;
    }
    stops[target].requestFocus();
    _scrollFocusedIntoView();
    return true;
  }

  /// 把当前焦点滚到可视区（设置内容是可滚动的长列表）。
  /// 焦点变更在微任务里生效，下一帧再取 primaryFocus。
  void _scrollFocusedIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = FocusManager.instance.primaryFocus?.context;
      if (target == null || !target.mounted) return;
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 120),
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }


  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
      bottom: widget.isOpen ? 0 : -MediaQuery.of(context).size.height,
      left: 0,
      right: 0,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: widget.isOpen ? 1.0 : 0.0,
        child: ScaledPanel(
          alignment: Alignment.bottomCenter,
          scale: panelScaleOf(context),
          // 限宽居中：设置面板不再通栏铺满，宽屏下保持 760 逻辑像素以内
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Material(
            color: Colors.black87,
            elevation: 24,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(16)),
            child: SafeArea(
              top: false,
              child: Builder(builder: (context) {
                // 横屏手机等矮屏（高度<500）时面板几乎占满全高，避免太短无法操作
                final screenH = MediaQuery.of(context).size.height;
                return SizedBox(
                  key: _panelKey,
                  height: screenH * (screenH < 500 ? 0.95 : 0.7),
                  // 焦点遍历圈定在设置面板内（按控件树顺序上下走）：
                  // 否则方向键会穿到播放页底部面板的按钮上
                  child: FocusTraversalGroup(
                    policy: WidgetOrderTraversalPolicy(),
                    child: Focus(
                      focusNode: _panelFocusNode,
                      onKeyEvent: _onPanelKeyEvent,
                      child: Column(
                    children: [
                    // 顶部拖拽条 + 标题
                    Container(
                      padding:
                          const EdgeInsets.only(top: 10, bottom: 8),
                      child: Column(
                        children: [
                          Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white30,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              const SizedBox(width: 16),
                              const Text(
                                '设置',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Spacer(),
                              // 关闭按钮只给鼠标用（遥控器用 Esc 关闭），
                              // 不参与焦点遍历，保证内容区往上走落到页签栏
                              ExcludeFocus(
                                child: IconButton(
                                  icon: const Icon(Icons.close,
                                      color: Colors.white70),
                                  onPressed: widget.onClose,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // Tab 栏：单独可获得焦点（上下键能落到这里），
                    // 移到这里后左右键切页签
                    Focus(
                      focusNode: _tabFocus,
                      onKeyEvent: (node, event) {
                        if (event is! KeyDownEvent &&
                            event is! KeyRepeatEvent) {
                          return KeyEventResult.ignored;
                        }
                        final k = event.logicalKey;
                        if (k != LogicalKeyboardKey.arrowLeft &&
                            k != LogicalKeyboardKey.arrowRight) {
                          return KeyEventResult.ignored;
                        }
                        final next = _tabController.index +
                            (k == LogicalKeyboardKey.arrowLeft ? -1 : 1);
                        if (next >= 0 && next < _tabController.length) {
                          _tabController.animateTo(next);
                        }
                        // 焦点留在页签栏上，连续左右按不用重新找焦点
                        _tabFocus.requestFocus();
                        return KeyEventResult.handled;
                      },
                      child: ListenableBuilder(
                        listenable: _tabFocus,
                        builder: (context, child) {
                          // 焦点在页签栏时给一圈描边，遥控器用户能看清
                          // 焦点已经上来了，此时左右键切页
                          return Container(
                            decoration: _tabFocus.hasFocus
                                ? BoxDecoration(
                                    border: Border.all(
                                        color: Colors.white70, width: 1),
                                    borderRadius: BorderRadius.circular(8),
                                  )
                                : null,
                            child: child,
                          );
                        },
                        // 页签自身不取焦点：焦点由上面的 Focus 节点持有，
                        // 左右键才能稳定切页
                        child: ExcludeFocus(
                          child: TabBar(
                            controller: _tabController,
                            indicatorColor: Colors.blueAccent,
                            labelColor: Colors.blueAccent,
                            unselectedLabelColor: Colors.white54,
                            tabs: const [
                              Tab(text: '播放列表'),
                              Tab(text: 'EPG'),
                              Tab(text: '播放器'),
                              Tab(text: '系统'),
                              Tab(text: '说明'),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const Divider(color: Colors.white12, height: 1),
                    // Tab 内容：只构建当前页（TabBarView 会把另外 4 页也留在
                    // 焦点树里，方向键会跑到看不见的控件上）
                    Expanded(child: _tabPage(_tabController.index)),
                  ],
                      ),
                    ),
                  ),
                );
              }),
            ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== 播放列表管理标签页 ====================

class _PlaylistTab extends StatefulWidget {
  @override
  State<_PlaylistTab> createState() => _PlaylistTabState();
}

class _PlaylistTabState extends State<_PlaylistTab> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  PlaylistSourceType _type = PlaylistSourceType.url;
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _pickLocalFile() async {
    // file_picker 12+ 新 API：FilePicker.pickFile 直接返回 PlatformFile?
    // 放开所有文件类型：直播源后缀五花八门（.m3u/.m3u8/.txt/.nzk/
    // .conf/.list/.php 甚至无后缀），加载时按内容自动识别格式
    final file = await _pickLocalFileWithTopmostFix();
    if (file?.path != null) {
      setState(() {
        _urlController.text = file!.path!;
        _type = PlaylistSourceType.local;
      });
    }
  }

  Future<void> _addPlaylist() async {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (name.isEmpty || url.isEmpty) {
      OsdBus.show('请填写名称和地址', icon: Icons.warning_amber_rounded);
      return;
    }
    setState(() => _isLoading = true);
    // 格式存 unknown：加载时按文件/响应【内容】嗅探，后缀不可靠
    // （.php 可能是 M3U 也可能是 TVBox TXT，.nzk 实际是 TXT）
    const format = PlaylistFormat.unknown;
    final source = PlaylistSource(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      url: url,
      type: _type,
      format: format,
      addedAt: DateTime.now(),
    );
    await context.read<PlayerController>().addPlaylist(source);
    _nameController.clear();
    _urlController.clear();
    setState(() => _isLoading = false);
  }

  /// 编辑已有播放列表（名称/地址/类型）
  Future<void> _editPlaylist(PlaylistSource source) async {
    final nameCtl = TextEditingController(text: source.name);
    final urlCtl = TextEditingController(text: source.url);
    var type = source.type;
    if (!mounted) return;
    final result = await showDialog<PlaylistSource>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('编辑播放列表'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<PlaylistSourceType>(
                  segments: const [
                    ButtonSegment(
                        value: PlaylistSourceType.url, label: Text('网络地址')),
                    ButtonSegment(
                        value: PlaylistSourceType.local, label: Text('本地文件')),
                  ],
                  selected: {type},
                  onSelectionChanged: (s) => setDialog(() => type = s.first),
                ),
                const SizedBox(height: 10),
                _ImeSafeTextField(
                  controller: nameCtl,
                  style: const TextStyle(color: Colors.white),
                  decoration: _inputDecoration('列表名称'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _ImeSafeTextField(
                        controller: urlCtl,
                        style: const TextStyle(color: Colors.white),
                        decoration: _inputDecoration(
                            type == PlaylistSourceType.url ? '直播源地址' : '本地文件路径'),
                      ),
                    ),
                    if (type == PlaylistSourceType.local)
                      IconButton(
                        icon: const Icon(Icons.folder_open,
                            color: Colors.blueAccent),
                        onPressed: () async {
                          final f =
                              await _pickLocalFileWithTopmostFix();
                          if (f?.path != null) urlCtl.text = f!.path!;
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                final name = nameCtl.text.trim();
                final url = urlCtl.text.trim();
                if (name.isEmpty || url.isEmpty) return;
                Navigator.pop(
                  ctx,
                  source.copyWith(name: name, url: url, type: type),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      await context.read<PlayerController>().editPlaylist(result);
    }
  }

  /// 复制播放列表地址到剪贴板
  Future<void> _copyPlaylist(PlaylistSource p) async {
    await Clipboard.setData(ClipboardData(text: p.url));
    if (!mounted) return;
    OsdBus.show('地址已复制', icon: Icons.copy);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final playlists = controller.sourceManager.playlists;
        // 整页 ListView：表单+列表一起滚动，横屏矮屏也不会溢出
        return ListView(
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            // 添加表单
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: SegmentedButton<PlaylistSourceType>(
                          segments: const [
                            ButtonSegment(
                                value: PlaylistSourceType.url,
                                label: Text('网络地址')),
                            ButtonSegment(
                                value: PlaylistSourceType.local,
                                label: Text('本地文件')),
                          ],
                          selected: {_type},
                          onSelectionChanged: (s) =>
                              setState(() => _type = s.first),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _ImeSafeTextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('列表名称（如：我的电视）'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _ImeSafeTextField(
                          controller: _urlController,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration(
                              _type == PlaylistSourceType.url
                                  ? '直播源地址（M3U / TVBox TXT / PHP 等，自动识别）'
                                  : '本地文件路径（任意类型，自动识别）'),
                        ),
                      ),
                      if (_type == PlaylistSourceType.local)
                        IconButton(
                          icon: const Icon(Icons.folder_open,
                              color: Colors.blueAccent),
                          onPressed: _pickLocalFile,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isLoading ? null : _addPlaylist,
                      icon: const Icon(Icons.add),
                      label: Text(_isLoading ? '添加中...' : '添加播放列表'),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12),
            // 播放列表
            if (playlists.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text('暂无播放列表，请添加',
                      style: TextStyle(color: Colors.white54)),
                ),
              )
            else
              ...List.generate(playlists.length, (index) {
                final p = playlists[index];
                final isCurrent =
                    controller.sourceManager.currentPlaylistId == p.id;
                return _SourceRow(
                  title: p.name,
                  subtitle: p.url,
                  icon: p.type == PlaylistSourceType.url
                      ? Icons.cloud
                      : Icons.folder,
                  isCurrent: isCurrent,
                  // 行上按 OK = 选定该播放列表；左右键进入行尾按钮
                  onSelect: isCurrent
                      ? null
                      : () => controller.selectPlaylist(p.id),
                  actions: [
                    _RowAction(Icons.edit, Colors.lightBlueAccent, '编辑',
                        () => _editPlaylist(p)),
                    _RowAction(Icons.copy, Colors.white60, '复制名称和地址',
                        () => _copyPlaylist(p)),
                    _RowAction(Icons.refresh, Colors.amber, '刷新',
                        () => controller.refreshChannels()),
                    _RowAction(Icons.delete, Colors.redAccent, '删除',
                        () => controller.removePlaylist(p.id)),
                  ],
                );
              }),
          ],
        );
      },
    );
  }
}

// ==================== EPG 管理标签页 ====================

class _EpgTab extends StatefulWidget {
  @override
  State<_EpgTab> createState() => _EpgTabState();
}

class _EpgTabState extends State<_EpgTab> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _addEpg() async {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (name.isEmpty || url.isEmpty) {
      OsdBus.show('请填写名称和地址', icon: Icons.warning_amber_rounded);
      return;
    }
    setState(() => _isLoading = true);
    final source = EpgSource(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      url: url,
      addedAt: DateTime.now(),
    );
    await context.read<PlayerController>().addEpg(source);
    _nameController.clear();
    _urlController.clear();
    setState(() => _isLoading = false);
  }

  /// 编辑已有 EPG 源（名称/地址）
  Future<void> _editEpg(EpgSource source) async {
    final nameCtl = TextEditingController(text: source.name);
    final urlCtl = TextEditingController(text: source.url);
    if (!mounted) return;
    final result = await showDialog<EpgSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑 EPG'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ImeSafeTextField(
              controller: nameCtl,
              style: const TextStyle(color: Colors.white),
              decoration: _inputDecoration('EPG 名称'),
            ),
            const SizedBox(height: 8),
            _ImeSafeTextField(
              controller: urlCtl,
              style: const TextStyle(color: Colors.white),
              decoration: _inputDecoration('XMLTV EPG 地址 URL'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              final name = nameCtl.text.trim();
              final url = urlCtl.text.trim();
              if (name.isEmpty || url.isEmpty) return;
              Navigator.pop(ctx, source.copyWith(name: name, url: url));
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null && mounted) {
      await context.read<PlayerController>().editEpg(result);
    }
  }

  /// 复制 EPG 地址到剪贴板
  Future<void> _copyEpg(EpgSource e) async {
    await Clipboard.setData(ClipboardData(text: e.url));
    if (!mounted) return;
    OsdBus.show('地址已复制', icon: Icons.copy);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final epgs = controller.sourceManager.epgs;
        // 整页 ListView：表单+列表一起滚动，横屏矮屏也不会溢出
        return ListView(
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  _ImeSafeTextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('EPG 名称（如：央视节目单）'),
                  ),
                  const SizedBox(height: 8),
                  _ImeSafeTextField(
                    controller: _urlController,
                    style: const TextStyle(color: Colors.white),
                    decoration:
                        _inputDecoration('XMLTV EPG 地址 URL'),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isLoading ? null : _addEpg,
                      icon: const Icon(Icons.add),
                      label: Text(_isLoading ? '添加中...' : '添加 EPG'),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12),
            if (epgs.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text('暂无 EPG 源，请添加',
                      style: TextStyle(color: Colors.white54)),
                ),
              )
            else
              ...List.generate(epgs.length, (index) {
                final e = epgs[index];
                final isCurrent =
                    controller.sourceManager.currentEpgId == e.id;
                return _SourceRow(
                  title: e.name,
                  subtitle: e.url,
                  icon: Icons.menu_book,
                  isCurrent: isCurrent,
                  onSelect:
                      isCurrent ? null : () => controller.selectEpg(e.id),
                  actions: [
                    _RowAction(Icons.edit, Colors.lightBlueAccent, '编辑',
                        () => _editEpg(e)),
                    _RowAction(Icons.copy, Colors.white60, '复制名称和地址',
                        () => _copyEpg(e)),
                    _RowAction(Icons.refresh, Colors.amber, '刷新',
                        () => controller.refreshEpg()),
                    _RowAction(Icons.delete, Colors.redAccent, '删除',
                        () => controller.removeEpg(e.id)),
                  ],
                );
              }),
          ],
        );
      },
    );
  }
}

// ==================== 播放器设置标签页 ====================

class _PlayerSettingsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final s = controller.settings;
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _buildQualitySelector(controller),
            SwitchListTile(
              secondary: const Icon(Icons.skip_next, color: Colors.white70),
              title: const Text('自动播放下一频道',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: const Text('当前节目结束后自动切换',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              value: s.autoPlayNext,
              onChanged: (v) => controller
                  .updateSettings(s.copyWith(autoPlayNext: v)),
              activeColor: Colors.blueAccent,
            ),
            _buildSlider(
              icon: Icons.touch_app,
              title: '手势灵敏度',
              value: s.gestureSensitivity,
              min: 0.5,
              max: 2.0,
              divisions: 15,
              label: '${s.gestureSensitivity.toStringAsFixed(1)}x',
              onChanged: (v) => controller
                  .updateSettings(s.copyWith(gestureSensitivity: v)),
            ),
            _buildSlider(
              icon: Icons.timer,
              title: '面板自动隐藏',
              value: s.autoHideDelay / 1000,
              min: 1.0,
              max: 10.0,
              divisions: 9,
              label: '${(s.autoHideDelay / 1000).toStringAsFixed(1)} 秒',
              onChanged: (v) => controller.updateSettings(
                  s.copyWith(autoHideDelay: (v * 1000).round())),
            ),
            _buildSlider(
              icon: Icons.swap_horiz,
              title: '切源等待时间',
              value: s.sourceTimeoutSeconds.toDouble(),
              min: 5,
              max: 30,
              divisions: 5,
              label: '${s.sourceTimeoutSeconds} 秒',
              onChanged: (v) => controller.updateSettings(
                  s.copyWith(sourceTimeoutSeconds: v.round())),
              subtitleText: '起播超过该时间未成功，自动尝试下一个源',
            ),
            // 播放缓冲：分段选择 5/10/20/30 秒（换台时由 MDK 后端应用）
            ListTile(
              leading: const Icon(Icons.slow_motion_video,
                  color: Colors.white70),
              title: const Text('播放缓冲'),
              subtitle: const Text('弱网或直播卡顿可调大，换台后生效'),
              trailing: SegmentedButton<int>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
                segments: const [5, 10, 20, 30]
                    .map((v) =>
                        ButtonSegment(value: v, label: Text('$v 秒')))
                    .toList(),
                selected: {s.bufferSeconds},
                onSelectionChanged: (sel) => controller.updateSettings(
                    s.copyWith(bufferSeconds: sel.first)),
              ),
            ),
            _buildUiScaleTile(context, controller, s),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }

  /// 字体缩放：自动按分辨率适配 + 手动滑块
  Widget _buildUiScaleTile(
      BuildContext context, PlayerController controller, PlayerSettings s) {
    final mq = MediaQuery.of(context);
    final physicalW = mq.size.width * mq.devicePixelRatio;
    final autoScale = (physicalW / 1920.0).clamp(1.0, 3.0);
    final scale = s.uiScaleAuto ? autoScale : s.uiScale;
    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.screen_rotation,
              color: Colors.white70),
          title: const Text('字体大小自动适配',
              style: TextStyle(color: Colors.white, fontSize: 15)),
          subtitle: Text(
            '按屏幕分辨率自动缩放（当前屏幕：${physicalW.round()} 像素，自动 ${autoScale.toStringAsFixed(2)}x）',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          value: s.uiScaleAuto,
          onChanged: (v) =>
              controller.updateSettings(s.copyWith(uiScaleAuto: v)),
          activeColor: Colors.blueAccent,
        ),
        ListTile(
          leading: Icon(Icons.format_size,
              color: s.uiScaleAuto ? Colors.white24 : Colors.white70),
          title: Text('手动字体缩放',
              style: TextStyle(
                  color: s.uiScaleAuto ? Colors.white38 : Colors.white,
                  fontSize: 15)),
          enabled: !s.uiScaleAuto,
          subtitle: _NavSlider(
            // 自动模式下展示当前生效值但禁止拖动
            value: scale.clamp(0.8, 3.0).toDouble(),
            min: 0.8,
            max: 3.0,
            divisions: 22,
            label: '${scale.toStringAsFixed(1)}x',
            onChanged: s.uiScaleAuto
                ? null
                : (v) => controller.updateSettings(s.copyWith(uiScale: v)),
          ),
        ),
      ],
    );
  }

  Widget _buildQualitySelector(PlayerController controller) {
    return ExpansionTile(
      leading: const Icon(Icons.hd, color: Colors.white70),
      title: const Text('视频画质',
          style: TextStyle(color: Colors.white, fontSize: 15)),
      subtitle: Text(controller.settings.preferredQuality.label,
          style: const TextStyle(color: Colors.white54, fontSize: 12)),
      iconColor: Colors.white70,
      collapsedIconColor: Colors.white70,
      children: VideoQuality.values.map((q) {
        return RadioListTile<VideoQuality>(
          value: q,
          groupValue: controller.settings.preferredQuality,
          onChanged: (v) {
            if (v != null) {
              controller.updateSettings(
                  controller.settings.copyWith(preferredQuality: v));
            }
          },
          title: Text(q.label,
              style:
                  const TextStyle(color: Colors.white70, fontSize: 14)),
          activeColor: Colors.blueAccent,
        );
      }).toList(),
    );
  }

  Widget _buildSlider({
    required IconData icon,
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required ValueChanged<double> onChanged,
    String? subtitleText,
  }) {
    final clamped = value.clamp(min, max);
    return ListTile(
      leading: Icon(icon, color: Colors.white70),
      title: Text(title,
          style: const TextStyle(color: Colors.white, fontSize: 15)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitleText != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(subtitleText,
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 12)),
            ),
          _NavSlider(
            value: clamped.toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            label: label,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

// ==================== 遥控器可用的滑块 ====================

/// 键盘/遥控器友好的滑块。
/// Flutter 自带的 Slider 会把上下方向键当成数值增减（并且它自己持有焦点，
/// 比外层更靠近焦点树），结果焦点落在滑块上就跳不出来、按上下还会改值。
/// 这里给滑块套一个自建焦点节点：内层 Slider 用 ExcludeFocus 排除出焦点树，
/// 左右键由外层自己调节数值，上下键回到外层（由设置面板统一做焦点移动）。
class _NavSlider extends StatefulWidget {
  const _NavSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final ValueChanged<double>? onChanged;

  @override
  State<_NavSlider> createState() => _NavSliderState();
}

class _NavSliderState extends State<_NavSlider> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'settingsSlider');

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  /// 一格（divisions 均分）的步长
  double get _step => widget.divisions > 0
      ? (widget.max - widget.min) / widget.divisions
      : 0.01;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (widget.onChanged == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    final next = (widget.value +
            (key == LogicalKeyboardKey.arrowRight ? _step : -_step))
        .clamp(widget.min, widget.max)
        .toDouble();
    widget.onChanged!(next);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    final focused = _focusNode.hasFocus;
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: focused
            ? BoxDecoration(
                border: Border.all(
                    color: enabled ? Colors.blueAccent : Colors.white38),
                borderRadius: BorderRadius.circular(8),
              )
            : null,
        child: ExcludeFocus(
          child: SliderTheme(
            data: SliderThemeData(
              activeTrackColor: Colors.blueAccent,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.blueAccent,
              overlayColor: Colors.blueAccent.withOpacity(0.2),
              disabledActiveTrackColor: Colors.white24,
              disabledThumbColor: Colors.white38,
            ),
            child: Slider(
              value: widget.value,
              min: widget.min,
              max: widget.max,
              divisions: widget.divisions,
              label: widget.label,
              onChanged: widget.onChanged,
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== 系统设置标签页 ====================

class _SystemSettingsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final s = controller.settings;
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            if (controller.isDesktop) ...[
              SwitchListTile(
                secondary: const Icon(Icons.push_pin,
                    color: Colors.white70),
                title: const Text('窗口置顶',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
                subtitle: const Text('窗口始终保持在最前，确保快捷键响应',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                value: s.alwaysOnTop,
                onChanged: (v) => controller
                    .updateSettings(s.copyWith(alwaysOnTop: v)),
                activeColor: Colors.blueAccent,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.power_settings_new,
                    color: Colors.white70),
                title: const Text('开机启动',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
                subtitle: const Text('开机后自动启动 OMPlayer',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                value: s.launchAtStartup,
                onChanged: (v) => controller
                    .updateSettings(s.copyWith(launchAtStartup: v)),
                activeColor: Colors.blueAccent,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.fullscreen, color: Colors.white70),
                title: const Text('启动全屏',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
                subtitle: const Text('仅在程序启动时生效一次；启动后双击全屏/还原不受影响',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                value: s.startFullscreen,
                onChanged: (v) => controller
                    .updateSettings(s.copyWith(startFullscreen: v)),
                activeColor: Colors.blueAccent,
              ),
            ],
            // 开关状态由独立 clockVisible 驱动：切换只重建时钟，不触发
            // 整棵播放 Stack 重建（旧做法反复切换会灰屏）
            ValueListenableBuilder<bool>(
              valueListenable: controller.clockVisible,
              builder: (context, showClock, _) => SwitchListTile(
                secondary:
                    const Icon(Icons.access_time, color: Colors.white70),
                title: const Text('显示时间',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
                subtitle: const Text('右上角一直显示实时系统时间',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                value: showClock,
                onChanged: controller.setShowClock,
                activeColor: Colors.blueAccent,
              ),
            ),
            // 网页直播支持：关闭后启动不加载 WebView2 运行时环境，
            // 网页频道（webview:// 源）不可用
            ListTile(
              leading: Icon(Icons.language,
                  color: s.webEnabled
                      ? Colors.greenAccent
                      : Colors.white54),
              title: const Text('网页直播支持',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: Text(
                s.webEnabled
                    ? '已开启：支持 webview:// 网页直播源\n关闭后重启不再加载 WebView2（不支持的系统可避免出错）'
                    : '已关闭：启动不加载 WebView2 运行时，网页直播源不可用；重新开启后恢复',
                style: const TextStyle(
                    color: Colors.white54, fontSize: 12),
              ),
              trailing: Switch(
                value: s.webEnabled,
                onChanged: (v) => controller
                    .updateSettings(s.copyWith(webEnabled: v)),
                activeColor: Colors.blueAccent,
              ),
            ),
            // 网页频道卡死自动重载：位置 24 秒不推进即重载（每频道最多 3 次）
            ListTile(
              leading: Icon(Icons.refresh,
                  color: s.autoReloadStall
                      ? Colors.greenAccent
                      : Colors.white54),
              title: const Text('网页卡死自动重载',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: const Text(
                '已开启：网页频道播放位置连续 24 秒不推进时自动重载（每频道最多 3 次）\n'
                '内置播放器的直播流有自己的卡顿自愈，不受此开关影响',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              trailing: Switch(
                value: s.autoReloadStall,
                onChanged: (v) => controller
                    .updateSettings(s.copyWith(autoReloadStall: v)),
                activeColor: Colors.blueAccent,
              ),
            ),
            // DLNA 投屏接收状态 + 开关
            ListTile(
              leading: Icon(Icons.cast,
                  color: controller.dlnaRunning
                      ? Colors.greenAccent
                      : Colors.redAccent),
              title: const Text('DLNA 投屏接收',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: Text(
                controller.dlnaRunning
                    ? '已开启：${controller.dlnaName}\n${controller.dlnaEndpoint}\n手机需与本机同一局域网，防火墙需放行本程序'
                    : '未开启：服务已停止或端口被占用',
                style: const TextStyle(
                    color: Colors.white54, fontSize: 12),
              ),
              trailing: Switch(
                value: s.dlnaEnabled,
                onChanged: (v) => controller
                    .updateSettings(s.copyWith(dlnaEnabled: v)),
                activeColor: Colors.blueAccent,
              ),
            ),
            // 局域网 Web 管理：手机扫码增删改直播源/EPG
            ListTile(
              leading: Icon(Icons.qr_code_2,
                  color: s.remoteAdminEnabled &&
                          controller.remoteAdminUrl.isNotEmpty
                      ? Colors.greenAccent
                      : Colors.white54),
              title: const Text('手机扫码管理',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: Text(
                s.remoteAdminEnabled && controller.remoteAdminUrl.isNotEmpty
                    ? '已开启：手机连同一 Wi‑Fi，扫码即可编辑直播源和 EPG\n${controller.remoteAdminUrl}\n'
                        '手机打不开时，请在电脑防火墙提示中允许本程序联网'
                    : (s.remoteAdminEnabled
                        ? '服务启动中或当前平台不支持（端口 8963 起）'
                        : '关闭后局域网内无法通过手机管理'),
                style: const TextStyle(
                    color: Colors.white54, fontSize: 12),
              ),
              trailing: Switch(
                value: s.remoteAdminEnabled,
                onChanged: (v) => controller
                    .updateSettings(s.copyWith(remoteAdminEnabled: v)),
                activeColor: Colors.blueAccent,
              ),
              onTap: controller.remoteAdminUrl.isEmpty
                  ? null
                  : () => showRemoteAdminQrDialog(
                      context, controller.remoteAdminUrl),
            ),
            // 网页频道诊断：复现「打不开/黑屏/串台」后导出日志发给开发者
            ListTile(
              leading: const Icon(Icons.bug_report_outlined,
                  color: Colors.white70),
              title: const Text('导出网页诊断日志',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: const Text(
                  '网页频道故障时使用：先打开故障频道复现一遍，再点这里导出',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              onTap: () async {
                final p = await WebDiag.flush();
                OsdBus.show(
                  p.isEmpty
                      ? '暂无诊断日志：请先打开一次网页频道复现故障'
                      : '诊断日志已导出：$p',
                  icon: Icons.bug_report_outlined,
                );
              },
            ),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }
}

// ==================== 说明标签页 ====================

/// 说明（参考 OMTV）：键盘/鼠标快捷键、遥控器操作、注意事项
class _HelpTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final desktop = controller.isDesktop;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _helpSection('键盘快捷键'),
            _helpInfoCard([
              _helpRow('空格', '播放 / 暂停'),
              _helpRow('F / F11', '全屏切换'),
              _helpRow('M', '静音 / 恢复'),
              _helpRow('L', '解锁（锁定后也可点顶部标题栏的锁按钮解锁）'),
              _helpRow('C', '频道列表'),
              _helpRow('E', '节目单'),
              _helpRow('S', '设置'),
              _helpRow('R', '录制（仅桌面端）'),
              _helpRow('↑ / ↓', '切换频道'),
              _helpRow('← / →', '切换播放源（点播时 ±60 秒快进/快退）'),
              _helpRow('数字键', '直接输入频道号'),
              _helpRow('⏯ / ⏮ / ⏭', '播放暂停 / 上一台 / 下一台'),
              _helpRow('返回 / Esc', '逐层关闭面板，最后弹出退出卡片'),
            ]),
            if (desktop) ...[
              _helpSection('鼠标操作'),
              _helpInfoCard([
                _helpRow('双击画面', '全屏 / 还原（小窗模式下为恢复窗口）'),
                _helpRow('鼠标移到屏幕左边缘', '打开频道列表'),
                _helpRow('鼠标移到屏幕右边缘', '打开节目单'),
                _helpRow('鼠标移到屏幕底部', '显示控制面板'),
                _helpRow('鼠标移到屏幕顶部', '呼出标题栏：置顶 / 锁定 / 最小化 / 最大化 / 关闭'),
                _helpRow('底部面板按钮', '静音、全屏、旋转、小窗、重载等可直接点'),
                _helpRow('右键', '相当于返回键，弹出退出卡片'),
                _helpRow('网页频道前台时', '右键被网页接管，可移到底部呼出控制面板后右键，或按 S 键'),
                _helpRow('退出卡片', '返回 / 锁定 / 设置 / 退出 / 关机'),
              ]),
            ],
            _helpSection('遥控器'),
            _helpInfoCard([
              _helpRow('方向键 ↑ / ↓', '面板未开时切换频道；面板打开时在面板内移动'),
              _helpRow('方向键 ← / →', '面板未开时切换播放源；面板打开时移动高亮'),
              _helpRow('OK', '短按打开频道列表 / 长按呼出控制面板（面板打开时为确认）'),
              _helpRow('返回', '逐层关闭面板；锁定时解锁'),
              _helpRow('菜单键', '短按节目单 / 长按设置'),
              _helpRow('数字键', '直接输入频道号跳转'),
            ]),
            _helpSection('注意事项'),
            _helpNotesCard([
              '直播源和 EPG 都在本设置里自行添加：可在「播放列表」添加多个 m3u / tvbox / 本地源，'
                  '在「EPG」添加多个 XMLTV 源，随时切换，不是固定源。',
              '网页频道（webview:// 源）依赖 WebView2 运行时。系统不支持时，'
                  '可在「系统」关闭「网页直播支持」，程序启动就不会加载 WebView2；'
                  '即使忘记关闭，检测不到运行时也只会提示不可用，不会崩溃或影响退出。',
              '网页频道首次加载较慢属正常；播放位置连续 24 秒不推进会尝试自动重载'
                  '（每频道最多 3 次），也可在底部面板点「重载频道」。',
              '锁定后除返回键、菜单键、L 键外，所有遥控器与键盘操作都会被屏蔽。',
              '手机扫码管理需要手机与电脑连接同一 Wi-Fi，并在防火墙中允许本程序。',
              '台标优先使用源内 tvg-logo，没有则按台名匹配内置台标，仍没有时留空。',
            ]),
          ],
        );
      },
    );
  }
}

Widget _helpSection(String title) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
    child: Text(
      title,
      style: const TextStyle(
        color: Colors.blueAccent,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 1,
      ),
    ),
  );
}

Widget _helpInfoCard(List<Widget> children) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.04),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.white12),
    ),
    child: Column(children: children),
  );
}

Widget _helpRow(String key, String desc) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(
            key,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Text(desc,
              style: const TextStyle(color: Colors.white60, fontSize: 13)),
        ),
      ],
    ),
  );
}

/// 注意事项：逐条小圆点列表
Widget _helpNotesCard(List<String> notes) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.04),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.white12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < notes.length; i++)
          Padding(
            padding:
                EdgeInsets.only(bottom: i == notes.length - 1 ? 0 : 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 5, right: 8),
                  child: Icon(Icons.circle,
                      size: 5, color: Colors.blueAccent),
                ),
                Expanded(
                  child: Text(notes[i],
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          height: 1.45)),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

// ==================== 源条目行（播放列表 / EPG 共用） ====================

/// 行尾操作按钮
class _RowAction {
  const _RowAction(this.icon, this.color, this.tooltip, this.onPressed);

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;
}

/// 源条目行。遥控器交互：
/// - 上下键：设置面板统一做行间移动（本行只占一个焦点节点，
///   行尾按钮不参与焦点遍历，所以不会停在按钮上出不来）
/// - 左右键：在「整行（选定）」与行尾各按钮之间切换
/// - OK：整行＝选定该源；按钮上＝执行该按钮
class _SourceRow extends StatefulWidget {
  const _SourceRow({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.isCurrent,
    required this.onSelect,
    required this.actions,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool isCurrent;

  /// null＝已是当前源，选定无效果
  final VoidCallback? onSelect;
  final List<_RowAction> actions;

  @override
  State<_SourceRow> createState() => _SourceRowState();
}

class _SourceRowState extends State<_SourceRow> {
  final FocusNode _rowNode = FocusNode(debugLabel: 'settingsSourceRow');
  late final List<FocusNode> _actionNodes = List<FocusNode>.generate(
    widget.actions.length,
    (i) => FocusNode(debugLabel: 'settingsSourceRowAction$i'),
  );

  /// 0＝整行（选定），1..n＝第 n 个行尾按钮
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _rowNode.addListener(_onFocusChanged);
    for (final n in _actionNodes) {
      n.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    _rowNode.removeListener(_onFocusChanged);
    for (final n in _actionNodes) {
      n.removeListener(_onFocusChanged);
      n.dispose();
    }
    _rowNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    final i = _actionNodes.indexWhere((n) => n.hasFocus);
    setState(() => _index = i < 0 ? 0 : i + 1);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight) {
      final target = (k == LogicalKeyboardKey.arrowLeft ? _index - 1 : _index + 1)
          .clamp(0, widget.actions.length)
          .toInt();
      setState(() => _index = target);
      if (target == 0) {
        _rowNode.requestFocus();
      } else {
        _actionNodes[target - 1].requestFocus();
      }
      return KeyEventResult.handled;
    }
    // 整行上按 OK/回车 = 选定该源（按钮上的 OK 由按钮自身处理）
    if (_index == 0 &&
        (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.numpadEnter ||
            k == LogicalKeyboardKey.gameButtonA)) {
      widget.onSelect?.call();
      return KeyEventResult.handled;
    }
    // 上下键交给设置面板统一处理
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final focused = _rowNode.hasFocus || _index > 0;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
      decoration: BoxDecoration(
        color: _rowNode.hasFocus ? Colors.white.withOpacity(0.04) : null,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: focused ? Colors.blueAccent : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Focus(
        focusNode: _rowNode,
        onKeyEvent: _onKey,
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onSelect,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        widget.icon,
                        size: 22,
                        color: widget.isCurrent
                            ? Colors.blueAccent
                            : Colors.white54,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: widget.isCurrent
                                    ? Colors.blueAccent
                                    : Colors.white,
                                fontWeight: widget.isCurrent
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            Text(
                              widget.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // 当前正在使用：蓝色对号（仅状态标识）
            if (widget.isCurrent)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.check_circle,
                    color: Colors.blueAccent, size: 20),
              ),
            // 行尾按钮：不参与上下遍历，只能用左右键在行内进入
            Focus(
              skipTraversal: true,
              descendantsAreTraversable: false,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < widget.actions.length; i++)
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _actionNodes[i].hasFocus
                              ? Colors.white70
                              : Colors.transparent,
                        ),
                      ),
                      child: IconButton(
                        focusNode: _actionNodes[i],
                        visualDensity: VisualDensity.compact,
                        iconSize: 20,
                        tooltip: widget.actions[i].tooltip,
                        icon: Icon(widget.actions[i].icon,
                            color: widget.actions[i].color),
                        onPressed: widget.actions[i].onPressed,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

// ==================== 公共工具 ====================

/// 弹出局域网管理地址二维码（设置面板与底部控制面板遥控器入口共用）。
///
/// 白色圆角卡片 + 圆角模块二维码，URL 独立底色展示，
/// 「复制地址 / 关闭」两个按钮等高并排，遥控器返回键也可关闭。
Future<void> showRemoteAdminQrDialog(BuildContext context, String url) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.72),
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 360),
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('手机扫码管理',
                style: TextStyle(
                    color: Color(0xFF11141B),
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text('手机与电脑连接同一 Wi‑Fi',
                style: TextStyle(color: Colors.black45, fontSize: 13)),
            const SizedBox(height: 18),
            // 二维码：白底圆角卡片内嵌圆角方块码，四周留白保证可识别
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.07),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: QrImageView(
                data: url,
                version: QrVersions.auto,
                size: 216,
                backgroundColor: Colors.white,
                padding: EdgeInsets.zero,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Color(0xFF141821),
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Color(0xFF141821),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFECEEF2),
                borderRadius: BorderRadius.circular(9),
              ),
              child: SelectableText(
                url,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Color(0xFF333A47),
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: url));
                      if (!ctx.mounted) return;
                      Navigator.pop(ctx);
                      OsdBus.show('地址已复制', icon: Icons.copy);
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('复制地址'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF333A47),
                      side: const BorderSide(color: Color(0xFFD2D7E0)),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(11)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(11)),
                    ),
                    child: const Text('关闭'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

InputDecoration _inputDecoration(String hint) {
  return InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Colors.white38),
    filled: true,
    fillColor: Colors.white10,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide.none,
    ),
    contentPadding:
        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );
}
