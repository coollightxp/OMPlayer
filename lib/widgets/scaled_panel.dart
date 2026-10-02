import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/player_controller.dart';

/// 安卓面板缩放因子：按屏幕【最短边】判断设备形态
/// （手机横屏时宽度是长边，不能按宽度判）。
/// - 手机（最短边 < 600）：0.72
/// - 小平板（600 ~ 700）：0.9
/// - 大平板 / 安卓 TV / 桌面：1.0
double panelScaleOf(BuildContext context) {
  final shortest = MediaQuery.of(context).size.shortestSide;
  if (shortest < 600) return 0.72;
  if (shortest < 700) return 0.9;
  return 1.0;
}

/// 面板【整体】等比缩放。
///
/// 与只改 textScaler（字小框大）不同：Transform.scale 把外框/内边距/
/// 图标/文字一起等比缩小，命中区域同步缩放。
///
/// 面板内文字只受用户在设置里的「界面缩放」(uiScale) 控制，
/// 形态缩放全部交给 Transform，避免与 app.dart 的全局缩放叠加。
class ScaledPanel extends StatelessWidget {
  /// 设计稿宽度：
  /// - 抽屉：child 需要按固定宽度（如 320）布局而外框只占 230，
  ///   传入此值时内部用 OverflowBox；
  /// - 底部/设置面板：传 null（或不传），child 正常布局后直接缩放，
  ///   命中行为与 v1.0.98 一致
  final double? designWidth;

  /// 缩放对齐方向：左抽屉 centerLeft、右抽屉 centerRight、
  /// 底部面板 bottomCenter
  final Alignment alignment;

  /// 缩放因子（用 [panelScaleOf] 获取）
  final double scale;

  final Widget child;

  const ScaledPanel({
    super.key,
    this.designWidth,
    required this.alignment,
    required this.scale,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final settings = context.watch<PlayerController>().settings;
    // 面板内只保留用户自己的界面缩放设置
    final userScale =
        settings.uiScaleAuto ? 1.0 : settings.uiScale.clamp(0.8, 3.0);
    Widget content = MediaQuery(
      data: mq.copyWith(textScaler: TextScaler.linear(userScale)),
      child: child,
    );
    if (scale == 1.0) return content;
    final dw = designWidth;
    if (dw != null) {
      // 抽屉：child 按设计宽度布局（外框比设计宽度窄）
      return OverflowBox(
        minWidth: dw,
        maxWidth: dw,
        alignment: alignment,
        child: Transform.scale(
          scale: scale,
          alignment: alignment,
          child: content,
        ),
      );
    }
    // 底部/设置面板：正常布局 + 整体缩放
    return Transform.scale(
      scale: scale,
      alignment: alignment,
      child: content,
    );
  }
}
