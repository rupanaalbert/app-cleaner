import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/booking_repository.dart';
import 'booking_controller.dart';
import 'paypal_approval_screen.dart';
import 'steps/home_step.dart';
import 'steps/review_step.dart';
import 'steps/schedule_step.dart';
import 'steps/service_step.dart';

final money = NumberFormat.currency(symbol: r'$', decimalDigits: 2);
String dollars(int cents) => money.format(cents / 100);

/// The booking flow: service → home → schedule → review.
///
/// The signature element is the price ledger pinned to the bottom. Most
/// on-demand apps reveal the real total on the last screen, after the customer
/// is invested. Here the total is present from the first tap and every choice
/// visibly moves it — including the weekend surcharge, which announces itself
/// rather than hiding inside a bigger number.
class BookingFlowScreen extends StatefulWidget {
  const BookingFlowScreen({
    super.key,
    required this.repository,
    required this.propertyId,
    required this.addressLine,
  });

  final BookingRepository repository;
  final String propertyId;
  final String addressLine;

  @override
  State<BookingFlowScreen> createState() => _BookingFlowScreenState();
}

class _BookingFlowScreenState extends State<BookingFlowScreen> {
  late final BookingController c = BookingController(
    repository: widget.repository,
    propertyId: widget.propertyId,
  );

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final PaypalOrder order;
    try {
      order = await c.createPaypalOrder();
    } catch (e) {
      if (!mounted) return;
      _showSubmitError('$e');
      return;
    }
    if (!mounted) return;

    // The fake repository has no real PayPal to redirect through — it signals
    // an already-approved order instead of a real approve link so the demo
    // flow completes the same way it always has.
    var approved = order.approveUrl == kDemoApprovedPaypalUrl;
    if (!approved) {
      final result = await Navigator.of(context).push<PaypalApprovalResult>(
        MaterialPageRoute(builder: (_) => PaypalApprovalScreen(approveUrl: order.approveUrl)),
      );
      approved = result?.approved ?? false;
    }
    if (!approved || !mounted) return;

    await c.submit(order.orderId);
    if (!mounted) return;
    if (c.confirmed != null) {
      await showModalBottomSheet<void>(
        context: context,
        isDismissible: false,
        backgroundColor: Sparkle.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Sparkle.radius)),
        ),
        builder: (_) => _ConfirmedSheet(booking: c.confirmed!),
      );
    } else if (c.submitError != null) {
      _showSubmitError(c.submitError!);
    }
  }

  void _showSubmitError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: Sparkle.clay,
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            leading: c.canGoBack
                ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: c.back)
                : IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.maybePop(context),
                  ),
            title: Text(widget.addressLine,
                style: const TextStyle(fontSize: 14, color: Sparkle.inkSoft)),
            centerTitle: true,
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(3),
              child: _StepBar(index: c.stepIndex, total: BookingStep.values.length),
            ),
          ),
          body: SafeArea(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: switch (c.step) {
                BookingStep.service => ServiceStep(key: const ValueKey('service'), c: c),
                BookingStep.home => HomeStep(key: const ValueKey('home'), c: c),
                BookingStep.schedule => ScheduleStep(key: const ValueKey('schedule'), c: c),
                BookingStep.review => ReviewStep(key: const ValueKey('review'), c: c),
              },
            ),
          ),
          bottomNavigationBar: PriceLedger(
            c: c,
            onPrimary: c.step == BookingStep.review ? _confirm : c.next,
          ),
        );
      },
    );
  }
}

class _StepBar extends StatelessWidget {
  const _StepBar({required this.index, required this.total});
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(total, (i) {
        return Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            height: 3,
            margin: EdgeInsets.only(right: i == total - 1 ? 0 : 2),
            color: i <= index ? Sparkle.seafoam : Sparkle.hairline,
          ),
        );
      }),
    );
  }
}

/// Pinned price summary. Expands into the full line-item ledger on tap — the
/// breakdown is one gesture away at every step, not buried in a receipt.
class PriceLedger extends StatefulWidget {
  const PriceLedger({super.key, required this.c, required this.onPrimary});
  final BookingController c;
  final VoidCallback onPrimary;

  @override
  State<PriceLedger> createState() => _PriceLedgerState();
}

class _PriceLedgerState extends State<PriceLedger> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final quote = c.quote;
    final loading = c.quoteState == QuoteState.loading;

    return Container(
      decoration: const BoxDecoration(
        color: Sparkle.surface,
        border: Border(top: BorderSide(color: Sparkle.hairline)),
        boxShadow: Sparkle.stickyBarShadow,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Sparkle.s4, Sparkle.s3, Sparkle.s4, Sparkle.s3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_expanded && quote != null) ...[
                for (final line in quote.lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Sparkle.s2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(line.label,
                              style: TextStyle(
                                fontSize: 14,
                                color: line.isFee ? Sparkle.inkSoft : Sparkle.ink,
                              )),
                        ),
                        Text(dollars(line.cents),
                            style: const TextStyle(fontSize: 14, color: Sparkle.ink)),
                      ],
                    ),
                  ),
                if (quote.multipliers.contains('weekend'))
                  const _Note('Weekend rate applied — 15% above weekday pricing.'),
                if (quote.multipliers.contains('evening'))
                  const _Note('Evening rate applied — 10% above daytime pricing.'),
                const Divider(color: Sparkle.hairline, height: Sparkle.s5),
              ],
              InkWell(
                onTap: quote == null ? null : () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: Sparkle.s3),
                  child: Row(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Text(
                                quote == null ? 'Estimate' : 'Total',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                              if (quote != null) ...[
                                const SizedBox(width: Sparkle.s1),
                                Icon(_expanded ? Icons.expand_more : Icons.expand_less,
                                    size: 16, color: Sparkle.inkSoft),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: Text(
                              quote == null
                                  ? (c.draft.hasSchedule ? '—' : 'Pick a time')
                                  : dollars(quote.totalCents),
                              key: ValueKey(quote?.totalCents ?? -1),
                              style: Theme.of(context).textTheme.displaySmall,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      if (loading)
                        const Padding(
                          padding: EdgeInsets.only(right: Sparkle.s3),
                          child: SizedBox(
                            height: 16, width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Sparkle.inkSoft),
                          ),
                        )
                      else if (quote != null)
                        Text('${_hours(quote.durationMin)} · all in',
                            style: const TextStyle(fontSize: 13, color: Sparkle.inkSoft)),
                    ],
                  ),
                ),
              ),
              FilledButton(
                onPressed: c.canAdvance ? widget.onPrimary : null,
                child: c.submitting
                    ? const SizedBox(
                        height: 20, width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(switch (c.step) {
                        BookingStep.review => 'Confirm and book',
                        BookingStep.schedule => 'Review booking',
                        _ => 'Continue',
                      }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _hours(int minutes) {
    final h = minutes ~/ 60, m = minutes % 60;
    if (h == 0) return '${m}m';
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Sparkle.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 14, color: Sparkle.inkSoft),
          const SizedBox(width: Sparkle.s2),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 12, color: Sparkle.inkSoft)),
          ),
        ],
      ),
    );
  }
}

class _ConfirmedSheet extends StatelessWidget {
  const _ConfirmedSheet({required this.booking});
  final ConfirmedBooking booking;

  @override
  Widget build(BuildContext context) {
    final when = DateFormat('EEEE d MMMM · h:mm a').format(booking.scheduledAt);
    return Padding(
      padding: const EdgeInsets.all(Sparkle.s5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 420),
            curve: Curves.elasticOut,
            builder: (context, value, child) => Transform.scale(scale: value, child: child),
            child: SvgPicture.asset('assets/images/sparkle_motif.svg', width: 64, height: 64),
          ),
          const SizedBox(height: Sparkle.s3),
          Text('Booked for $when', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Sparkle.s2),
          Text(
            'We\'re finding your cleaner now — usually within a few minutes. '
            'Your card is on hold for ${dollars(booking.totalCents)} and is only charged once the clean is done.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: Sparkle.s3),
          Text('Reference ${booking.reference}',
              style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: Sparkle.s5),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('View booking'),
          ),
        ],
      ),
    );
  }
}
