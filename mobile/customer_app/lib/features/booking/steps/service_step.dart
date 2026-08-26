import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme.dart';
import '../../../data/booking_repository.dart';
import '../booking_controller.dart';
import '../booking_flow_screen.dart' show dollars;
import '../widgets/hero_banner.dart';

class ServiceStep extends StatelessWidget {
  const ServiceStep({super.key, required this.c});
  final BookingController c;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(Sparkle.s4, Sparkle.s4, Sparkle.s4, Sparkle.s6),
      children: [
        const HeroBanner(imageAsset: 'assets/images/hero_tidy_home.svg'),
        Text('What kind of clean?', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Sparkle.s4),
        for (final service in ServiceOption.catalog)
          Padding(
            padding: const EdgeInsets.only(bottom: Sparkle.s3),
            child: _SelectCard(
              selected: c.draft.serviceCode == service.code,
              onTap: () => c.setService(service.code),
              title: service.name,
              eyebrow: service.pitch,
              body: service.detail,
              imageAsset: service.code == 'standard'
                  ? 'assets/images/icon_standard_clean.svg'
                  : 'assets/images/icon_deep_clean.svg',
            ),
          ),
        const SizedBox(height: Sparkle.s4),
        Text('Add anything?', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Sparkle.s1),
        const Text('Optional extras, priced individually.',
            style: TextStyle(color: Sparkle.inkSoft, fontSize: 13)),
        const SizedBox(height: Sparkle.s3),
        Wrap(
          spacing: Sparkle.s2,
          runSpacing: Sparkle.s2,
          children: [
            for (final addon in AddonOption.catalog)
              _AddonChip(
                label: '${addon.name}  ${dollars(addon.priceCents)}',
                selected: c.draft.addonCodes.contains(addon.code),
                onTap: () => c.toggleAddon(addon.code),
              ),
          ],
        ),
      ],
    );
  }
}

class _SelectCard extends StatelessWidget {
  const _SelectCard({
    required this.selected,
    required this.onTap,
    required this.title,
    required this.eyebrow,
    required this.body,
    this.imageAsset,
  });

  final bool selected;
  final VoidCallback onTap;
  final String title;
  final String eyebrow;
  final String body;
  final String? imageAsset;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Sparkle.radius),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.all(Sparkle.s4),
          decoration: BoxDecoration(
            color: selected ? Sparkle.seafoamSoft : Sparkle.surface,
            borderRadius: BorderRadius.circular(Sparkle.radius),
            border: Border.all(
              color: selected ? Sparkle.seafoam : Sparkle.hairline,
              width: selected ? 2 : 1,
            ),
            boxShadow: selected ? Sparkle.selectedShadow : Sparkle.cardShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (imageAsset != null) ...[
                    SvgPicture.asset(imageAsset!, width: 48, height: 48),
                    const SizedBox(width: Sparkle.s3),
                  ],
                  Expanded(
                    child: Text(eyebrow.toUpperCase(),
                        style: Theme.of(context).textTheme.labelSmall),
                  ),
                  if (selected) const Icon(Icons.check_circle, size: 20, color: Sparkle.seafoam),
                ],
              ),
              const SizedBox(height: Sparkle.s1),
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Sparkle.s2),
              Text(body, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddonChip extends StatelessWidget {
  const _AddonChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(30),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: Sparkle.s4, vertical: Sparkle.s3),
        decoration: BoxDecoration(
          color: selected ? Sparkle.marine : Sparkle.surface,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: selected ? Sparkle.marine : Sparkle.hairline),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: selected ? Colors.white : Sparkle.ink,
          ),
        ),
      ),
    );
  }
}
