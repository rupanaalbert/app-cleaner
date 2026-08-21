import 'dart:async';

import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'data/chat_repository.dart';
import 'data/earnings_repository.dart';
import 'data/geolocation.dart';
import 'data/jobs_repository.dart';
import 'data/offers_repository.dart';
import 'features/active_job/active_job_screen.dart';
import 'features/earnings/earnings_screen.dart';
import 'features/job_discovery/job_discovery_screen.dart';
import 'features/schedule/schedule_screen.dart';

void main() => runApp(const SparkleCleanerApp());

class SparkleCleanerApp extends StatelessWidget {
  const SparkleCleanerApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Swap these fakes for the Http* repositories once auth is wired:
    //   HttpOffersRepository(baseUrl: ..., tokenProvider: ...), etc., and a
    //   GeolocatorLocator() plus a real LocationPublisher for en-route tracking.
    // The fakes keep every screen runnable and testable without a backend.
    return MaterialApp(
      title: 'Sparkle',
      theme: Sparkle.theme(),
      debugShowCheckedModeBanner: false,
      home: HomeShell(
        offers: _FakeOffersRepository(),
        jobs: _FakeJobsRepository(),
        earnings: _FakeEarningsRepository(),
        locator: const FakeLocator(),
        chat: _FakeChatRepository(),
      ),
    );
  }
}

/// The cleaner's three tabs: find work, do the work you took, see what you made.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.offers,
    required this.jobs,
    required this.earnings,
    required this.locator,
    required this.chat,
  });

  final OffersRepository offers;
  final JobsRepository jobs;
  final EarningsRepository earnings;
  final Locator locator;
  final ChatRepository chat;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  Future<void> _openJob(ScheduledJob job) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ActiveJobScreen(
        repository: widget.jobs,
        locator: widget.locator,
        bookingId: job.bookingId,
        chat: widget.chat,
        // tracker: LocationPublisher(...) in production — streams position to
        // the customer while en route. Left null under the fake (no Firebase).
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilt per selection so Schedule and Earnings are always fresh when
    // opened — each loads on init and supports pull-to-refresh.
    final screen = switch (_tab) {
      1 => ScheduleScreen(repository: widget.jobs, onOpenJob: _openJob),
      2 => EarningsScreen(repository: widget.earnings),
      _ => JobDiscoveryScreen(
          repository: widget.offers,
          onOfferAccepted: (_) => setState(() => _tab = 1), // land on the schedule
        ),
    };

    return Scaffold(
      body: screen,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.search), label: 'Discover'),
          NavigationDestination(icon: Icon(Icons.event_note_outlined), label: 'Schedule'),
          NavigationDestination(icon: Icon(Icons.payments_outlined), label: 'Earnings'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- fakes -----

class _FakeOffersRepository implements OffersRepository {
  @override
  Future<List<JobOffer>> fetchOpenOffers() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final now = DateTime.now();
    return [
      JobOffer(
        offerId: '1', bookingId: 'b1', serviceCode: 'deep', serviceName: 'Deep Clean',
        scheduledAt: now.add(const Duration(days: 1, hours: 3)), durationMin: 180,
        payoutCents: 14260, distanceKm: 4.2, neighborhood: 'Malden, MA 02148',
        lat: 42.4258, lng: -71.0662, bedrooms: 3, bathrooms: 2, squareFeet: 1600,
        hasPets: true, expiresAt: now.add(const Duration(seconds: 74)),
      ),
      JobOffer(
        offerId: '2', bookingId: 'b2', serviceCode: 'standard', serviceName: 'Standard Clean',
        scheduledAt: now.add(const Duration(days: 2, hours: 1)), durationMin: 120,
        payoutCents: 8640, distanceKm: 9.8, neighborhood: 'Methuen, MA 01844',
        lat: 42.7262, lng: -71.1909, bedrooms: 2, bathrooms: 1, squareFeet: 1100,
        hasPets: false, expiresAt: now.add(const Duration(seconds: 18)),
      ),
    ];
  }

  @override
  Future<void> accept(String offerId) async =>
      Future<void>.delayed(const Duration(milliseconds: 600));

  @override
  Future<void> decline(String offerId, String reason) async {}

  @override
  Future<void> setAvailability(bool online) async {}
}

class _FakeJobData {
  _FakeJobData({
    required this.reference,
    required this.serviceCode,
    required this.scheduledAt,
    required this.durationMin,
    required this.payoutCents,
    required this.status,
    required this.line1,
    required this.city,
    required this.region,
    required this.postalCode,
    required this.accessNotes,
    required this.instructions,
  });

  final String reference;
  final String serviceCode;
  final DateTime scheduledAt;
  final int durationMin;
  final int payoutCents;
  String status;
  final String line1;
  final String city;
  final String region;
  final String postalCode;
  final String? accessNotes;
  final String? instructions;
}

class _FakeJobsRepository implements JobsRepository {
  _FakeJobsRepository();

  final _now = DateTime.now();
  late final Map<String, _FakeJobData> _data = {
    'b1': _FakeJobData(
      reference: 'SPK-8J4K2Q', serviceCode: 'deep',
      scheduledAt: _now.add(const Duration(hours: 1)), durationMin: 180, payoutCents: 14260,
      status: 'en_route', line1: '27 Pleasant St', city: 'Methuen', region: 'MA', postalCode: '01844',
      accessNotes: 'Key under the pot on the porch. Friendly dog inside.',
      instructions: 'Please focus on the kitchen and both bathrooms.',
    ),
    'b2': _FakeJobData(
      reference: 'SPK-3RT9WM', serviceCode: 'standard',
      scheduledAt: _now.add(const Duration(hours: 5)), durationMin: 120, payoutCents: 8640,
      status: 'assigned', line1: '10 Elm St', city: 'Andover', region: 'MA', postalCode: '01810',
      accessNotes: null, instructions: null,
    ),
    'b3': _FakeJobData(
      reference: 'SPK-K22XQD', serviceCode: 'deep',
      scheduledAt: _now.add(const Duration(days: 1, hours: 2)), durationMin: 180, payoutCents: 13120,
      status: 'assigned', line1: '4 Harbor Rd', city: 'Haverhill', region: 'MA', postalCode: '01830',
      accessNotes: null, instructions: 'Interior windows if you have time.',
    ),
  };

  ScheduledJob _scheduled(String id, _FakeJobData d) => ScheduledJob(
        bookingId: id, reference: d.reference, serviceCode: d.serviceCode,
        serviceName: d.serviceCode == 'deep' ? 'Deep Clean' : 'Standard Clean',
        scheduledAt: d.scheduledAt, durationMin: d.durationMin, payoutCents: d.payoutCents,
        status: d.status,
      );

  @override
  Future<List<ScheduledJob>> schedule() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final jobs = _data.entries.map((e) => _scheduled(e.key, e.value)).toList()
      ..sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
    return jobs;
  }

  @override
  Future<JobDetail> job(String bookingId) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final d = _data[bookingId]!;
    return JobDetail(
      bookingId: bookingId, reference: d.reference, serviceCode: d.serviceCode,
      serviceName: d.serviceCode == 'deep' ? 'Deep Clean' : 'Standard Clean',
      scheduledAt: d.scheduledAt, durationMin: d.durationMin, payoutCents: d.payoutCents,
      tipCents: 0, status: d.status, specialInstructions: d.instructions,
      line1: d.line1, line2: null, city: d.city, region: d.region, postalCode: d.postalCode,
      accessNotes: d.accessNotes,
    );
  }

  @override
  Future<ScheduledJob> updateStatus(String bookingId, String status,
      {GeoPoint? location, int? actualDurationMin}) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _data[bookingId]!.status = status;
    return _scheduled(bookingId, _data[bookingId]!);
  }

  @override
  Future<List<PhotoTarget>> presignPhotos(String bookingId, String phase, int count) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return [for (var i = 0; i < count; i++) PhotoTarget(key: '$bookingId/$phase/$i', url: 'https://example.invalid/upload')];
  }

  @override
  Future<void> uploadPhoto(String uploadUrl, List<int> bytes) async =>
      Future<void>.delayed(const Duration(milliseconds: 300));
}

class _FakeChatRepository implements ChatRepository {
  final _messages = <ChatMessage>[
    ChatMessage(
      id: '0', senderId: 'customer', body: 'Hi! The gate code is 4432, and please watch for the cat.',
      sentAt: DateTime.now().subtract(const Duration(minutes: 12)),
    ),
  ];
  final _controller = StreamController<List<ChatMessage>>.broadcast();

  @override
  String get currentUserId => 'me';

  @override
  Future<void> ready() async {}

  @override
  Stream<List<ChatMessage>> watch(String bookingId) async* {
    yield List.of(_messages);
    yield* _controller.stream;
  }

  @override
  Future<void> send(String bookingId, String body) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    _messages.add(ChatMessage(id: '${_messages.length}', senderId: 'me', body: body, sentAt: DateTime.now()));
    _controller.add(List.of(_messages));
  }
}

class _FakeEarningsRepository implements EarningsRepository {
  @override
  Future<Earnings> fetch({DateTime? from, DateTime? to}) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // Wider windows show more; keeps the period switch visibly doing something.
    final scale = from == null ? 12 : (DateTime.now().difference(from).inDays > 20 ? 4 : 1);
    return Earnings(
      grossCents: 21500 * scale,
      commissionCents: 4300 * scale,
      netCents: 17200 * scale,
      tipsCents: 1500 * scale,
      jobs: 3 * scale,
      nextPayoutCents: 18700,
      nextPayoutArrival: DateTime.now().add(const Duration(days: 2)),
    );
  }
}
