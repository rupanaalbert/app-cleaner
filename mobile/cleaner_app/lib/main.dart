import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'core/theme.dart';
import 'data/chat_repository.dart';
import 'data/earnings_repository.dart';
import 'data/geolocation.dart';
import 'data/jobs_repository.dart';
import 'data/offers_repository.dart';
import 'data/onboarding_repository.dart';
import 'features/active_job/active_job_screen.dart';
import 'features/earnings/earnings_screen.dart';
import 'features/job_discovery/job_discovery_screen.dart';
import 'features/onboarding/documents_step_screen.dart';
import 'features/onboarding/onboarding_hub_screen.dart';
import 'features/onboarding/payouts_step_screen.dart';
import 'features/schedule/schedule_screen.dart';

void main() => runApp(const SparkleCleanerApp());

// 10.0.2.2 is the Android emulator's alias for the host machine's localhost —
// `npm run dev` in backend/ needs to already be running there.
const _devApiBaseUrl = 'http://10.0.2.2:8080';

// There's no login screen wired up yet, so this logs in with a seeded dev
// cleaner on every token request rather than caching — simplest thing that
// can't hand the app a stale/expired access token. Swap for a real session
// once auth exists. Chat and location stay on their fakes: chat needs
// Firebase config that doesn't exist yet, and there's no real device/GPS
// position worth publishing from an emulator.
Future<String> _devTokenProvider() async {
  final res = await http.post(
    Uri.parse('$_devApiBaseUrl/v1/auth/login'),
    headers: {'content-type': 'application/json'},
    body: jsonEncode({'email': 'amara.osei@example.com', 'password': 'sparkle-dev-password'}),
  );
  if (res.statusCode != 200) throw StateError('dev login failed: ${res.statusCode} ${res.body}');
  return (jsonDecode(res.body) as Map<String, dynamic>)['access_token'] as String;
}

class SparkleCleanerApp extends StatelessWidget {
  const SparkleCleanerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sparkle',
      theme: Sparkle.theme(),
      debugShowCheckedModeBanner: false,
      home: HomeShell(
        offers: HttpOffersRepository(baseUrl: _devApiBaseUrl, tokenProvider: _devTokenProvider),
        jobs: HttpJobsRepository(baseUrl: _devApiBaseUrl, tokenProvider: _devTokenProvider),
        earnings: HttpEarningsRepository(baseUrl: _devApiBaseUrl, tokenProvider: _devTokenProvider),
        locator: const FakeLocator(),
        chat: _FakeChatRepository(),
        onboarding: HttpOnboardingRepository(baseUrl: _devApiBaseUrl, tokenProvider: _devTokenProvider),
      ),
    );
  }
}

/// The cleaner's four tabs: find work, do the work you took, see what you
/// made, get approved to work at all.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.offers,
    required this.jobs,
    required this.earnings,
    required this.locator,
    required this.chat,
    required this.onboarding,
  });

  final OffersRepository offers;
  final JobsRepository jobs;
  final EarningsRepository earnings;
  final Locator locator;
  final ChatRepository chat;
  final OnboardingRepository onboarding;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  // Bumped whenever a step screen returns, so OnboardingHubScreen remounts
  // (via its key below) and reloads instead of showing stale progress.
  int _onboardingRefreshTick = 0;

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

  Future<void> _openOnboardingStep(String key) async {
    final state = await widget.onboarding.load();
    if (!mounted) return;

    switch (key) {
      case 'documents':
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => DocumentsStepScreen(
            repository: widget.onboarding,
            initial: state,
            pickImage: (fromCamera) async {
              final file = await ImagePicker().pickImage(
                source: fromCamera ? ImageSource.camera : ImageSource.gallery,
                imageQuality: 70,
                maxWidth: 1600,
              );
              return file?.readAsBytes();
            },
          ),
        ));
      case 'payouts':
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PayoutsStepScreen(repository: widget.onboarding, initial: state),
        ));
      default:
        // Profile and background-check steps don't have dedicated screens yet
        // — a pre-existing gap, not something this payments migration adds.
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Coming soon')));
        return;
    }
    if (mounted) setState(() => _onboardingRefreshTick++);
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilt per selection so Schedule and Earnings are always fresh when
    // opened — each loads on init and supports pull-to-refresh.
    final screen = switch (_tab) {
      1 => ScheduleScreen(repository: widget.jobs, onOpenJob: _openJob),
      2 => EarningsScreen(repository: widget.earnings),
      3 => OnboardingHubScreen(
          key: ValueKey(_onboardingRefreshTick),
          repository: widget.onboarding,
          onOpenStep: _openOnboardingStep,
        ),
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
          NavigationDestination(icon: Icon(Icons.verified_user_outlined), label: 'Approval'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- fakes -----

class FakeOffersRepository implements OffersRepository {
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

class FakeJobsRepository implements JobsRepository {
  FakeJobsRepository();

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

/// Simulates instant approval at every step — there's no reviewer or PayPal
/// sandbox behind a fake. The real `HttpOnboardingRepository` gates
/// `payouts_enabled` on an async webhook (see webhook.service.js); this fake
/// just flips it on the call so the demo flow doesn't stall waiting for
/// something that will never arrive.
class FakeOnboardingRepository implements OnboardingRepository {
  bool _profileDone = false;
  bool _availabilityDone = false;
  final Set<String> _verifiedDocs = {};
  bool _payoutsDone = false;
  String _bgStatus = 'not_started';

  OnboardingState _snapshot() {
    const requiredDocs = ['gov_id', 'insurance', 'work_auth'];
    return OnboardingState.fromJson({
      'onboarding_status': _bgStatus == 'clear' &&
              _profileDone &&
              _availabilityDone &&
              _verifiedDocs.length == requiredDocs.length &&
              _payoutsDone
          ? 'approved'
          : 'started',
      'ready_to_submit': _profileDone &&
          _availabilityDone &&
          _verifiedDocs.length == requiredDocs.length &&
          _payoutsDone,
      'submitted': false,
      'documents': [
        for (final type in _verifiedDocs)
          {'doc_type': type, 'id': type, 'verified_at': DateTime.now().toIso8601String()},
      ],
      'availability': _availabilityDone
          ? [
              for (var d = 1; d <= 5; d++) {'day_of_week': d},
            ]
          : [],
      'steps': {
        'profile': {
          'complete': _profileDone && _availabilityDone,
          'detail': _availabilityDone ? '5 weekly windows, 15 km radius' : 'Add the hours you can work',
        },
        'documents': {
          'complete': _verifiedDocs.length == requiredDocs.length,
          'detail': _verifiedDocs.length == requiredDocs.length
              ? '${_verifiedDocs.length} uploaded'
              : 'Still needed: ${requiredDocs.where((d) => !_verifiedDocs.contains(d)).join(', ')}',
        },
        'payouts': {
          'complete': _payoutsDone,
          'detail': _payoutsDone ? 'Ready to receive payouts' : 'Add your PayPal email',
        },
        'background_check': {
          'complete': _bgStatus == 'clear',
          'detail': switch (_bgStatus) {
            'clear' => 'Clear',
            'pending' => 'In progress — usually 1 to 3 business days',
            _ => 'Consent to a background check',
          },
        },
      },
    });
  }

  @override
  Future<OnboardingState> load() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return _snapshot();
  }

  @override
  Future<OnboardingState> saveProfile({
    String? bio,
    int? yearsExperience,
    List<String>? serviceTypes,
    double? serviceRadiusKm,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _profileDone = true;
    return _snapshot();
  }

  @override
  Future<OnboardingState> setAvailability(List<Map<String, int>> windows) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _availabilityDone = windows.isNotEmpty;
    return _snapshot();
  }

  @override
  Future<OnboardingState> uploadDocument(String docType, List<int> bytes, {String? expiresAt}) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    _verifiedDocs.add(docType);
    return _snapshot();
  }

  @override
  Future<OnboardingState> savePayoutsEmail(String email) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _payoutsDone = true;
    return _snapshot();
  }

  @override
  Future<String?> startBackgroundCheck() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _bgStatus = 'clear';
    return null;
  }

  @override
  Future<void> submit() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!_snapshot().readyToSubmit) {
      throw const OnboardingIncomplete('Finish the tasks above first.');
    }
  }
}

class FakeEarningsRepository implements EarningsRepository {
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
