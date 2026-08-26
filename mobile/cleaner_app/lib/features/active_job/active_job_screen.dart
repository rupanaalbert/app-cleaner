import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/chat_repository.dart';
import '../../data/geolocation.dart';
import '../../data/jobs_repository.dart';
import '../../data/location_publisher.dart';
import '../chat/chat_screen.dart';

/// The one job the cleaner is doing right now.
///
/// A shift is a state machine walked one tap at a time: on my way → arrived →
/// start → finish. The screen shows exactly where they are and offers exactly
/// the next move, thumb-sized at the bottom. `arrived` and `completed` are
/// geofenced server-side, so those taps carry a fresh GPS fix; a Deep Clean
/// can't be finished until the after-photos exist. Every refusal comes back as
/// plain language, never a dead button.
class ActiveJobScreen extends StatefulWidget {
  const ActiveJobScreen({
    super.key,
    required this.repository,
    required this.locator,
    required this.bookingId,
    this.tracker,
    this.chat,
  });

  final JobsRepository repository;
  final Locator locator;
  final String bookingId;

  /// Streams the cleaner's position to the customer while en route. Optional so
  /// the screen runs under a fake with no Firebase.
  final LocationPublisher? tracker;

  /// Booking thread. Optional so the screen runs under a fake with no Firebase;
  /// when present, a message button appears in the app bar.
  final ChatRepository? chat;

  @override
  State<ActiveJobScreen> createState() => _ActiveJobScreenState();
}

class _ActiveJobScreenState extends State<ActiveJobScreen> {
  static const _requiredAfterPhotos = 3;

  final _money = NumberFormat.currency(symbol: r'$', decimalDigits: 2);
  final _time = DateFormat('EEE d MMM · h:mm a');

  JobDetail? _job;
  bool _loading = true;
  String? _error;
  bool _busy = false;
  bool _uploadingPhoto = false;
  int _afterPhotos = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final job = await widget.repository.job(widget.bookingId);
      if (!mounted) return;
      setState(() {
        _job = job;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiFailure ? e.message : 'Could not load the job. Pull down to retry.';
      });
    }
  }

  _Step? get _next {
    switch (_job?.status) {
      case 'assigned':
        return const _Step('en_route', 'I\'m on my way', needsLocation: false);
      case 'en_route':
        return const _Step('arrived', 'I\'ve arrived', needsLocation: true);
      case 'arrived':
        return const _Step('in_progress', 'Start cleaning', needsLocation: false);
      case 'in_progress':
        return const _Step('completed', 'Finish job', needsLocation: true);
      default:
        return null;
    }
  }

  bool get _photosOutstanding =>
      (_job?.isDeepClean ?? false) && _job?.status == 'in_progress' && _afterPhotos < _requiredAfterPhotos;

  Future<void> _advance(_Step step) async {
    // Mirror the server gate so the cleaner is told to shoot photos before the
    // request is spent, not after a 422.
    if (step.status == 'completed' && _photosOutstanding) {
      _say('Add at least $_requiredAfterPhotos after-photos before finishing.', Sparkle.clay);
      return;
    }

    setState(() => _busy = true);
    try {
      GeoPoint? location;
      if (step.needsLocation) location = await widget.locator.current();

      await widget.repository.updateStatus(widget.bookingId, step.status, location: location);

      // Tracking runs only from en route until arrival — the app stops watching
      // before the cleaner walks in the door.
      if (step.status == 'en_route') await widget.tracker?.start(widget.bookingId);
      if (step.status == 'arrived') await widget.tracker?.stop();

      if (step.status == 'completed') {
        _say('Job complete. Your payout is on its way.', Sparkle.seafoam);
      }
      await _load();
    } on LocationUnavailable catch (e) {
      _say(e.message, Sparkle.clay);
    } on GeofenceFailed catch (e) {
      _say(e.message, Sparkle.clay);
    } on PhotosRequired catch (e) {
      _say(e.message, Sparkle.clay);
    } on LocationRequired catch (e) {
      _say(e.message, Sparkle.clay);
    } on IllegalTransition catch (e) {
      _say(e.message, Sparkle.clay);
      await _load(); // the screen was stale; resync
    } catch (e) {
      _say('$e', Sparkle.clay);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addPhoto() async {
    setState(() => _uploadingPhoto = true);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 70,
        maxWidth: 1600,
      );
      if (file == null) return; // cancelled — not an error
      final bytes = await file.readAsBytes();
      final targets = await widget.repository.presignPhotos(widget.bookingId, 'after', 1);
      await widget.repository.uploadPhoto(targets.first.url, bytes);
      if (!mounted) return;
      setState(() => _afterPhotos += 1);
    } catch (e) {
      _say('Could not add that photo. $e', Sparkle.clay);
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  void _say(String message, Color tone) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: tone,
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    final job = _job;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Sparkle.marine,
        foregroundColor: Colors.white,
        title: Text(job?.reference ?? 'Job',
            style: const TextStyle(fontFamily: 'Archivo', fontWeight: FontWeight.w600)),
        actions: [
          if (widget.chat != null)
            IconButton(
              tooltip: 'Message customer',
              icon: const Icon(Icons.chat_bubble_outline),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ChatScreen(
                  repository: widget.chat!,
                  bookingId: widget.bookingId,
                  title: 'Customer',
                ),
              )),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Sparkle.marine))
          : _error != null
              ? RefreshIndicator(
                  onRefresh: _load,
                  color: Sparkle.marine,
                  child: _ScrollableCenter(child: _ErrorState(message: _error!, onRetry: _load)))
              : _body(job!),
      bottomNavigationBar: job == null ? null : _actionBar(job),
    );
  }

  Widget _body(JobDetail job) {
    return RefreshIndicator(
      onRefresh: _load,
      color: Sparkle.marine,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(Sparkle.s4, Sparkle.s4, Sparkle.s4, Sparkle.s6),
        children: [
          _StatusStepper(status: job.status),
          const SizedBox(height: Sparkle.s5),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(job.serviceName, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 2),
                    Text(_time.format(job.scheduledAt), style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('You earn', style: Theme.of(context).textTheme.labelSmall),
                  Text(_money.format(job.payoutCents / 100),
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(color: Sparkle.payout)),
                ],
              ),
            ],
          ),
          const SizedBox(height: Sparkle.s5),
          if (job.hasAddress)
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Label('Address'),
                  const SizedBox(height: Sparkle.s1),
                  Text(job.line1!, style: Theme.of(context).textTheme.titleMedium),
                  if (job.line2 != null && job.line2!.isNotEmpty)
                    Text(job.line2!, style: Theme.of(context).textTheme.bodyMedium),
                  Text(job.cityLine, style: Theme.of(context).textTheme.bodyMedium),
                  if (job.accessNotes != null && job.accessNotes!.isNotEmpty) ...[
                    const SizedBox(height: Sparkle.s3),
                    const _Label('Getting in'),
                    const SizedBox(height: Sparkle.s1),
                    Text(job.accessNotes!, style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ],
              ),
            )
          else
            _Card(
              child: Row(
                children: [
                  const Icon(Icons.lock_outline, size: 18, color: Sparkle.inkSoft),
                  const SizedBox(width: Sparkle.s2),
                  Expanded(
                    child: Text('The full address unlocks when you start the job.',
                        style: Theme.of(context).textTheme.bodyMedium),
                  ),
                ],
              ),
            ),
          if (job.specialInstructions != null && job.specialInstructions!.isNotEmpty) ...[
            const SizedBox(height: Sparkle.s3),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Label('From the customer'),
                  const SizedBox(height: Sparkle.s1),
                  Text(job.specialInstructions!, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
          ],
          if (job.isDeepClean && job.status == 'in_progress') ...[
            const SizedBox(height: Sparkle.s3),
            _photoCard(),
          ],
          if (_next == null && (job.status == 'completed' || job.status == 'settled')) ...[
            const SizedBox(height: Sparkle.s5),
            Center(
              child: Column(
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.elasticOut,
                    builder: (context, value, child) => Transform.scale(scale: value, child: child),
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: const BoxDecoration(color: Sparkle.seafoamSoft, shape: BoxShape.circle),
                      child: const Icon(Icons.check_circle, color: Sparkle.seafoam, size: 36),
                    ),
                  ),
                  const SizedBox(height: Sparkle.s2),
                  Text('Job complete', style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _photoCard() {
    final done = _afterPhotos >= _requiredAfterPhotos;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _Label('After-photos'),
              const Spacer(),
              Text('$_afterPhotos of $_requiredAfterPhotos',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: done ? Sparkle.seafoam : Sparkle.inkSoft)),
            ],
          ),
          const SizedBox(height: Sparkle.s1),
          Text(
            done
                ? 'You\'ve got enough to finish. Add more if you like.'
                : 'A Deep Clean needs $_requiredAfterPhotos photos of the finished work before you can complete it.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: Sparkle.s3),
          OutlinedButton.icon(
            onPressed: _uploadingPhoto ? null : _addPhoto,
            icon: _uploadingPhoto
                ? const SizedBox(
                    height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Sparkle.marine))
                : const Icon(Icons.camera_alt_outlined, size: 18),
            label: Text(_uploadingPhoto ? 'Uploading…' : 'Add photo'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              foregroundColor: Sparkle.marine,
              side: const BorderSide(color: Sparkle.hairline),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ],
      ),
    );
  }

  Widget? _actionBar(JobDetail job) {
    final step = _next;
    if (step == null) return null;
    final blocked = step.status == 'completed' && _photosOutstanding;
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(Sparkle.s4, Sparkle.s2, Sparkle.s4, Sparkle.s3),
      child: FilledButton(
        onPressed: (_busy || blocked) ? null : () => _advance(step),
        style: FilledButton.styleFrom(
          backgroundColor: blocked ? Sparkle.hairline : Sparkle.marine,
        ),
        child: _busy
            ? const SizedBox(
                height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Text(step.label),
      ),
    );
  }
}

class _Step {
  final String status;
  final String label;
  final bool needsLocation;
  const _Step(this.status, this.label, {required this.needsLocation});
}

class _StatusStepper extends StatelessWidget {
  const _StatusStepper({required this.status});
  final String status;

  static const _order = ['en_route', 'arrived', 'in_progress', 'completed'];
  static const _labels = {
    'en_route': 'On the way',
    'arrived': 'Arrived',
    'in_progress': 'Cleaning',
    'completed': 'Done',
  };

  int get _reached {
    // 'assigned' is before the first step; 'settled' is past the last.
    if (status == 'assigned') return -1;
    if (status == 'settled') return _order.length - 1;
    final i = _order.indexOf(status);
    return i < 0 ? -1 : i;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < _order.length; i++) ...[
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 5,
                  decoration: BoxDecoration(
                    color: i <= _reached ? Sparkle.seafoam : Sparkle.hairline,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(height: Sparkle.s1),
                Text(
                  _labels[_order[i]]!,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: i == _reached ? FontWeight.w700 : FontWeight.w500,
                    color: i <= _reached ? Sparkle.marine : Sparkle.inkSoft,
                  ),
                ),
              ],
            ),
          ),
          if (i < _order.length - 1) const SizedBox(width: Sparkle.s2),
        ],
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Sparkle.surface,
          borderRadius: BorderRadius.circular(Sparkle.radius),
          border: Border.all(color: Sparkle.hairline),
          boxShadow: Sparkle.cardShadow,
        ),
        padding: const EdgeInsets.all(Sparkle.s4),
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
