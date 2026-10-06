import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/epg_source.dart';
import '../models/playlist_source.dart';
import '../services/player_controller.dart';

/// 节目源 / EPG 源管理窗口
/// 上：手机扫码管理二维码（未开启扫码时提示去偏好设置开启）
/// 中：源列表（勾选当前源 / 复制 URL / 删除）
/// 下：名称（选填）+ URL + 确定
class SourceManageDialog extends StatefulWidget {
  /// true=节目源(playlist)，false=EPG 源
  final bool isPlaylist;

  const SourceManageDialog({super.key, required this.isPlaylist});

  /// 打开窗口并返回对话框内组件的状态（供 player_screen 转发遥控器按键）
  static Future<void> present(
    BuildContext context, {
    required bool isPlaylist,
    required GlobalKey<SourceManageDialogState> key,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.72),
      builder: (_) => Dialog(
        backgroundColor: const Color(0xFF16181D),
        insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 40),
        child: SourceManageDialog(key: key, isPlaylist: isPlaylist),
      ),
    );
  }

  @override
  State<SourceManageDialog> createState() => SourceManageDialogState();
}

class SourceManageDialogState extends State<SourceManageDialog> {
  final _nameCtl = TextEditingController();
  final _urlCtl = TextEditingController();
  bool _saving = false;

  /// 遥控器平面焦点：每个源占 3 个槽位（选择/复制/删除），
  /// 最后一个槽位为「确定」。输入框用鼠标/软键盘操作。
  int _kbIndex = 0;

  @override
  void dispose() {
    _nameCtl.dispose();
    _urlCtl.dispose();
    super.dispose();
  }

  /// 遥控器/键盘按键入口（player_screen 在 modal 状态下转发）
  void handleRemoteKey(String action, {required bool isDown}) {
    if (!isDown || !mounted) return;
    final c = context.read<PlayerController>();
    final sources = widget.isPlaylist
        ? c.sourceManager.playlists
        : c.sourceManager.epgs;
    final max = sources.length * 3; // 最后一个槽位=确定
    switch (action) {
      case 'up':
        setState(() => _kbIndex = (_kbIndex - 1).clamp(0, max));
        _ensureVisible();
        break;
      case 'down':
        setState(() => _kbIndex = (_kbIndex + 1).clamp(0, max));
        _ensureVisible();
        break;
      case 'ok':
        if (_kbIndex == max) {
          _save();
        } else {
          final si = _kbIndex ~/ 3;
          final part = _kbIndex % 3;
          if (si >= sources.length) break;
          final src = sources[si];
          if (part == 0) {
            _select(src);
          } else if (part == 1) {
            _copy(src is PlaylistSource ? src.url : (src as EpgSource).url);
          } else {
            _delete(src);
          }
        }
        break;
      case 'back':
        Navigator.of(context).maybePop();
        break;
    }
  }

  final _slotKey = GlobalKey();
  final Map<int, GlobalKey> _slotKeys = {};
  final ScrollController _listScroll = ScrollController();

  void _ensureVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _slotKeys[_kbIndex]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: 0.5);
      }
    });
  }

  Future<void> _select(Object src) async {
    final c = context.read<PlayerController>();
    if (src is PlaylistSource) {
      await c.selectPlaylist(src.id);
    } else {
      await c.selectEpg((src as EpgSource).id);
    }
  }

  Future<void> _delete(Object src) async {
    final c = context.read<PlayerController>();
    final name =
        src is PlaylistSource ? src.name : (src as EpgSource).name;
    if (src is PlaylistSource) {
      await c.removePlaylist(src.id);
    } else {
      await c.removeEpg((src as EpgSource).id);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除：$name'), duration: const Duration(seconds: 2)),
      );
      final remaining = widget.isPlaylist
          ? c.sourceManager.playlists.length
          : c.sourceManager.epgs.length;
      // 清理已删除槽位的 GlobalKey，避免无主 key 残留
      _slotKeys.removeWhere((k, _) => k >= remaining * 3);
      setState(() {
        _kbIndex = _kbIndex.clamp(0, remaining * 3);
      });
    }
  }

  Future<void> _copy(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('地址已复制'), duration: Duration(seconds: 2)),
    );
  }

  Future<void> _save() async {
    final url = _urlCtl.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写源地址')),
      );
      return;
    }
    final name = _nameCtl.text.trim().isEmpty
        ? _fallbackName(url)
        : _nameCtl.text.trim();
    final c = context.read<PlayerController>();
    setState(() => _saving = true);
    try {
      if (widget.isPlaylist) {
        await c.addPlaylist(PlaylistSource(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: name,
          url: url,
          type: PlaylistSourceType.url,
          format: PlaylistFormat.unknown,
          addedAt: DateTime.now(),
        ));
      } else {
        await c.addEpg(EpgSource(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: name,
          url: url,
          addedAt: DateTime.now(),
        ));
      }
      if (!mounted) return;
      _nameCtl.clear();
      _urlCtl.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已添加：$name'), duration: const Duration(seconds: 2)),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _fallbackName(String url) {
    final u = Uri.tryParse(url);
    final host = u?.host ?? '';
    if (host.isNotEmpty) return host;
    return widget.isPlaylist ? '节目源' : 'EPG 源';
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isPlaylist ? '节目源设置' : 'EPG 源设置';
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏
            Row(
              children: [
                Icon(widget.isPlaylist ? Icons.live_tv : Icons.schedule,
                    color: Colors.white70, size: 21),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white54),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
            const Divider(height: 12, color: Colors.white12),
            _buildQrArea(),
            const SizedBox(height: 8),
            Flexible(child: _buildSourceList()),
            const Divider(height: 16, color: Colors.white12),
            _buildAddArea(),
          ],
        ),
      ),
    );
  }

  Widget _buildQrArea() {
    final c = context.watch<PlayerController>();
    final enabled = c.settings.remoteAdminEnabled;
    final url = c.remoteAdminUrl;
    if (!enabled || url.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          children: [
            Icon(Icons.info_outline, color: Colors.amber, size: 18),
            SizedBox(width: 8),
            Expanded(
              child: Text('请先在偏好设置开启手机扫码管理',
                  style: TextStyle(color: Colors.white60, fontSize: 12)),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: QrImageView(
              data: url,
              version: QrVersions.auto,
              size: 96,
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
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('手机扫码添加源',
                    style: TextStyle(color: Colors.white, fontSize: 13)),
                const SizedBox(height: 4),
                Text(url,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11)),
                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: () => _copy(url),
                  icon: const Icon(Icons.copy, size: 15),
                  label: const Text('复制地址'),
                  style: TextButton.styleFrom(
                      foregroundColor: Colors.lightBlueAccent,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 32)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceList() {
    final c = context.watch<PlayerController>();
    final sources =
        widget.isPlaylist ? c.sourceManager.playlists : c.sourceManager.epgs;
    final currentId = widget.isPlaylist
        ? c.sourceManager.currentPlaylistId
        : c.sourceManager.currentEpgId;
    if (sources.isEmpty) {
      return const Center(
        child: Text('暂无源，请在下方添加',
            style: TextStyle(color: Colors.white38, fontSize: 13)),
      );
    }
    return ListView.builder(
      key: _slotKey,
      controller: _listScroll,
      shrinkWrap: true,
      itemCount: sources.length,
      itemBuilder: (context, index) {
        final src = sources[index];
        final name = src is PlaylistSource ? src.name : (src as EpgSource).name;
        final url = src is PlaylistSource ? src.url : (src as EpgSource).url;
        final isCurrent =
            (src is PlaylistSource ? src.id : (src as EpgSource).id) ==
                currentId;
        final base = index * 3;
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              _slotButton(
                slot: base,
                icon: isCurrent
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                color: isCurrent ? Colors.blueAccent : Colors.white38,
                tooltip: isCurrent ? '当前源' : '切换为当前源',
                onPressed: () => _select(src),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13)),
                    Text(url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11)),
                  ],
                ),
              ),
              _slotButton(
                slot: base + 1,
                icon: Icons.copy,
                color: Colors.white60,
                tooltip: '复制地址',
                onPressed: () => _copy(url),
              ),
              _slotButton(
                slot: base + 2,
                icon: Icons.delete,
                color: Colors.redAccent,
                tooltip: '删除',
                onPressed: () => _delete(src),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 遥控器槽位按钮：键盘焦点框 + 鼠标点击二合一
  Widget _slotButton({
    required int slot,
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    final focused = slot == _kbIndex;
    final key = _slotKeys[slot] ??= GlobalKey();
    return IconButton(
      key: key,
      icon: Icon(icon, size: 19),
      color: color,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        side: focused
            ? const BorderSide(color: Colors.white70, width: 1.4)
            : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      onPressed: onPressed,
    );
  }

  Widget _buildAddArea() {
    final confirmSlot =
        (widget.isPlaylist
                ? context.watch<PlayerController>().sourceManager.playlists
                : context.watch<PlayerController>().sourceManager.epgs)
            .length *
            3;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _nameCtl,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '名称（选填）',
                  labelStyle: TextStyle(color: Colors.white38),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.blueAccent),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _urlCtl,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '源地址（http://...）',
                  labelStyle: TextStyle(color: Colors.white38),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.blueAccent),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: Builder(builder: (context) {
            final focused = confirmSlot == _kbIndex;
            return Container(
              key: _slotKeys[confirmSlot] ??= GlobalKey(),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: focused
                    ? Border.all(color: Colors.white70, width: 1.4)
                    : null,
              ),
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check, size: 18),
                label: const Text('确定'),
              ),
            );
          }),
        ),
      ],
    );
  }
}
