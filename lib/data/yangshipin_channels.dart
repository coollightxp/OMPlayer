import '../models/channel.dart';

/// 央视频道数据模块（独立、可随时替换的静态表）。
///
/// 播放方式与普通网页频道完全一致：
/// `webview://https://yangshipin.cn/tv/home?pid=<pid>`，由现有 WebView 链路
/// 加载官方页面播放，不做直链/cKey 解析。
/// 台标取自 assets/logos/<logoId>.png（用户提供的台标包）。
/// 频道 id 直接用央视频 pid，收藏/上次播放记录天然兼容。
class YangshipinChannels {
  const YangshipinChannels._();

  static const String webBase = 'https://yangshipin.cn/tv/home?pid=';

  static Channel _yangshin(
      String name, String pid, String logoId, String categoryId) {
    return Channel(
      id: pid,
      name: name,
      logoUrl: 'assets/logos/$logoId.png',
      streamUrls: ['webview://$webBase$pid'],
      categoryId: categoryId,
      tvgId: pid,
      tvgName: name,
      groupTitle: categoryId,
    );
  }

  static Channel _webPage(
      String name, String id, String url, String logoId, String categoryId) {
    return Channel(
      id: id,
      name: name,
      logoUrl: 'assets/logos/$logoId.png',
      streamUrls: ['webview://$url'],
      categoryId: categoryId,
      tvgId: id,
      tvgName: name,
      groupTitle: categoryId,
    );
  }

  // ==================== 央视频道 ====================
  static const List<List<String>> _cctv = [
    ['CCTV-1', '600001859', 'cctv1'],
    ['CCTV-2', '600001800', 'cctv2'],
    ['CCTV-3', '600001801', 'cctv3'],
    ['CCTV-4', '600001814', 'cctv4'],
    ['CCTV-5', '600001818', 'cctv5'],
    ['CCTV-5+', '600001817', 'cctv5plus'],
    ['CCTV-6', '600108442', 'cctv6'],
    ['CCTV-7', '600004092', 'cctv7'],
    ['CCTV-8', '600001803', 'cctv8'],
    ['CCTV-9', '600004078', 'cctv9'],
    ['CCTV-10', '600001805', 'cctv10'],
    ['CCTV-11', '600001806', 'cctv11'],
    ['CCTV-12', '600001807', 'cctv12'],
    ['CCTV-13', '600001811', 'cctv13'],
    ['CCTV-14', '600001809', 'cctv14'],
    ['CCTV-15', '600001815', 'cctv15'],
    ['CCTV-16', '600098637', 'cctv16'],
    ['CCTV-17', '600001810', 'cctv17'],
    ['CCTV-4K', '600002264', 'cctv4k'],
    ['CCTV-8K', '600156816', 'cctv8k'],
    ['CGTN', '600014550', 'cgtn'],
    ['CGTN 纪录', '600084781', 'cgtn_doc'],
    ['CGTN 西班牙语', '600084744', 'cgtn_es'],
    ['CGTN 法语', '600084704', 'cgtn_fr'],
    ['CGTN 阿拉伯语', '600084782', 'cgtn_ar'],
    ['CGTN 俄语', '600084758', 'cgtn_ru'],
  ];

  // ==================== 卫视频道 ====================
  static const List<List<String>> _satellite = [
    ['北京卫视', '600002309', 'bjws'],
    ['天津卫视', '600152137', 'tjws'],
    ['河北卫视', '600002493', 'hebws'],
    ['山西卫视', '600190407', 'sxws'],
    ['内蒙古卫视', '600190401', 'nmgws'],
    ['辽宁卫视', '600002505', 'lnws'],
    ['吉林卫视', '600190405', 'jlws'],
    ['黑龙江卫视', '600002498', 'hljws'],
    ['东方卫视', '600002483', 'dfws'],
    ['江苏卫视', '600002521', 'jsws'],
    ['浙江卫视', '600002520', 'zjws'],
    ['安徽卫视', '600002532', 'ahws'],
    ['东南卫视', '600002484', 'dnws'],
    ['江西卫视', '600002503', 'jxws'],
    ['山东卫视', '600002513', 'sdws'],
    ['河南卫视', '600002525', 'hnws'],
    ['湖北卫视', '600002508', 'hbws'],
    ['湖南卫视', '600002475', 'hunws'],
    ['广东卫视', '600002485', 'gdws'],
    ['深圳卫视', '600002481', 'szws'],
    ['广西卫视', '600002509', 'gxws'],
    ['海南卫视', '600002506', 'haiws'],
    ['重庆卫视', '600002531', 'cqws'],
    ['四川卫视', '600002516', 'scws'],
    ['贵州卫视', '600002490', 'gzws'],
    ['云南卫视', '600190402', 'ynws'],
    ['西藏卫视', '600190403', 'xzws'],
    ['陕西卫视', '600190400', 'sxanws'],
    ['甘肃卫视', '600190408', 'gsws'],
    ['青海卫视', '600190406', 'qhws'],
    ['宁夏卫视', '600190737', 'nxws'],
  ];

  // ==================== CCTV 数字付费 ====================
  static const List<List<String>> _digital = [
    ['CCTV 风云剧场', '600099658', 'fyjc'],
    ['CCTV 第一剧场', '600099655', 'dyjc'],
    ['CCTV 怀旧剧场', '600099620', 'hjjc'],
  ];

  // ==================== 教育频道（广西台网页直播，无央视频 EPG） ====================
  static const List<List<String>> _cetv = [
    [
      'CETV-1',
      'cetv1',
      'cetv1',
      'https://tv.gxtv.cn/channel/channelivePlay_ffa6b6e1b32b4a16a73eb3ef66f8bfc7.html'
    ],
    [
      'CETV-2',
      'cetv2',
      'cetv2',
      'https://tv.gxtv.cn/channel/channelivePlay_80d0ffb42c114eaf9663708629ff0a3e.html'
    ],
    [
      'CETV-4',
      'cetv4',
      'cetv4',
      'https://tv.gxtv.cn/channel/channelivePlay_67eace939278435bb4bca90800fb4225.html'
    ],
  ];

  static List<Channel> get cctvChannels =>
      _cctv.map((e) => _yangshin(e[0], e[1], e[2], 'cctv')).toList(growable: false);

  static List<Channel> get satelliteChannels => _satellite
      .map((e) => _yangshin(e[0], e[1], e[2], 'satellite'))
      .toList(growable: false);

  static List<Channel> get digitalChannels =>
      _digital.map((e) => _yangshin(e[0], e[1], e[2], 'digital')).toList(growable: false);

  static List<Channel> get educationChannels => _cetv
      .map((e) => _webPage(e[0], e[1], e[3], e[2], 'cetv'))
      .toList(growable: false);

  /// 全部频道分类（左侧抽屉第一级）
  static List<ChannelCategory> get categories => [
        ChannelCategory(id: 'cctv', name: '央视频道', channels: cctvChannels),
        ChannelCategory(
            id: 'satellite', name: '卫视频道', channels: satelliteChannels),
        ChannelCategory(
            id: 'digital', name: '数字付费', channels: digitalChannels),
        ChannelCategory(
            id: 'cetv', name: '教育频道', channels: educationChannels),
      ];

  static List<Channel> get allChannels =>
      [...cctvChannels, ...satelliteChannels, ...digitalChannels, ...educationChannels];

  /// 有 EPG 的频道 pid 列表（教育频道走第三方网页，没有央视频节目单）
  static List<String> get epgPids => [
        ..._cctv.map((e) => e[1]),
        ..._satellite.map((e) => e[1]),
        ..._digital.map((e) => e[1]),
      ];
}
