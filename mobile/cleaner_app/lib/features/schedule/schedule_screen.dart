import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../core/widgets/sparkle_card.dart';
import '../../data/jobs_repository.dart';

/// Today's schedule — the cleaner's assigned and live jobs, soonest first.
///
/// A live job (en route / arrived / cleaning) is pinned to the top and drawn in
/// seafoam: on a shift, the job you're doing right now is the only one that
/// matters, and it should be the first thing your thumb finds. Everything else
/// is grouped into Today and Later so a full week doesn't read as one wall.
class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key, required this.repository, required this.onOpenJob});

  final JobsRepository repository;
  final Future<void> Function(ScheduledJob job) onOpenJob;

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  final _money = NumberFormat.currency(symbol: r'$', decimalDigits: 2);
  final _time = DateFormat('EEE d MMM · h:mm a');

  List<ScheduledJob> _jobs = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final jobs = await widget.repository.schedule();
      if (!mounted) return;
      setState(() {
        _jobs = jobs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiFailure ? e.message : 'Could not load your schedule. Pull down to retry.';
      });
    }
  }

  Future<void> _open(ScheduledJob job) async {
    await widget.onOpenJob(job);
    // A job may have advanced or finished while it was open — reflect it.
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final active = _jobs.where((j) => j.isActive).toList();
    final today = _jobs.where((j) => !j.isActive && j.isToday).toList();
    final later = _jobs.where((j) => !j.isActive && !j.isToday).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Schedule')),
      body: RefreshIndicator(
        onRefresh: _load,
        color: Sparkle.marine,
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: Sparkle.marine))
            : _error != null
                ? _ScrollableCenter(child: _ErrorState(message: _error!, onRetry: _load))
                : _jobs.isEmpty
                    ? const _ScrollableCenter(child: _EmptyState())
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(Sparkle.s4, Sparkle.s4, Sparkle.s4, Sparkle.s6),
                        children: [
                          if (active.isNotEmpty) ...[
                            const _SectionHeader('Active now'),
                            for (final job in active)
                              _JobTile(job: job, money: _money, time: _time, onTap: () => _open(job)),
                            const SizedBox(height: Sparkle.s5),
                          ],
                          if (today.isNotEmpty) ...[
                            const _SectionHeader('Today'),
                            for (final job in today)
                              _JobTile(job: job, money: _money, time: _time, onTap: () => _open(job)),
                            const SizedBox(height: Sparkle.s5),
                          ],
                          if (later.isNotEmpty) ...[
                            const _SectionHeader('Later'),
                            for (final job in later)
                              _JobTile(job: job, money: _money, time: _time, onTap: () => _open(job)),
                          ],
                        ],
                      ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Sparkle.s2),
        child: Text(label.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
      );
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.job, required this.money, required this.time, required this.onTap});

  final ScheduledJob job;
  final NumberFormat money;
  final DateFormat time;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (label, tone) = _statusChip(job.status);
    return Padding(
      padding: const EdgeInsets.only(bottom: Sparkle.s3),
      child: SparkleCard(
        onTap: onTap,
        borderColor: job.isActive ? Sparkle.seafoam : Sparkle.hairline,
        borderWidth: job.isActive ? 1.5 : 1,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _Pill(label: label, tone: tone),
                      if (job.isDeepClean) ...[
                        const SizedBox(width: Sparkle.s1),
                        const _Pill(label: 'DEEP', tone: Sparkle.marine),
                      ],
                    ],
                  ),
                  const SizedBox(height: Sparkle.s2),
                  Text(time.format(job.scheduledAt), style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text('${job.serviceName} · ${_hours(job.durationMin)} on site',
                      style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
            const SizedBox(width: Sparkle.s3),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(money.format(job.payoutCents / 100),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Sparkle.payout)),
                const SizedBox(height: Sparkle.s2),
                const Icon(Icons.chevron_right, color: Sparkle.inkSoft),
              ],
            ),
          ],
        ),
      ),
    );
  }

  (String, Color) _statusChip(String status) => switch (status) {
        'assigned' => ('SCHEDULED', Sparkle.inkSoft),
        'en_route' => ('ON THE WAY', Sparkle.seafoam),
        'arrived' => ('ARRIVED', Sparkle.seafoam),
        'in_progress' => ('CLEANING', Sparkle.seafoam),
        _ => (status.toUpperCase(), Sparkle.inkSoft),
      };

  String _hours(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.tone});
  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Sparkle.s2, vertical: 3),
        decoration: BoxDecoration(color: tone.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(6)),
        child: Text(label,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: tone)),
      );
}

class _ScrollableCenter extends StatelessWidget {
  const _ScrollableCenter({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: child),
          ),
        ),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(Sparkle.s6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset('assets/images/illustration_empty_calm.svg', width: 96, height: 96),
            const SizedBox(height: Sparkle.s4),
            Text('Nothing on your schedule', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Sparkle.s2),
            Text('Jobs you accept from Discover show up here with the address and directions.',
                textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
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
