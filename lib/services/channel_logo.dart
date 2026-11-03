import 'package:flutter/services.dart';

import '../models/channel.dart';

/// 频道台标解析。
///
/// 优先级：节目源里指定的 `tvg-logo`（网络图）→ 内置 `assets/logos` 里
/// 按频道名匹配的台标 → 都没有则由界面显示占位图标。
class ChannelLogo {
  ChannelLogo._();

  static const String _dir = 'assets/logos/';

  /// 归一化频道名 → 资源路径（启动后加载一次）
  static Map<String, String>? _assets;

  /// 频道名里常见的、不参与匹配的修饰词。频道名常带「高清/频道/HD」
  /// 等后缀，而台标文件名一般不带，匹配时逐个剥离再试
  static const List<String> _noise = [
    '(高清)',
    '(超清)',
    '(标清)',
    '高清',
    '超清',
    '标清',
    '频道',
    'hd',
    '4k',
    '8k',
  ];

  /// 读取 AssetManifest，建立「归一化文件名 → 资源路径」索引。
  /// 只做一次，代价约几毫秒；失败时保持空表（界面回落到占位）
  static Future<void> ensureLoaded() async {
    if (_assets != null) return;
    final map = <String, String>{};
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      for (final key in manifest.listAssets()) {
        if (!key.startsWith(_dir)) continue;
        final file = key.substring(_dir.length);
        if (!file.toLowerCase().endsWith('.png')) continue;
        map[normalize(file.substring(0, file.length - 4))] = key;
      }
    } catch (_) {
      // 拿不到清单不影响播放，台标走占位
    }
    _assets = map;
  }

  /// 归一化：转小写、去空白、全角括号转半角、去掉 `-`/`·`、`+` 记作 plus
  static final _spaceRe = RegExp(r'\s+');

  static String normalize(String s) => s
      .toLowerCase()
      .replaceAll(_spaceRe, '')
      .replaceAll('（', '(')
      .replaceAll('）', ')')
      .replaceAll('-', '')
      .replaceAll('·', '')
      .replaceAll('+', 'plus');

  /// 频道对应的内置台标资源路径；没有匹配返回空串
  static String assetFor(Channel channel) {
    final map = _assets;
    if (map == null) {
      ensureLoaded();
      return '';
    }
    if (map.isEmpty) return '';
    var name = channel.name.trim();
    if (name.isEmpty) return '';

    // 1. 完整原名归一化精确命中
    for (int i = 0; i <= _noise.length; i++) {
      final hit = map[normalize(name)];
      if (hit != null) return hit;
      final lower = name.toLowerCase();
      for (final noise in _noise) {
        if (lower.endsWith(noise)) {
          name = name.substring(0, name.length - noise.length).trim();
          break;
        }
      }
      if (name.isEmpty) break;
    }

    // 2. 字母+数字核心（汉字全丢，只留英数）：
    //    "CCTV1综合频道" → "cctv1"，能命中 asset 里 "cctv1.png"
    //    "湖南卫视" → 空（没英数），跳过
    final core = _lettersAndDigitsOnly(channel.name);
    if (core.isNotEmpty) {
      final hit = map[core];
      if (hit != null) return hit;
      // "cctv5plus" vs "cctv5+"：asset 里可能写成 cctv5plus 或 cctv5+
      final withPlus = core.replaceFirst('plus', '+');
      if (withPlus != core) {
        final hit2 = map[withPlus];
        if (hit2 != null) return hit2;
      }
    }

    // 3. tvg-name 里的字母核心（播放源可能有 tvg-name="cctv1"）
    if (channel.tvgName.isNotEmpty) {
      final c = _lettersAndDigitsOnly(channel.tvgName);
      if (c.isNotEmpty) {
        final hit = map[c];
        if (hit != null) return hit;
      }
    }

    return '';
  }

  /// 从频道名里提取英+数字核心（其他汉字/标点全丢）。
  /// 要求至少同时含字母和数字（避免 "体育"→空；"5"→太泛）
  static String _lettersAndDigitsOnly(String s) {
    final sb = StringBuffer();
    bool sawLetter = false;
    bool sawDigit = false;
    for (final code in s.toLowerCase().codeUnits) {
      if ((code >= 97 && code <= 122) || (code >= 48 && code <= 57)) {
        sb.writeCharCode(code);
        if (code >= 97) sawLetter = true;
        if (code >= 48) sawDigit = true;
      }
    }
    if (sawLetter && sawDigit) return sb.toString();
    return '';
  }
}
