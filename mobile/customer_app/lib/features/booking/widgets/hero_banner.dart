import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme.dart';

/// Soft gradient banner with a duotone illustration — shared by service/home steps.
class HeroBanner extends StatelessWidget {
  const HeroBanner({super.key, required this.imageAsset, this.headline});

  final String imageAsset;
  final String? headline;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Sparkle.s4),
      child: Container(
        decoration: BoxDecoration(
          gradient: Sparkle.heroGradient,
          borderRadius: BorderRadius.circular(Sparkle.radius),
          boxShadow: Sparkle.heroShadow,
        ),
        clipBehavior: Clip.antiAlias,
        // A Stack with only a Positioned child (headline == null, the common
        // case) has no non-positioned child to size itself from and needs
        // bounded constraints from somewhere — this banner sits in a
        // ListView, which gives none. Fix the height instead.
        child: SizedBox(
          height: 96,
          child: Stack(
            children: [
              Positioned(
                right: -8,
                bottom: -8,
                child: SvgPicture.asset(imageAsset, width: 140, height: 105),
              ),
              if (headline != null)
                Padding(
                  padding: const EdgeInsets.all(Sparkle.s4),
                  child: Text(
                    headline!,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Sparkle.marine),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
