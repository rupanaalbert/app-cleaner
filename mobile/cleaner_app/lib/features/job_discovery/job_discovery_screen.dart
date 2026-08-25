import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/offers_repository.dart';

/// Job Discovery — the cleaner's home screen.
///
/// The screen has exactly one job: let someone decide, in about three seconds,
/// whether to take a job. So every card leads with the payout, and the offer's
/// 90-second window is drawn as a ring that drains around it. Urgency is the
/// real content here; a countdown in small grey text would bury it.
///
/// One ticker drives every card. Twenty AnimatedBuilders each with their own
/// Timer is how you cook a phone that lives in a car mount all day.
class JobDiscoveryScreen extends StatefulWidget {
  const JobDiscoveryScreen({
    super.key,
    required this.repository,
    this.onOfferAccepted,
  });

  final OffersRepository repository;
  final void Function(JobOffer offer)? onOfferAccepted;

  @override
  State<JobDiscoveryScreen> createState() => _JobDiscoveryScreenState();
}

class _JobDiscoveryScreenState extends State<JobDiscoveryScreen> {
  final _money = NumberFormat.currency(symbol: r'$', decimalDigits: 2);
  final _time = DateFormat('EEE d MMM · h:mm a');

  List<JobOffer> _offers = const [];
  bool _loading = true;
  bool _online = true;
  String? _error;
  String? _accepting;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _load();
    // Drives every expiry ring, and drops offers the moment they lapse.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final live = _offers.where((o) => !o.isExpired).toList();
      setState(() => _offers = live);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final offers = await widget.repository.fetchOpenOffers();
      if (!mounted) return;
      setState(() {
        _offers = offers;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiFailure ? e.message : 'Could not load jobs. Pull down to retry.';
      });
    }
  }

  Future<void> _accept(JobOffer offer) async {
    setState(() => _accepting = offer.offerId);
    try {
      await widget.repository.accept(offer.offerId);
      if (!mounted) return;
      setState(() {
        _offers = _offers.where((o) => o.offerId != offer.offerId).toList();
        _accepting = null;
      });
      widget.onOfferAccepted?.call(offer);
      _say('Job accepted. The address is in your schedule.', tone: Sparkle.seafoam);
    } on OfferTaken {
      _drop(offer, 'Another cleaner took this one.');
    } on OfferExpired {
      _drop(offer, 'That offer expired.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _accepting = null);
      _say('$e', tone: Sparkle.clay);
    }
  }

  Future<void> _decline(JobOffer offer) async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Sparkle.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Sparkle.radius)),
      ),
      builder: (context) => const _DeclineSheet(),
    );
    if (reason == null) return;
    await widget.repository.decline(offer.offerId, reason);
    if (!mounted) return;
    setState(() => _offers = _offers.where((o) => o.offerId != offer.offerId).toList());
  }

  void _drop(JobOffer offer, String message) {
    if (!mounted) return;
    setState(() {
      _offers = _offers.where((o) => o.offerId != offer.offerId).toList();
      _accepting = null;
    });
    _say(message);
  }

  void _say(String message, {Color tone = Sparkle.marineDeep}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: tone,
        behavior: SnackBarBehavior.floating,
      ));
  }

  Future<void> _toggleOnline(bool value) async {
    setState(() => _online = value);
    await widget.repository.setAvailability(value);
    if (value) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        color: Sparkle.marine,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            _header(),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator(color: Sparkle.marine)),
              )
            else if (_error != null)
              SliverFillRemaining(hasScrollBody: false, child: _ErrorState(message: _error!, onRetry: _load))
            else if (_offers.isEmpty)
              SliverFillRemaining(hasScrollBody: false, child: _EmptyState(online: _online))
            else
              SliverList.separated(
                itemCount: _offers.length,
                separatorBuilder: (_, __) => const SizedBox(height: Sparkle.s3),
                itemBuilder: (context, i) {
                  final offer = _offers[i];
                  return Padding(
                    padding: EdgeInsets.fromLTRB(
                      Sparkle.s4, i == 0 ? Sparkle.s4 : 0, Sparkle.s4,
                      i == _offers.length - 1 ? Sparkle.s6 : 0,
                    ),
                    child: _OfferCard(
                      offer: offer,
                      money: _money,
                      time: _time,
                      busy: _accepting == offer.offerId,
                      onAccept: () => _accept(offer),
                      onDecline: () => _decline(offer),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return SliverAppBar(
      pinned: true,
      expandedHeight: 132,
      backgroundColor: Sparkle.marine,
      foregroundColor: Colors.white,
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsets.fromLTRB(Sparkle.s4, 0, Sparkle.s4, Sparkle.s3),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _offers.isEmpty ? 'Jobs near you' : '${_offers.length} jobs near you',
              style: const TextStyle(fontFamily: 'Archivo', fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        background: Padding(
          padding: const EdgeInsets.fromLTRB(Sparkle.s4, 56, Sparkle.s4, 44),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_online ? 'Accepting jobs' : 'Not accepting jobs',
                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    _online ? 'We\'ll notify you when work comes in' : 'Turn on to start receiving offers',
                    style: const TextStyle(color: Color(0xFFA9C6CD), fontSize: 13),
                  ),
                ],
              ),
              Switch(
                value: _online,
                onChanged: _toggleOnline,
                activeThumbColor: Colors.white,
                activeTrackColor: Sparkle.seafoam,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfferCard extends StatelessWidget {
  const _OfferCard({
    required this.offer,
    required this.money,
    required this.time,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
  });

  final JobOffer offer;
  final NumberFormat money;
  final DateFormat time;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final seconds = math.max(0, offer.remaining.inSeconds);
    final urgent = seconds <= 20;

    return Container(
      decoration: BoxDecoration(
        color: Sparkle.surface,
        borderRadius: BorderRadius.circular(Sparkle.radius),
        border: Border.all(color: urgent ? Sparkle.clay : Sparkle.hairline, width: urgent ? 1.5 : 1),
        boxShadow: const [
          BoxShadow(color: Color(0x0F0E3A45), blurRadius: 18, offset: Offset(0, 6)),
        ],
      ),
      padding: const EdgeInsets.all(Sparkle.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Signature element: the payout sits inside a ring that drains
              // as the offer window closes. One glance gives both the reward
              // and the time left to claim it.
              _ExpiryRing(
                secondsLeft: seconds,
                totalSeconds: 90,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      money.format(offer.payoutCents / 100),
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(color: Sparkle.payout),
                    ),
                    Text('${money.format(offer.hourlyCents / 100)}/hr',
                        style: const TextStyle(fontSize: 12, color: Sparkle.inkSoft)),
                  ],
                ),
              ),
              const SizedBox(width: Sparkle.s4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (offer.isDeepClean) const _Chip(label: 'DEEP CLEAN', tone: Sparkle.marine),
                        if (offer.hasPets) ...[
                          const SizedBox(width: Sparkle.s1),
                          const _Chip(label: 'PETS', tone: Sparkle.inkSoft),
                        ],
                      ],
                    ),
                    const SizedBox(height: Sparkle.s2),
                    Text(time.format(offer.scheduledAt),
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      '${offer.bedrooms} bed · ${offer.bathrooms} bath'
                      '${offer.squareFeet != null ? ' · ${offer.squareFeet} sq ft' : ''}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${offer.distanceKm.toStringAsFixed(1)} km · ${offer.neighborhood}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Sparkle.s3),
          Row(
            children: [
              Text('${_hours(offer.durationMin)} on site',
                  style: Theme.of(context).textTheme.labelSmall),
              const Spacer(),
              Text(
                urgent ? 'Closing in ${seconds}s' : 'Open for ${seconds}s',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: urgent ? Sparkle.clay : Sparkle.inkSoft,
                ),
              ),
            ],
          ),
          const SizedBox(height: Sparkle.s3),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: OutlinedButton(
                  onPressed: busy ? null : onDecline,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    side: const BorderSide(color: Sparkle.hairline),
                    foregroundColor: Sparkle.ink,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: const Text('Pass'),
                ),
              ),
              const SizedBox(width: Sparkle.s3),
              Expanded(
                flex: 3,
                child: FilledButton(
                  onPressed: busy ? null : onAccept,
                  child: busy
                      ? const SizedBox(
                          height: 20, width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Accept job'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _hours(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }
}

/// Draining ring around the payout. Turns clay under 20 seconds — the only
/// place in the card where color changes state, so it can't be missed.
class _ExpiryRing extends StatelessWidget {
  const _ExpiryRing({
    required this.secondsLeft,
    required this.totalSeconds,
    required this.child,
  });

  final int secondsLeft;
  final int totalSeconds;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final progress = (secondsLeft / totalSeconds).clamp(0.0, 1.0);
    return Semantics(
      label: '$secondsLeft seconds left to accept',
      child: SizedBox(
        width: 108,
        height: 108,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox.expand(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: progress, end: progress),
                duration: const Duration(milliseconds: 900),
                builder: (context, value, _) => CircularProgressIndicator(
                  value: value,
                  strokeWidth: 5,
                  strokeCap: StrokeCap.round,
                  backgroundColor: Sparkle.hairline,
                  valueColor: AlwaysStoppedAnimation(
                    secondsLeft <= 20 ? Sparkle.clay : Sparkle.seafoam,
                  ),
                ),
              ),
            ),
            Padding(padding: const EdgeInsets.all(Sparkle.s3), child: child),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.tone});
  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sparkle.s2, vertical: 3),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: tone)),
    );
  }
}

class _DeclineSheet extends StatelessWidget {
  const _DeclineSheet();

  static const _reasons = {
    'too_far': 'Too far away',
    'bad_timing': 'Doesn\'t fit my schedule',
    'low_pay': 'Pay is too low',
    'other': 'Another reason',
  };

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Sparkle.s4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Why are you passing?', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Sparkle.s1),
            const Text(
              'This tunes which jobs we send you. Passing never affects your rating.',
              style: TextStyle(color: Sparkle.inkSoft, fontSize: 13),
            ),
            const SizedBox(height: Sparkle.s3),
            for (final entry in _reasons.entries)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(entry.value),
                trailing: const Icon(Icons.chevron_right, color: Sparkle.inkSoft),
                onTap: () => Navigator.pop(context, entry.key),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.online});
  final bool online;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Sparkle.s6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(online ? Icons.notifications_active_outlined : Icons.toggle_off_outlined,
              size: 44, color: Sparkle.inkSoft),
          const SizedBox(height: Sparkle.s4),
          Text(online ? 'No open jobs right now' : 'You\'re not accepting jobs',
              style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: Sparkle.s2),
          Text(
            online
                ? 'Keep the app open — new jobs arrive as a notification, and weekend mornings are busiest.'
                : 'Turn on Accepting jobs at the top to start receiving offers.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Sparkle.s6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
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
}
