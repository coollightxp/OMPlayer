import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/epg_source.dart';
import '../models/player_settings.dart';
import '../models/playlist_source.dart';
import '../services/player_controller.dart';

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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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
        child: Material(
          color: Colors.black87,
          elevation: 24,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: SafeArea(
            top: false,
            child: Builder(builder: (context) {
              // 横屏手机等矮屏（高度<500）时面板几乎占满全高，避免太短无法操作
              final screenH = MediaQuery.of(context).size.height;
              return SizedBox(
                height: screenH * (screenH < 500 ? 0.95 : 0.7),
                child: Column(
                children: [
                  // 顶部拖拽条 + 标题
                  Container(
                    padding: const EdgeInsets.only(top: 10, bottom: 8),
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
                            IconButton(
                              icon:
                                  const Icon(Icons.close, color: Colors.white70),
                              onPressed: widget.onClose,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Tab 栏
                  TabBar(
                    controller: _tabController,
                    indicatorColor: Colors.blueAccent,
                    labelColor: Colors.blueAccent,
                    unselectedLabelColor: Colors.white54,
                    tabs: const [
                      Tab(text: '播放列表'),
                      Tab(text: 'EPG'),
                      Tab(text: '播放器'),
                      Tab(text: '系统'),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 1),
                  // Tab 内容
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        _PlaylistTab(),
                        _EpgTab(),
                        _PlayerSettingsTab(),
                        _SystemSettingsTab(),
                      ],
                    ),
                  ),
                ],
              ),
              );
            }),
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
    final file = await FilePicker.pickFile(
      type: FileType.any,
    );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写名称和地址')),
      );
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
                TextField(
                  controller: nameCtl,
                  style: const TextStyle(color: Colors.white),
                  decoration: _inputDecoration('列表名称'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
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
                          final f = await FilePicker.pickFile(
                              type: FileType.any);
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('地址已复制'), duration: Duration(seconds: 1)),
    );
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
                  TextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('列表名称（如：我的电视）'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
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
                return ListTile(
                  // 点击整行即切换为当前播放列表
                  onTap: isCurrent
                      ? null
                      : () => controller.selectPlaylist(p.id),
                  leading: Icon(
                    p.type == PlaylistSourceType.url
                        ? Icons.cloud
                        : Icons.folder,
                    color: isCurrent
                        ? Colors.blueAccent
                        : Colors.white54,
                  ),
                  title: Text(
                    p.name,
                    style: TextStyle(
                      color: isCurrent
                          ? Colors.blueAccent
                          : Colors.white,
                      fontWeight: isCurrent
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(
                    p.url,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 当前正在使用：蓝色对号（仅状态标识）
                      if (isCurrent)
                        const Icon(Icons.check_circle,
                            color: Colors.blueAccent, size: 22),
                      IconButton(
                        icon: const Icon(Icons.edit,
                            color: Colors.lightBlueAccent),
                        onPressed: () => _editPlaylist(p),
                        tooltip: '编辑',
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy,
                            color: Colors.white60),
                        onPressed: () => _copyPlaylist(p),
                        tooltip: '复制名称和地址',
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh,
                            color: Colors.amber),
                        onPressed: () =>
                            controller.refreshChannels(),
                        tooltip: '刷新',
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete,
                            color: Colors.redAccent),
                        onPressed: () =>
                            controller.removePlaylist(p.id),
                        tooltip: '删除',
                      ),
                    ],
                  ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写名称和地址')),
      );
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
            TextField(
              controller: nameCtl,
              style: const TextStyle(color: Colors.white),
              decoration: _inputDecoration('EPG 名称'),
            ),
            const SizedBox(height: 8),
            TextField(
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('地址已复制'), duration: Duration(seconds: 1)),
    );
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
                  TextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('EPG 名称（如：央视节目单）'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
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
                return ListTile(
                  // 点击整行即切换为当前 EPG
                  onTap: isCurrent
                      ? null
                      : () => controller.selectEpg(e.id),
                  leading: Icon(Icons.menu_book,
                      color: isCurrent
                          ? Colors.blueAccent
                          : Colors.white54),
                  title: Text(
                    e.name,
                    style: TextStyle(
                      color: isCurrent
                          ? Colors.blueAccent
                          : Colors.white,
                      fontWeight: isCurrent
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(
                    e.url,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 当前正在使用：蓝色对号（仅状态标识）
                      if (isCurrent)
                        const Icon(Icons.check_circle,
                            color: Colors.blueAccent, size: 22),
                      IconButton(
                        icon: const Icon(Icons.edit,
                            color: Colors.lightBlueAccent),
                        onPressed: () => _editEpg(e),
                        tooltip: '编辑',
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy,
                            color: Colors.white60),
                        onPressed: () => _copyEpg(e),
                        tooltip: '复制名称和地址',
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh,
                            color: Colors.amber),
                        onPressed: () => controller.refreshEpg(),
                        tooltip: '刷新',
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete,
                            color: Colors.redAccent),
                        onPressed: () => controller.removeEpg(e.id),
                        tooltip: '删除',
                      ),
                    ],
                  ),
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
            // 播放缓冲：分段选择 5/10/20/30 秒（重启后由 MDK 后端应用）
            ListTile(
              leading: const Icon(Icons.slow_motion_video,
                  color: Colors.white70),
              title: const Text('播放缓冲'),
              subtitle: const Text('弱网或直播卡顿可调大，修改后重启生效'),
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
          subtitle: SliderTheme(
            data: SliderThemeData(
              activeTrackColor: Colors.blueAccent,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.blueAccent,
              overlayColor: Colors.blueAccent.withOpacity(0.2),
              disabledActiveTrackColor: Colors.white24,
              disabledThumbColor: Colors.white38,
            ),
            child: Slider(
              // 自动模式下展示当前生效值但禁止拖动
              value: scale.clamp(0.8, 3.0),
              min: 0.8,
              max: 3.0,
              divisions: 22,
              label: '${scale.toStringAsFixed(1)}x',
              onChanged: s.uiScaleAuto
                  ? null
                  : (v) =>
                      controller.updateSettings(s.copyWith(uiScale: v)),
            ),
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
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: Colors.blueAccent,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.blueAccent,
              overlayColor: Colors.blueAccent.withOpacity(0.2),
            ),
            child: Slider(
              value: clamped,
              min: min,
              max: max,
              divisions: divisions,
              label: label,
              onChanged: onChanged,
            ),
          ),
        ],
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
            SwitchListTile(
              secondary: const Icon(Icons.access_time, color: Colors.white70),
              title: const Text('显示时间',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: const Text('右上角一直显示实时系统时间',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              value: s.showClock,
              onChanged: (v) =>
                  controller.updateSettings(s.copyWith(showClock: v)),
              activeColor: Colors.blueAccent,
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
                        '${controller.castLogPath.isNotEmpty ? '\n投屏异常时请反馈诊断日志：\n${controller.castLogPath}' : ''}'
                    : '未开启：服务已停止或端口被占用'
                        '${controller.castLogPath.isNotEmpty ? '\n投屏异常时请反馈诊断日志：\n${controller.castLogPath}' : ''}',
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
                  : () => _showRemoteAdminQr(context, controller.remoteAdminUrl),
            ),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }

  /// 弹出局域网管理地址二维码
  void _showRemoteAdminQr(BuildContext context, String url) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('手机扫码管理',
            style: TextStyle(color: Colors.black, fontSize: 17)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('手机与电脑连接同一 Wi‑Fi',
                style: TextStyle(color: Colors.black54, fontSize: 13)),
            const SizedBox(height: 16),
            QrImageView(
              data: url,
              version: QrVersions.auto,
              size: 220,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 12),
            SelectableText(url,
                style: const TextStyle(color: Colors.black87, fontSize: 14)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('地址已复制'),
                    duration: Duration(seconds: 1)),
              );
            },
            child: const Text('复制地址'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

// ==================== 公共工具 ====================

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
