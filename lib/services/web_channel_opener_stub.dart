import 'package:url_launcher/url_launcher.dart';

/// 打开网页频道（Web 端）：新标签页打开网站，由网站自身播放器播放
Future<void> openWebChannel(String url, String title) async {
  await launchUrl(
    Uri.parse(url),
    mode: LaunchMode.externalApplication,
    webOnlyWindowName: '_blank',
  );
}
