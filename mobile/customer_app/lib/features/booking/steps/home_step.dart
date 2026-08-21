import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme.dart';
import '../booking_controller.dart';

class HomeStep extends StatelessWidget {
  const HomeStep({super.key, required this.c});
  final BookingController c;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(Sparkle.s4, Sparkle.s4, Sparkle.s4, Sparkle.s6),
      children: [
        Text('Tell us about your home', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Sparkle.s1),
        const Text('Room count sets the price and the time we book for your cleaner.',
            style: TextStyle(color: Sparkle.inkSoft, fontSize: 13)),
        const SizedBox(height: Sparkle.s5),
        _Stepper(
          label: 'Bedrooms',
          value: c.draft.bedrooms,
          min: 1,
          max: 8,
          onChanged: (v) => c.setRooms(bedrooms: v),
        ),
        const Divider(height: Sparkle.s6, color: Sparkle.hairline),
        _Stepper(
          label: 'Bathrooms',
          value: c.draft.bathrooms,
          min: 1,
          max: 6,
          onChanged: (v) => c.setRooms(bathrooms: v),
        ),
        const SizedBox(height: Sparkle.s6),
        Text('Square footage', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Sparkle.s1),
        const Text('Optional. A rough number is fine — it only adjusts larger homes.',
            style: TextStyle(color: Sparkle.inkSoft, fontSize: 13)),
        const SizedBox(height: Sparkle.s3),
        TextField(
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(5)],
          onChanged: (v) => c.setRooms(squareFeet: int.tryParse(v)),
          decoration: InputDecoration(
            hintText: 'e.g. 1600',
            suffixText: 'sq ft',
            filled: true,
            fillColor: Sparkle.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Sparkle.hairline),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Sparkle.hairline),
            ),
          ),
        ),
      ],
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: Theme.of(context).textTheme.titleMedium)),
        _Round(
          icon: Icons.remove,
          // Disabled rather than hidden: the control keeps its position, so
          // repeated taps never land on the wrong button.
          onTap: value > min ? () => onChanged(value - 1) : null,
          semanticLabel: 'Fewer $label',
        ),
        SizedBox(
          width: 56,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Archivo', fontSize: 22, fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        _Round(
          icon: Icons.add,
          onTap: value < max ? () => onChanged(value + 1) : null,
          semanticLabel: 'More $label',
        ),
      ],
    );
  }
}

class _Round extends StatelessWidget {
  const _Round({required this.icon, required this.onTap, required this.semanticLabel});
  final IconData icon;
  final VoidCallback? onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      label: semanticLabel,
      button: true,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          height: 44,
          width: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Sparkle.surface,
            border: Border.all(color: enabled ? Sparkle.marine : Sparkle.hairline),
          ),
          child: Icon(icon, size: 20, color: enabled ? Sparkle.marine : Sparkle.hairline),
        ),
      ),
    );
  }
}
