import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/chat_repository.dart';
import '../../data/tracking_repository.dart';
import '../chat/chat_screen.dart';

/// Track your cleaner.
///
/// The screen answers one question — "where are they and when will they be
/// here?" — and stops answering it the moment the answer stops mattering.
/// Location disappears at `arrived`: watching someone's dot while they're
/// inside your house is surveillance, not service, and the Firebase rules
/// enforce the same boundary server-side.
class TrackBookingScreen extends StatefulWidget {
  const TrackBookingScreen({
    super.key,
    required this.repository,
    required this.bookingId,
    this.chat,
  });

  final TrackingRepository repository;
  final String bookingId;

  /// Booking thread. Optional so the screen runs under a fake with no Firebase;
  /// when present (and a cleaner is assigned), a message button appears.
  final ChatRepository? chat;

  @override
  State<TrackBookingScreen> createState() => _TrackBookingScreenState();
}

class _TrackBookingScreenState extends State<TrackBookingScreen> {
  BookingProgress? _progress;
  TrackingPing? _ping;
  String? _error;
  bool _callPending = false;

  StreamSubscription<TrackingPing>? _locationSub;
  StreamSubscription<String>? _statusSub;
  GoogleMapController? _map;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    _statusSub?.cancel();
    _map?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final progress = await widget.repository.loadProgress(widget.bookingId);
      if (!mounted) return;
      setState(() {
        _progress = progress;
        _error = null;
      });
      _bindStreams(progress);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not load this booking. Pull down to retry.');
    }
  }

  void _bindStreams(BookingProgress progress) {
    _statusSub ??= widget.repository.watchStatus(widget.bookingId).listen((status) {
      if (!mounted || status == _progress?.status) return;
      // Status came from Firebase, but timestamps and the cleaner profile live
      // in Postgres — refetch rather than patching a half-known object.
      _load();
    });

    _locationSub?.cancel();
    _locationSub = null;
    if (!progress.isTrackable) {
      setState(() => _ping = null);
      return;
    }

    _locationSub = widget.repository.watchLocation(widget.bookingId).listen((ping) {
      if (!mounted) return;
      setState(() => _ping = ping);
      _map?.animateCamera(CameraUpdate.newLatLng(LatLng(ping.lat, ping.lng)));
    });
  }

  Future<void> _call() async {
    setState(() => _callPending = true);
    try {
      final call = await widget.repository.openCall(widget.bookingId);
      if (!mounted) return;
      _say('Calling ${call.proxyNumber} — your real number stays private.');
    } catch (e) {
      if (!mounted) return;
      _say('$e', tone: Sparkle.clay);
    } finally {
      if (mounted) setState(() => _callPending = false);
    }
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

  @override
  Widget build(BuildContext context) {
    final progress = _progress;

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(Sparkle.s6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off_outlined, size: 40, color: Sparkle.inkSoft),
                const SizedBox(height: Sparkle.s4),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: Sparkle.s4),
                FilledButton(onPressed: _load, child: const Text('Try again')),
              ],
            ),
          ),
        ),
      );
    }

    if (progress == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: Sparkle.marine)));
    }

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: _mapOrPlaceholder(progress)),
          Positioned(
            top: MediaQuery.of(context).padding.top + Sparkle.s2,
            left: Sparkle.s3,
            child: _CircleButton(icon: Icons.arrow_back, onTap: () => Navigator.maybePop(context)),
          ),
          if (widget.chat != null && progress.hasCleaner)
            Positioned(
              top: MediaQuery.of(context).padding.top + Sparkle.s2,
              right: Sparkle.s3,
              child: _CircleButton(
                icon: Icons.chat_bubble_outline,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ChatScreen(
                    repository: widget.chat!,
                    bookingId: widget.bookingId,
                    title: 'Your cleaner',
                  ),
                )),
              ),
            ),
          DraggableScrollableSheet(
            initialChildSize: progress.isTrackable ? 0.42 : 0.55,
            minChildSize: 0.28,
            maxChildSize: 0.9,
            builder: (context, controller) => _Sheet(
              controller: controller,
              progress: progress,
              ping: _ping,
              callPending: _callPending,
              onCall: _call,
            ),
          ),
        ],
      ),
    );
  }

  Widget _mapOrPlaceholder(BookingProgress progress) {
    if (!progress.isTrackable || _ping == null) {
      return Container(
        color: Sparkle.marine,
        alignment: Alignment.topCenter,
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 80),
        child: _WaitingHeader(progress: progress),
      );
    }

    final ping = _ping!;
    return GoogleMap(
      initialCameraPosition: CameraPosition(target: LatLng(ping.lat, ping.lng), zoom: 14),
      onMapCreated: (c) => _map = c,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      markers: {
        Marker(
          markerId: const MarkerId('cleaner'),
          position: LatLng(ping.lat, ping.lng),
          rotation: ping.heading ?? 0,
          flat: true,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          infoWindow: InfoWindow(title: progress.cleanerName ?? 'Your cleaner'),
        ),
        Marker(
          markerId: const MarkerId('home'),
          position: LatLng(progress.propertyLat, progress.propertyLng),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          infoWindow: const InfoWindow(title: 'Your home'),
        ),
      },
    );
  }
}

class _WaitingHeader extends StatelessWidget {
  const _WaitingHeader({required this.progress});
  final BookingProgress progress;

  @override
  Widget build(BuildContext context) {
    final (icon, line) = switch (progress.status) {
      'pending_match' => (Icons.search, 'Finding your cleaner'),
      'assigned' => (Icons.event_available_outlined, 'Booked and confirmed'),
      'arrived' => (Icons.door_front_door_outlined, 'Your cleaner has arrived'),
      'in_progress' => (Icons.cleaning_services_outlined, 'Cleaning in progress'),
      'completed' || 'settled' => (Icons.check_circle_outline, 'All done'),
      'canceled' => (Icons.cancel_outlined, 'This booking was canceled'),
      _ => (Icons.schedule, 'Booked'),
    };

    return Column(
      children: [
        Icon(icon, color: Colors.white, size: 34),
        const SizedBox(height: Sparkle.s3),
        Text(line,
            style: const TextStyle(
                fontFamily: 'Manrope', fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white)),
      ],
    );
  }
}

class _Sheet extends StatelessWidget {
  const _Sheet({
    required this.controller,
    required this.progress,
    required this.ping,
    required this.callPending,
    required this.onCall,
  });

  final ScrollController controller;
  final BookingProgress progress;
  final TrackingPing? ping;
  final bool callPending;
  final VoidCallback onCall;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Sparkle.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: Sparkle.stickyBarShadow,
      ),
      child: ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(Sparkle.s4, Sparkle.s3, Sparkle.s4, Sparkle.s6),
        children: [
          Center(
            child: Container(
              height: 4, width: 40,
              decoration: BoxDecoration(
                color: Sparkle.hairline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: Sparkle.s4),
          _headline(context),
          const SizedBox(height: Sparkle.s5),
          if (progress.hasCleaner) _cleanerCard(context),
          const SizedBox(height: Sparkle.s5),
          Text('Progress', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: Sparkle.s3),
          _Timeline(progress: progress),
        ],
      ),
    );
  }

  Widget _headline(BuildContext context) {
    if (progress.isTrackable && ping != null) {
      final eta = estimateEtaMinutes(ping!, progress.propertyLat, progress.propertyLng);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Arriving in about', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 2),
          Text('$eta min', style: Theme.of(context).textTheme.displaySmall),
          if (ping!.isStale) ...[
            const SizedBox(height: Sparkle.s2),
            const Row(
              children: [
                Icon(Icons.signal_cellular_connected_no_internet_0_bar, size: 14, color: Sparkle.inkSoft),
                SizedBox(width: Sparkle.s2),
                Expanded(
                  child: Text(
                    'Location paused — weak signal on their phone. They\'re still on the way.',
                    style: TextStyle(fontSize: 12, color: Sparkle.inkSoft),
                  ),
                ),
              ],
            ),
          ],
        ],
      );
    }

    final line = switch (progress.status) {
      'pending_match' =>
        'We\'re matching you with a cleaner nearby. This usually takes a few minutes.',
      'assigned' =>
        'You\'ll be able to track your cleaner here once they set off for your home.',
      'arrived' => 'Your cleaner is at the door.',
      'in_progress' => 'Cleaning is underway. We\'ll let you know when it\'s finished.',
      'completed' || 'settled' => 'Your clean is finished. Your card has been charged.',
      'canceled' => 'This booking was canceled. Nothing further will be charged.',
      _ => '',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          DateFormat('EEEE d MMMM · h:mm a').format(progress.scheduledAt),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: Sparkle.s2),
        Text(line, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }

  Widget _cleanerCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Sparkle.s3),
      decoration: BoxDecoration(
        color: Sparkle.linen,
        borderRadius: BorderRadius.circular(Sparkle.radius),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: Sparkle.seafoamSoft,
            backgroundImage: progress.cleanerAvatarUrl != null
                ? NetworkImage(progress.cleanerAvatarUrl!)
                : null,
            child: progress.cleanerAvatarUrl == null
                ? Text(
                    progress.cleanerName![0],
                    style: const TextStyle(
                        fontFamily: 'Manrope', fontSize: 20, color: Sparkle.marine),
                  )
                : null,
          ),
          const SizedBox(width: Sparkle.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(progress.cleanerName!, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 2),
                Row(
                  children: [
                    const Icon(Icons.star_rounded, size: 15, color: Sparkle.seafoam),
                    const SizedBox(width: 3),
                    Text(
                      progress.cleanerRating?.toStringAsFixed(2) ?? 'New',
                      style: const TextStyle(fontSize: 13, color: Sparkle.ink),
                    ),
                    const Text(' · ', style: TextStyle(color: Sparkle.inkSoft)),
                    Text('${progress.cleanerJobsCompleted} cleans',
                        style: const TextStyle(fontSize: 13, color: Sparkle.inkSoft)),
                  ],
                ),
              ],
            ),
          ),
          _CircleButton(
            icon: Icons.chat_bubble_outline,
            onTap: () => Navigator.pushNamed(context, '/chat'),
          ),
          const SizedBox(width: Sparkle.s2),
          _CircleButton(
            icon: Icons.call_outlined,
            busy: callPending,
            filled: true,
            onTap: onCall,
          ),
        ],
      ),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.progress});
  final BookingProgress progress;

  @override
  Widget build(BuildContext context) {
    final steps = <(String, DateTime?)>[
      ('Cleaner assigned', progress.enRouteAt ?? progress.scheduledAt),
      ('On the way', progress.enRouteAt),
      ('Arrived', progress.arrivedAt),
      ('Cleaning', progress.startedAt),
      ('Finished', progress.completedAt),
    ];
    final format = DateFormat('h:mm a');

    return Column(
      children: [
        for (var i = 0; i < steps.length; i++)
          _TimelineRow(
            label: steps[i].$1,
            time: steps[i].$2 == null ? null : format.format(steps[i].$2!),
            done: steps[i].$2 != null,
            isLast: i == steps.length - 1,
          ),
      ],
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.label,
    required this.time,
    required this.done,
    required this.isLast,
  });

  final String label;
  final String? time;
  final bool done;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              Container(
                height: 14, width: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: done ? Sparkle.seafoam : Sparkle.surface,
                  border: Border.all(color: done ? Sparkle.seafoam : Sparkle.hairline, width: 2),
                ),
              ),
              if (!isLast)
                Expanded(
                  child: Container(width: 2, color: done ? Sparkle.seafoam : Sparkle.hairline),
                ),
            ],
          ),
          const SizedBox(width: Sparkle.s3),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : Sparkle.s4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: done ? FontWeight.w600 : FontWeight.w400,
                        color: done ? Sparkle.inkStrong : Sparkle.inkSoft,
                      ),
                    ),
                  ),
                  if (time != null)
                    Text(time!, style: const TextStyle(fontSize: 13, color: Sparkle.inkSoft)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    this.filled = false,
    this.busy = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool filled;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: busy ? null : onTap,
      customBorder: const CircleBorder(),
      child: Container(
        height: 44,
        width: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? Sparkle.seafoam : Sparkle.surface,
          border: Border.all(color: filled ? Sparkle.seafoam : Sparkle.hairline),
        ),
        child: busy
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : Icon(icon, size: 20, color: filled ? Colors.white : Sparkle.marine),
      ),
    );
  }
}
