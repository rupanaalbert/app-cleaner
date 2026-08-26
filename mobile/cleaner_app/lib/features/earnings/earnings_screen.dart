import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/earnings_repository.dart';

enum _Period { week, month, all }

/// Earnings — the number a cleaner opens the app to check on payday.
///
/// Take-home (their share plus tips, in full) leads, in amber, because it's the
/// figure that decides whether the work is worth it. Gross and commission are
/// there for trust, not pride of place. The next payout — amount and arrival —
/// sits right under it, since "when do I get paid" is the actual question.
class EarningsScreen extends StatefulWidget {
  const EarningsScreen({super.key, required this.repository});

  final EarningsRepository repository;

  @override
  State<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends State<EarningsScreen> {
  final _money = NumberFormat.currency(symbol: r'$', decimalDigits: 2);
  final _date = DateFormat('EEE d MMM');

  _Period _period = _Period.week;
  Earnings? _earnings;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  (DateTime?, DateTime?) get _window {
    final now = DateTime.now();
    switch (_period) {
      case _Period.week:
        final monday = DateTime(now.year, now.month, now.day).subtract(Duration(days: now.weekday - 1));
        return (monday, now);
      case _Period.month:
        return (DateTime(now.year, now.month), now);
      case _Period.all:
        return (null, null);
    }
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final (from, to) = _window;
      final earnings = await widget.repository.fetch(from: from, to: to);
      if (!mounted) return;
      setState(() {
        _earnings = earnings;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiFailure ? e.message : 'Could not load earnings. Pull down to retry.';
      });
    }
  }

  void _setPeriod(_Period period) {
    if (period == _period) return;
    setState(() {
      _period = period;
      _loading = true;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Sparkle.marine,
        foregroundColor: Colors.white,
        title: const Text('Earnings',
            style: TextStyle(fontFamily: 'Archivo', fontWeight: FontWeight.w600)),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: Sparkle.marine,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(Sparkle.s4, Sparkle.s4, Sparkle.s4, Sparkle.s6),
          children: [
            _periodPicker(),
            const SizedBox(height: Sparkle.s4),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: Sparkle.s6),
                child: Center(child: CircularProgressIndicator(color: Sparkle.marine)),
              )
            else if (_error != null)
              _ErrorState(message: _error!, onRetry: _load)
            else
              _summary(_earnings!),
          ],
        ),
      ),
    );
  }

  Widget _periodPicker() {
    Widget seg(_Period value, String label) {
      final active = _period == value;
      return Expanded(
        child: GestureDetector(
          onTap: () => _setPeriod(value),
          child: Container(
            margin: const EdgeInsets.all(3),
            padding: const EdgeInsets.symmetric(vertical: Sparkle.s2),
            decoration: BoxDecoration(
              color: active ? Sparkle.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              boxShadow: active
                  ? const [BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 2))]
                  : null,
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: active ? Sparkle.marine : Sparkle.inkSoft,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(color: Sparkle.hairline.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(13)),
      child: Row(children: [
        seg(_Period.week, 'This week'),
        seg(_Period.month, 'This month'),
        seg(_Period.all, 'All time'),
      ]),
    );
  }

  Widget _summary(Earnings e) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Sparkle.radius),
          child: Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Sparkle.marine,
                  borderRadius: BorderRadius.circular(Sparkle.radius),
                ),
                padding: const EdgeInsets.all(Sparkle.s5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('TAKE-HOME',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: const Color(0xFFA9C6CD))),
                    const SizedBox(height: Sparkle.s1),
                    Text(
                      _money.format(e.takeHomeCents / 100),
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(color: Sparkle.payout, fontSize: 40),
                    ),
                    const SizedBox(height: Sparkle.s1),
                    Text('${e.jobs} ${e.jobs == 1 ? 'job' : 'jobs'} · your share plus tips',
                        style: const TextStyle(color: Color(0xFFA9C6CD), fontSize: 13)),
                  ],
                ),
              ),
              Positioned(
                right: -12,
                bottom: -12,
                child: Opacity(
                  opacity: 0.18,
                  child: SvgPicture.asset('assets/images/hero_payout.svg', width: 120, height: 84),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Sparkle.s3),
        _Card(
          child: Column(
            children: [
              _Row(label: 'Your share', value: _money.format(e.netCents / 100)),
              const _Divider(),
              _Row(label: 'Tips', value: _money.format(e.tipsCents / 100)),
              const _Divider(),
              _Row(label: 'Booked (gross)', value: _money.format(e.grossCents / 100), muted: true),
              const _Divider(),
              _Row(label: 'Platform fee', value: '−${_money.format(e.commissionCents / 100)}', muted: true),
            ],
          ),
        ),
        const SizedBox(height: Sparkle.s3),
        _nextPayout(e),
      ],
    );
  }

  Widget _nextPayout(Earnings e) {
    final cents = e.nextPayoutCents ?? 0;
    return _Card(
      child: Row(
        children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: Sparkle.payout.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.account_balance_outlined, color: Sparkle.payout, size: 20),
          ),
          const SizedBox(width: Sparkle.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Label('Next payout'),
                const SizedBox(height: 2),
                Text(
                  cents == 0
                      ? 'No payout pending'
                      : e.nextPayoutArrival == null
                          ? 'On its way'
                          : 'Arrives ${_date.format(e.nextPayoutArrival!.toLocal())}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          Text(_money.format(cents / 100),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Sparkle.payout)),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.muted = false});
  final String label;
  final String value;
  final bool muted;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Sparkle.s3),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 14, color: muted ? Sparkle.inkSoft : Sparkle.inkStrong)),
            ),
            Text(value,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: muted ? Sparkle.inkSoft : Sparkle.inkStrong,
                  fontFeatures: const [FontFeature.tabularFigures()],
                )),
          ],
        ),
      );
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) => const Divider(height: 1, color: Sparkle.hairline);
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Sparkle.surface,
          borderRadius: BorderRadius.circular(Sparkle.radius),
          border: Border.all(color: Sparkle.hairline),
          boxShadow: Sparkle.cardShadow,
        ),
        padding: const EdgeInsets.symmetric(horizontal: Sparkle.s4, vertical: Sparkle.s1),
        child: child,
      );
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelSmall);
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Sparkle.s6),
        child: Column(
          children: [
            const Icon(Icons.cloud_off_outlined, size: 44, color: Sparkle.inkSoft),
            const SizedBox(height: Sparkle.s4),
            Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: Sparkle.s4),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      );
}
