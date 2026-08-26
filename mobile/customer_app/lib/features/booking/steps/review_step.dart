import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';

import '../../../core/theme.dart';
import '../../../data/booking_repository.dart';
import '../booking_controller.dart';
import '../booking_flow_screen.dart' show dollars;

/// Review and confirm.
///
/// Two things get said plainly here because they're the two things customers
/// get burned on elsewhere: the quote has a shelf life, and the card is held
/// rather than charged. Both are stated in the flow, not in a footnote.
class ReviewStep extends StatefulWidget {
  const ReviewStep({super.key, required this.c});
  final BookingController c;

  @override
  State<ReviewStep> createState() => _ReviewStepState();
}

class _ReviewStepState extends State<ReviewStep> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Drives the freshness countdown; also re-prices automatically the moment
    // the quote lapses, so the customer never taps Confirm on a dead price.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final quote = widget.c.quote;
      if (quote != null && quote.isStale && widget.c.quoteState != QuoteState.loading) {
        widget.c.refreshQuote();
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final quote = c.quote;
    final service = ServiceOption.catalog.firstWhere((s) => s.code == c.draft.serviceCode);

    return ListView(
      padding: const EdgeInsets.fromLTRB(Sparkle.s4, Sparkle.s4, Sparkle.s4, Sparkle.s6),
      children: [
        Text('Almost done', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Sparkle.s4),
        _Card(children: [
          _Row(
            label: 'Service',
            value: service.name,
            onEdit: () => _jump(BookingStep.service),
          ),
          _Row(
            label: 'Home',
            value: '${c.draft.bedrooms} bed · ${c.draft.bathrooms} bath'
                '${c.draft.squareFeet != null ? ' · ${c.draft.squareFeet} sq ft' : ''}',
            onEdit: () => _jump(BookingStep.home),
          ),
          _Row(
            label: 'When',
            value: c.draft.scheduledAt == null
                ? '—'
                : DateFormat('EEE d MMM · h:mm a').format(c.draft.scheduledAt!),
            onEdit: () => _jump(BookingStep.schedule),
          ),
          if (quote != null)
            _Row(label: 'Expected time on site', value: _hours(quote.durationMin)),
          if (c.draft.addonCodes.isNotEmpty)
            _Row(
              label: 'Extras',
              value: c.draft.addonCodes
                  .map((code) => AddonOption.catalog.firstWhere((a) => a.code == code).name)
                  .join(', '),
              onEdit: () => _jump(BookingStep.service),
            ),
        ]),
        const SizedBox(height: Sparkle.s4),
        Text('Anything your cleaner should know?',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Sparkle.s2),
        TextField(
          maxLines: 3,
          maxLength: 500,
          onChanged: c.setInstructions,
          decoration: InputDecoration(
            hintText: 'Gate code, where supplies live, a room to skip, a nervous cat…',
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
        const SizedBox(height: Sparkle.s2),
        _Reassurance(
          leading: SvgPicture.asset('assets/images/icon_card_hold.svg', width: 18, height: 18),
          title: 'Held now, charged after',
          body: quote == null
              ? 'We place a hold on your card and only charge once the clean is finished.'
              : 'We hold ${dollars(quote.totalCents)} on your card now and charge it once the clean is finished. '
                  'Cancel more than 12 hours ahead and the hold is released in full.',
        ),
        const _Reassurance(
          leading: _ShieldCheckIcon(),
          title: 'Every cleaner is background checked',
          body: 'Identity and criminal record checks are re-run yearly. Your address is only shared once a cleaner accepts.',
        ),
        if (quote != null) _Freshness(quote: quote, reloading: c.quoteState == QuoteState.loading),
        if (c.quoteError != null)
          Padding(
            padding: const EdgeInsets.only(top: Sparkle.s3),
            child: Text(c.quoteError!, style: const TextStyle(color: Sparkle.clay, fontSize: 13)),
          ),
      ],
    );
  }

  void _jump(BookingStep target) {
    while (widget.c.step != target && widget.c.canGoBack) {
      widget.c.back();
    }
  }

  String _hours(int minutes) {
    final h = minutes ~/ 60, m = minutes % 60;
    if (h == 0) return '$m minutes';
    return m == 0 ? '$h hours' : '${h}h ${m}m';
  }
}

class _Freshness extends StatelessWidget {
  const _Freshness({required this.quote, required this.reloading});
  final Quote quote;
  final bool reloading;

  @override
  Widget build(BuildContext context) {
    final left = quote.timeLeft;
    final text = reloading
        ? 'Refreshing your price…'
        : left.isNegative
            ? 'Price expired — refreshing.'
            : 'This price holds for ${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}.';

    return Padding(
      padding: const EdgeInsets.only(top: Sparkle.s4),
      child: Row(
        children: [
          const Icon(Icons.schedule, size: 14, color: Sparkle.inkSoft),
          const SizedBox(width: Sparkle.s2),
          Text(text, style: const TextStyle(fontSize: 12, color: Sparkle.inkSoft)),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sparkle.s4, vertical: Sparkle.s2),
      decoration: BoxDecoration(
        color: Sparkle.surface,
        borderRadius: BorderRadius.circular(Sparkle.radius),
        border: Border.all(color: Sparkle.hairline),
        boxShadow: Sparkle.cardShadow,
      ),
      child: Column(children: children),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.onEdit});
  final String label;
  final String value;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sparkle.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: const TextStyle(fontSize: 13, color: Sparkle.inkSoft)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 15, color: Sparkle.inkStrong)),
          ),
          if (onEdit != null)
            TextButton(
              onPressed: onEdit,
              style: TextButton.styleFrom(
                foregroundColor: Sparkle.seafoam,
                minimumSize: const Size(44, 44),
                padding: EdgeInsets.zero,
              ),
              child: const Text('Change'),
            ),
        ],
      ),
    );
  }
}

class _Reassurance extends StatelessWidget {
  const _Reassurance({required this.leading, required this.title, required this.body});
  final Widget leading;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Sparkle.s4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          leading,
          const SizedBox(width: Sparkle.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(body, style: const TextStyle(fontSize: 13, color: Sparkle.inkSoft, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ShieldCheckIcon extends StatelessWidget {
  const _ShieldCheckIcon();

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset('assets/images/icon_shield_check.svg', width: 18, height: 18);
  }
}
