import 'package:flutter/material.dart';

import '../theme.dart';

/// The one lifted-surface look shared by every card in this app: rounded
/// corners, a hairline border, and [Sparkle.cardShadow]. Pass [onTap] to get
/// tap feedback (Material + InkWell) for free; everything else defaults to
/// the plain resting state and only needs overriding where a screen wants a
/// different border/background/shadow (e.g. a verified or active state).
class SparkleCard extends StatelessWidget {
  const SparkleCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Sparkle.s4),
    this.onTap,
    this.color = Sparkle.surface,
    this.borderColor = Sparkle.hairline,
    this.borderWidth = 1,
    this.boxShadow = Sparkle.cardShadow,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color color;
  final Color borderColor;
  final double borderWidth;
  final List<BoxShadow> boxShadow;

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(Sparkle.radius),
        border: Border.all(color: borderColor, width: borderWidth),
        boxShadow: boxShadow,
      ),
      child: child,
    );

    if (onTap == null) return content;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(Sparkle.radius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Sparkle.radius),
        child: content,
      ),
    );
  }
}
