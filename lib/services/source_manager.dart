import 'dart:convert' show jsonDecode, utf8;
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fl_charset/fl_charset.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import '../models/epg_program.dart';
import '../models/epg_source.dart';
import '../models/playlist_source.dart';
import 'playlist_parser.dart';
import 'xmltv_epg_parser.dart';

/// 播放列表与 EPG 源管理服务
/// 负责：源的增删改查、本地持久化、网络拉取与解析
class SourceManager {
  static const String _playlistKey = 'omplayer_playlists';
  static const String _currentPlaylistKey = 'omplayer_current_playlist';
  static const String _epgKey = 'omplayer_epgs';
  static const String _currentEpgKey = 'omplayer_current_epg';

  List<PlaylistSource> _playlists = [];
  List<EpgSource> _epgs = [];
  String? _currentPlaylistId;
  String? _currentEpgId;

  // 缓存解析后的数据
  List<ChannelCategory> _cachedChannels = [];
  Map<String, List<EpgProgram>> _cachedEpg = {};
  /// EPG 频道 id -> 显示名列表
  Map<String, List<String>> _cachedEpgChannelNames = {};
  /// EPG 频道 id -> 台标地址
  Map<String, String> _cachedEpgChannelIcons = {};
  bool _channelsLoaded = false;
  bool _epgLoaded = false;

  List<PlaylistSource> get playlists => List.unmodifiable(_playlists);
  List<EpgSource> get epgs => List.unmodifiable(_epgs);
  String? get currentPlaylistId => _currentPlaylistId;
  String? get currentEpgId => _currentEpgId;
  List<ChannelCategory> get cachedChannels => _cachedChannels;
  Map<String, List<EpgProgram>> get cachedEpg => _cachedEpg;
  bool get channelsLoaded => _channelsLoaded;
  bool get epgLoaded => _epgLoaded;

  PlaylistSource? get currentPlaylist {
    if (_currentPlaylistId == null) return null;
    try {
      return _playlists.firstWhere((p) => p.id == _currentPlaylistId);
    } catch (_) {
      return null;
    }
  }

  EpgSource? get currentEpg {
    if (_currentEpgId == null) return null;
    try {
      return _epgs.firstWhere((e) => e.id == _currentEpgId);
    } catch (_) {
      return null;
    }
  }

  // ==================== 持久化 ====================

  Future<void> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final playlistStr = prefs.getString(_playlistKey);
    if (playlistStr != null && playlistStr.isNotEmpty) {
      _playlists = PlaylistSource.decodeList(playlistStr);
    }
    _currentPlaylistId = prefs.getString(_currentPlaylistKey);

    final epgStr = prefs.getString(_epgKey);
    if (epgStr != null && epgStr.isNotEmpty) {
      _epgs = EpgSource.decodeList(epgStr);
    }
    _currentEpgId = prefs.getString(_currentEpgKey);
  }

  Future<void> _savePlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_playlistKey, PlaylistSource.encodeList(_playlists));
    if (_currentPlaylistId != null) {
      await prefs.setString(_currentPlaylistKey, _currentPlaylistId!);
    } else {
      await prefs.remove(_currentPlaylistKey);
    }
  }

  Future<void> _saveEpgs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_epgKey, EpgSource.encodeList(_epgs));
    if (_currentEpgId != null) {
      await prefs.setString(_currentEpgKey, _currentEpgId!);
    } else {
      await prefs.remove(_currentEpgKey);
    }
  }

  // ==================== 播放列表管理 ====================

  /// 添加播放列表源
  Future<void> addPlaylist(PlaylistSource source) async {
    _playlists.add(source);
    await _savePlaylists();
  }

  /// 删除播放列表源
  Future<void> removePlaylist(String id) async {
    _playlists.removeWhere((p) => p.id == id);
    if (_currentPlaylistId == id) {
      _currentPlaylistId = null;
      _cachedChannels = [];
      _channelsLoaded = false;
    }
    await _savePlaylists();
  }

  /// 编辑播放列表源（名称/地址/类型）；地址变化后需重新加载频道
  Future<void> updatePlaylist(PlaylistSource source) async {
    final idx = _playlists.indexWhere((p) => p.id == source.id);
    if (idx < 0) return;
    _playlists[idx] = source;
    await _savePlaylists();
  }

  /// 全量替换（Web 管理端保存）：返回当前选中项是否仍存在
  Future<bool> replacePlaylists(
      List<PlaylistSource> list, String? currentId) async {
    _playlists = list;
    _currentPlaylistId =
        list.any((p) => p.id == currentId) ? currentId : null;
    await _savePlaylists();
    return _currentPlaylistId != null;
  }

  /// 选择当前使用的播放列表
  Future<void> selectPlaylist(String? id) async {
    _currentPlaylistId = id;
    await _savePlaylists();
  }

  /// 加载并解析当前播放列表的频道
  Future<List<ChannelCategory>> loadChannels() async {
    final source = currentPlaylist;
    if (source == null) {
      _cachedChannels = [];
      _channelsLoaded = true;
      return [];
    }

    try {
      final List<int> bytes;
      if (source.type == PlaylistSourceType.local) {
        bytes = await File(source.url).readAsBytes();
      } else {
        bytes = await _fetchPlaylistBytes(source.url);
      }

      final content = _decodePlaylistBytes(bytes);
      // 三级解析：m3u/txt 直接解析；HTML 聚合页提取 data-copy 接口地址；
      // TVBox 配置 JSON（lives）/多仓 JSON（urls）递归展开合并
      _cachedChannels = await _resolveContent(content, source.url, 2,
          {source.url});
      _channelsLoaded = true;

      // 更新最后更新时间
      final idx = _playlists.indexWhere((p) => p.id == source.id);
      if (idx >= 0) {
        _playlists[idx] = source.copyWith(lastUpdated: DateTime.now());
        await _savePlaylists();
      }
    } catch (e) {
      _cachedChannels = [];
      _channelsLoaded = true;
      rethrow;
    }
    return _cachedChannels;
  }

  /// 拉取网络播放列表字节：
  /// 国内盒子生态源（DIYP/影视仓）面向 okhttp 客户端，浏览器 UA 反而会被
  /// 广告劫持页拦截；个别源又只认浏览器。策略：先用 okhttp，
  /// 若返回内容是 HTML 广告页则换浏览器 UA 重试一次。
  static const _uaBox = 'okhttp/3.15';
  static const _uaBrowser =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  Future<List<int>> _fetchPlaylistBytes(String url,
      {Duration timeout = const Duration(seconds: 60)}) async {
    Future<List<int>> get(String ua) async {
      final resp = await http
          .get(
            Uri.parse(url),
            headers: {'User-Agent': ua, 'Accept': '*/*'},
          )
          .timeout(timeout);
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      return resp.bodyBytes;
    }

    final first = await get(_uaBox);
    final text = _decodePlaylistBytes(first).trimLeft().toLowerCase();
    final looksLikeHtml = text.startsWith('<!doctype html') ||
        text.startsWith('<html') ||
        (text.startsWith('<!--') && text.contains('<script'));
    if (looksLikeHtml) {
      return get(_uaBrowser);
    }
    return first;
  }

  /// 播放列表编码自动识别：
  /// 1. BOM：UTF-8(EF BB BF) / UTF-16 LE/BE
  /// 2. 严格 UTF-8 解码成功 → UTF-8（GBK 中文双字节几乎不可能通过 UTF-8 校验）
  /// 3. 失败 → GBK/GB18030（国内 DIYP/盒子分享源常见 ANSI 编码）
  /// 4. 都失败 → 宽松 UTF-8（不丢数据，乱码字符替换显示）
  static String _decodePlaylistBytes(List<int> bytes) {
    if (bytes.isEmpty) return '';
    // UTF-8 BOM
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3));
    }
    try {
      return utf8.decode(bytes);
    } catch (_) {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        return utf8.decode(bytes, allowMalformed: true);
      }
    }
  }

  // ==================== 内容递归解析 ====================
  // 盒子生态常见三级结构：
  // 1) HTML 聚合分享页（影视仓等）：卡片带 data-copy="接口地址" data-name="名称"
  // 2) TVBox 配置 JSON（lives 数组，type=0 为直链）/ 多仓 JSON（urls 数组）
  // 3) m3u / TXT 直播源（PlaylistParser 处理）
  // 递归展开并合并所有频道路径；深度限制 + 已访问集合防自引用死循环。

  static final _htmlTagRe = RegExp(r'<[^>]+>');
  static final _copyAttrRe =
      RegExp('data-copy\\s*=\\s*["\']([^"\']+)["\']');

  Future<List<ChannelCategory>> _resolveContent(
      String content, String url, int depth, Set<String> visited) async {
    final t = content.trimLeft();
    final lower = t.toLowerCase();
    if (lower.startsWith('<')) {
      if (depth <= 0) return const [];
      return _resolveHtmlPage(content, depth, visited);
    }
    if (t.startsWith('{')) {
      if (depth <= 0) return const [];
      return _resolveTvboxConfig(content, depth, visited);
    }
    final format = PlaylistParser.detectFormat(content, url);
    return PlaylistParser.parse(content, format);
  }

  /// HTML 聚合页：提取所有 data-copy 接口地址，逐个递归解析
  Future<List<ChannelCategory>> _resolveHtmlPage(
      String content, int depth, Set<String> visited) async {
    final results = <List<ChannelCategory>>[];
    for (final m in _htmlTagRe.allMatches(content)) {
      final tag = m.group(0)!;
      if (!tag.contains('data-copy')) continue;
      final c = _copyAttrRe.firstMatch(tag);
      if (c == null) continue;
      final cats = await _resolveUrl(c.group(1)!, depth - 1, visited);
      if (cats.isNotEmpty) results.add(cats);
    }
    return _mergeCategories(results);
  }

  /// TVBox 配置 JSON（lives）/ 多仓 JSON（urls）：展开子地址递归解析。
  /// lives 中 type=0 才是直链列表（1/2/3 为代理/jar 类型无法直连）；
  /// clan:// 等本地协议直接跳过
  Future<List<ChannelCategory>> _resolveTvboxConfig(
      String content, int depth, Set<String> visited) async {
    dynamic json;
    try {
      json = jsonDecode(content);
    } catch (_) {
      return const [];
    }
    if (json is! Map) return const [];
    final results = <List<ChannelCategory>>[];

    final lives = json['lives'];
    if (lives is List) {
      for (final live in lives) {
        if (live is! Map) continue;
        if ('${live['type']}' != '0') continue;
        final u = live['url'];
        if (u is! String) continue;
        final cats = await _resolveUrl(u, depth - 1, visited);
        if (cats.isNotEmpty) results.add(cats);
      }
    }

    final urls = json['urls'];
    if (urls is List) {
      for (final e in urls) {
        if (e is! Map) continue;
        final u = e['url'];
        if (u is! String) continue;
        final cats = await _resolveUrl(u, depth - 1, visited);
        if (cats.isNotEmpty) results.add(cats);
      }
    }
    return _mergeCategories(results);
  }

  /// 拉取并解析单个子地址（15 秒超时，单个失败不影响其它）
  Future<List<ChannelCategory>> _resolveUrl(
      String url, int depth, Set<String> visited) async {
    final u = url.trim();
    if (u.isEmpty ||
        visited.contains(u) ||
        !(u.startsWith('http://') || u.startsWith('https://'))) {
      return const [];
    }
    visited.add(u);
    try {
      final bytes = await _fetchPlaylistBytes(u,
          timeout: const Duration(seconds: 15));
      final content = _decodePlaylistBytes(bytes);
      return await _resolveContent(content, u, depth, visited);
    } catch (_) {
      return const [];
    }
  }

  /// 按分类名合并多路解析结果（同名频道交由 PlaylistParser 的合并键处理）
  List<ChannelCategory> _mergeCategories(
      Iterable<List<ChannelCategory>> lists) {
    final merged = <String, List<Channel>>{};
    final order = <String>[];
    for (final list in lists) {
      for (final c in list) {
        if (merged.containsKey(c.name)) {
          merged[c.name]!.addAll(c.channels);
        } else {
          merged[c.name] = List<Channel>.from(c.channels);
          order.add(c.name);
        }
      }
    }
    return [
      for (final name in order)
        ChannelCategory(id: name, name: name, channels: merged[name]!)
    ];
  }

  // ==================== EPG 管理 ====================

  /// 添加 EPG 源
  Future<void> addEpg(EpgSource source) async {
    _epgs.add(source);
    await _saveEpgs();
  }

  /// 删除 EPG 源
  Future<void> removeEpg(String id) async {
    _epgs.removeWhere((e) => e.id == id);
    if (_currentEpgId == id) {
      _currentEpgId = null;
      _cachedEpg = {};
      _epgLoaded = false;
    }
    await _saveEpgs();
  }

  /// 选择当前使用的 EPG
  Future<void> selectEpg(String? id) async {
    _currentEpgId = id;
    await _saveEpgs();
  }

  /// 编辑 EPG 源（名称/地址）
  Future<void> updateEpg(EpgSource source) async {
    final idx = _epgs.indexWhere((e) => e.id == source.id);
    if (idx < 0) return;
    _epgs[idx] = source;
    await _saveEpgs();
  }

  /// 全量替换（Web 管理端保存）
  Future<void> replaceEpgs(List<EpgSource> list, String? currentId) async {
    _epgs = list;
    _currentEpgId = list.any((e) => e.id == currentId) ? currentId : null;
    await _saveEpgs();
  }

  /// 加载并解析当前 EPG 数据
  Future<Map<String, List<EpgProgram>>> loadEpg() async {
    final source = currentEpg;
    if (source == null) {
      _cachedEpg = {};
      _epgLoaded = true;
      return {};
    }

    try {
      final resp = await http
          .get(Uri.parse(source.url))
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }

      // 支持 .gz 压缩的 EPG（按 gzip 魔数 1f 8b 判断，不依赖扩展名）
      final bytes = resp.bodyBytes;
      final body =
          (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b)
              ? utf8.decode(GZipDecoder().decodeBytes(bytes))
              : utf8.decode(bytes);
      final parsed = XmltvEpgParser.parse(body);
      _cachedEpg = parsed.programs;
      _cachedEpgChannelNames = parsed.channelNames;
      _cachedEpgChannelIcons = parsed.channelIcons;
      _epgLoaded = true;

      final idx = _epgs.indexWhere((e) => e.id == source.id);
      if (idx >= 0) {
        _epgs[idx] = source.copyWith(lastUpdated: DateTime.now());
        await _saveEpgs();
      }
    } catch (e) {
      _cachedEpg = {};
      _epgLoaded = true;
      rethrow;
    }
    return _cachedEpg;
  }

  /// 根据频道获取 EPG 节目列表
  List<EpgProgram> getProgramsForChannel(Channel channel) {
    return XmltvEpgParser.findProgramsForChannel(
        channel, _cachedEpg, _cachedEpgChannelNames);
  }

  /// 获取频道台标：优先 M3U tvg-logo，其次 EPG icon
  String getLogoForChannel(Channel channel) {
    if (channel.logoUrl.isNotEmpty) return channel.logoUrl;
    final id = XmltvEpgParser.matchChannelId(
        channel, _cachedEpg, _cachedEpgChannelNames);
    return id == null ? '' : (_cachedEpgChannelIcons[id] ?? '');
  }
}
