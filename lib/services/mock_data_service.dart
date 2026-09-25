import '../models/channel.dart';
import '../models/epg_program.dart';

/// 模拟数据服务 - 实际项目中可替换为网络请求
class MockDataService {
  /// 获取所有频道分类及频道列表
  static List<ChannelCategory> getCategories() {
    return [
      ChannelCategory(
        id: 'news',
        name: '新闻',
        channels: _newsChannels(),
      ),
      ChannelCategory(
        id: 'sports',
        name: '体育',
        channels: _sportsChannels(),
      ),
      ChannelCategory(
        id: 'movies',
        name: '电影',
        channels: _movieChannels(),
      ),
      ChannelCategory(
        id: 'entertainment',
        name: '综艺娱乐',
        channels: _entertainmentChannels(),
      ),
      ChannelCategory(
        id: 'documentary',
        name: '纪录片',
        channels: _documentaryChannels(),
      ),
    ];
  }

  static List<Channel> _newsChannels() {
    return [
      Channel(
        id: 'cctv1',
        name: 'CCTV-1 综合',
        streamUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        categoryId: 'news',
        isFavorite: true,
      ),
      Channel(
        id: 'cctv13',
        name: 'CCTV-13 新闻',
        streamUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        categoryId: 'news',
      ),
      Channel(
        id: 'cgtn',
        name: 'CGTN 英语新闻',
        streamUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        categoryId: 'news',
      ),
      Channel(
        id: 'phoenix',
        name: '凤凰卫视资讯',
        streamUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        categoryId: 'news',
      ),
    ];
  }

  static List<Channel> _sportsChannels() {
    return [
      Channel(
        id: 'cctv5',
        name: 'CCTV-5 体育',
        streamUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        categoryId: 'sports',
        isFavorite: true,
      ),
      Channel(
        id: 'cctv5p',
        name: 'CCTV-5+ 体育赛事',
        streamUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        categoryId: 'sports',
      ),
      Channel(
        id: 'guangdong_sports',
        name: '广东体育',
        streamUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        categoryId: 'sports',
      ),
    ];
  }

  static List<Channel> _movieChannels() {
    return [
      Channel(
        id: 'cctv6',
        name: 'CCTV-6 电影',
        streamUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        categoryId: 'movies',
      ),
      Channel(
        id: 'film_classic',
        name: '经典电影频道',
        streamUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        categoryId: 'movies',
      ),
      Channel(
        id: 'hbo',
        name: 'HBO 亚洲',
        streamUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        categoryId: 'movies',
      ),
    ];
  }

  static List<Channel> _entertainmentChannels() {
    return [
      Channel(
        id: 'cctv3',
        name: 'CCTV-3 综艺',
        streamUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        categoryId: 'entertainment',
      ),
      Channel(
        id: 'hunan',
        name: '湖南卫视',
        streamUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        categoryId: 'entertainment',
      ),
      Channel(
        id: 'zhejiang',
        name: '浙江卫视',
        streamUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        categoryId: 'entertainment',
      ),
      Channel(
        id: 'jiangsu',
        name: '江苏卫视',
        streamUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        categoryId: 'entertainment',
      ),
    ];
  }

  static List<Channel> _documentaryChannels() {
    return [
      Channel(
        id: 'cctv9',
        name: 'CCTV-9 纪录',
        streamUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        categoryId: 'documentary',
      ),
      Channel(
        id: 'discovery',
        name: '探索频道',
        streamUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        categoryId: 'documentary',
      ),
      Channel(
        id: 'natgeo',
        name: '国家地理',
        streamUrl: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        categoryId: 'documentary',
      ),
    ];
  }

  /// 获取指定频道的 EPG 节目单
  static List<EpgProgram> getEpgForChannel(String channelId) {
    final now = DateTime.now();
    final todayMidnight = DateTime(now.year, now.month, now.day);

    return List.generate(12, (index) {
      final start = todayMidnight.add(Duration(hours: index * 2));
      final end = start.add(const Duration(hours: 2));
      return EpgProgram(
        id: '${channelId}_$index',
        channelId: channelId,
        title: _programTitleFor(channelId, index),
        description: '节目描述 - $channelId 第 ${index + 1} 个时段',
        startTime: start,
        endTime: end,
      );
    });
  }

  static String _programTitleFor(String channelId, int index) {
    final titles = {
      'cctv1': ['新闻联播', '焦点访谈', '晚间新闻', '电视剧场', '生活圈', '星光大道', '开讲啦', '人与自然', '挑战不可能', '经典咏流传', '今日说法', '寻宝'],
      'cctv13': ['新闻直播间', '新闻1+1', '面对面', '新闻调查', '东方时空', '朝闻天下', '新闻三十分', '共同关注', '晚间新闻', '国际时讯', '世界周刊', '军情时间到'],
      'cctv5': ['体育新闻', 'NBA最前线', '足球之夜', '天下足球', '体育世界', '冠军欧洲', '篮球公园', '健身动起来', '棋牌乐', '谁是舞王', '运动空间', '体育人间'],
      'cctv6': ['中国电影报道', '佳片有约', '流金岁月', '电影人物', '今日影评', '首映', '电影全解码', '光影星播客', '世界电影之旅', '音乐之声', '专题片', '周末影院'],
    };
    final list = titles[channelId] ?? ['节目 $index', '精彩内容', '特别节目'];
    return list[index % list.length];
  }

  /// 获取当前正在播放的节目
  static EpgProgram? getCurrentProgram(String channelId) {
    final epg = getEpgForChannel(channelId);
    try {
      return epg.firstWhere((p) => p.isNowPlaying);
    } catch (_) {
      return null;
    }
  }

  /// 获取下一个节目
  static EpgProgram? getNextProgram(String channelId) {
    final epg = getEpgForChannel(channelId);
    final now = DateTime.now();
    for (final p in epg) {
      if (p.startTime.isAfter(now)) return p;
    }
    return null;
  }
}
