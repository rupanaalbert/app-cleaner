import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class OnboardingStep {
  final String key;
  final String title;
  final bool complete;
  final String detail;
  const OnboardingStep({
    required this.key,
    required this.title,
    required this.complete,
    required this.detail,
  });
}

class DocumentSlot {
  final String? id;
  final String docType;
  final bool uploaded;
  final bool verified;
  final String? rejectedNote;

  const DocumentSlot({
    required this.docType,
    this.id,
    this.uploaded = false,
    this.verified = false,
    this.rejectedNote,
  });

  String get title => switch (docType) {
        'gov_id' => 'Photo ID',
        'insurance' => 'Proof of insurance',
        'work_auth' => 'Work authorization',
        _ => 'Certification',
      };

  String get why => switch (docType) {
        'gov_id' => 'Driver\'s licence or passport. Must match the name on your background check.',
        'insurance' => 'General liability certificate. Customers ask about this more than anything else.',
        'work_auth' => 'Proof you can work in the US.',
        _ => 'Optional, but it shows up on your profile.',
      };
}

class OnboardingState {
  final String onboardingStatus;
  final bool readyToSubmit;
  final bool submitted;
  final List<OnboardingStep> steps;
  final List<DocumentSlot> documents;
  final List<int> availableDays;

  const OnboardingState({
    required this.onboardingStatus,
    required this.readyToSubmit,
    required this.submitted,
    required this.steps,
    required this.documents,
    required this.availableDays,
  });

  int get completedCount => steps.where((s) => s.complete).length;
  bool get approved => onboardingStatus == 'approved';

  static const _titles = {
    'profile': 'Your profile and hours',
    'documents': 'Documents',
    'payouts': 'How you get paid',
    'background_check': 'Background check',
  };

  factory OnboardingState.fromJson(Map<String, dynamic> json) {
    final rawSteps = json['steps'] as Map<String, dynamic>;
    final rawDocs = (json['documents'] as List).cast<Map<String, dynamic>>();

    // Render every required slot, uploaded or not. A list that only shows what
    // you've already done can't tell you what's left.
    final byType = {for (final d in rawDocs) d['doc_type'] as String: d};
    final slots = ['gov_id', 'insurance', 'work_auth'].map((type) {
      final doc = byType[type];
      return DocumentSlot(
        docType: type,
        id: doc?['id'] as String?,
        uploaded: doc != null,
        verified: doc?['verified_at'] != null,
        rejectedNote: doc?['rejected_note'] as String?,
      );
    }).toList();

    return OnboardingState(
      onboardingStatus: json['onboarding_status'] as String,
      readyToSubmit: json['ready_to_submit'] as bool,
      submitted: json['submitted'] as bool,
      documents: slots,
      availableDays: [
        for (final w in (json['availability'] as List)) (w as Map)['day_of_week'] as int,
      ].toSet().toList()
        ..sort(),
      steps: [
        for (final key in ['profile', 'documents', 'payouts', 'background_check'])
          OnboardingStep(
            key: key,
            title: _titles[key]!,
            complete: (rawSteps[key] as Map)['complete'] as bool,
            detail: (rawSteps[key] as Map)['detail'] as String? ?? '',
          ),
      ],
    );
  }
}

class OnboardingIncomplete implements Exception {
  final String message;
  const OnboardingIncomplete(this.message);
}

class ApiFailure implements Exception {
  final String message;
  const ApiFailure(this.message);
  @override
  String toString() => message;
}

abstract class OnboardingRepository {
  Future<OnboardingState> load();
  Future<OnboardingState> saveProfile({
    String? bio,
    int? yearsExperience,
    List<String>? serviceTypes,
    double? serviceRadiusKm,
  });
  Future<OnboardingState> setAvailability(List<Map<String, int>> windows);
  Future<OnboardingState> uploadDocument(String docType, List<int> bytes, {String? expiresAt});
  Future<OnboardingState> savePayoutsEmail(String email);
  Future<String?> startBackgroundCheck();
  Future<void> submit();
}

class HttpOnboardingRepository implements OnboardingRepository {
  HttpOnboardingRepository({required this.baseUrl, required this.tokenProvider, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final Future<String> Function() tokenProvider;
  final http.Client _client;

  Future<Map<String, String>> _headers() async => {
        'authorization': 'Bearer ${await tokenProvider()}',
        'content-type': 'application/json',
      };

  Future<OnboardingState> _state(http.Response res) {
    if (res.statusCode >= 400) throw ApiFailure(_detail(res));
    return Future.value(OnboardingState.fromJson(jsonDecode(res.body) as Map<String, dynamic>));
  }

  @override
  Future<OnboardingState> load() async =>
      _state(await _client.get(Uri.parse('$baseUrl/v1/cleaner/onboarding'), headers: await _headers()));

  @override
  Future<OnboardingState> saveProfile({
    String? bio,
    int? yearsExperience,
    List<String>? serviceTypes,
    double? serviceRadiusKm,
  }) async =>
      _state(await _client.patch(
        Uri.parse('$baseUrl/v1/cleaner/onboarding/profile'),
        headers: await _headers(),
        body: jsonEncode({
          if (bio != null) 'bio': bio,
          if (yearsExperience != null) 'years_experience': yearsExperience,
          if (serviceTypes != null) 'service_types': serviceTypes,
          if (serviceRadiusKm != null) 'service_radius_km': serviceRadiusKm,
        }),
      ));

  @override
  Future<OnboardingState> setAvailability(List<Map<String, int>> windows) async =>
      _state(await _client.put(
        Uri.parse('$baseUrl/v1/cleaner/onboarding/availability'),
        headers: await _headers(),
        body: jsonEncode({'windows': windows}),
      ));

  /// Three calls: presign, PUT straight to S3, confirm with the hash. The file
  /// itself never passes through our API — one fewer place a passport scan can
  /// land in a log line.
  @override
  Future<OnboardingState> uploadDocument(String docType, List<int> bytes, {String? expiresAt}) async {
    final presign = await _client.post(
      Uri.parse('$baseUrl/v1/cleaner/onboarding/documents'),
      headers: await _headers(),
      body: jsonEncode({
        'doc_type': docType,
        if (expiresAt != null) 'expires_at': expiresAt,
        'content_type': 'image/jpeg',
      }),
    );
    if (presign.statusCode != 201) throw ApiFailure(_detail(presign));
    final slot = jsonDecode(presign.body) as Map<String, dynamic>;

    final put = await _client.put(
      Uri.parse(slot['upload_url'] as String),
      headers: {'content-type': 'image/jpeg'},
      body: bytes,
    );
    if (put.statusCode >= 300) throw const ApiFailure('Upload failed. Check your connection and retry.');

    return _state(await _client.post(
      Uri.parse('$baseUrl/v1/cleaner/onboarding/documents/${slot['document_id']}/confirm'),
      headers: await _headers(),
      body: jsonEncode({'sha256': _sha256Hex(bytes)}),
    ));
  }

  /// PayPal Payouts, not a Stripe-style hosted onboarding link — there's
  /// nowhere to redirect to. The backend saves the email and fires a $0.01
  /// verification payout; `payouts_enabled` flips once that resolves (see
  /// backend/src/services/webhook.service.js), so this just reloads state
  /// rather than returning a URL to open.
  @override
  Future<OnboardingState> savePayoutsEmail(String email) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/v1/cleaner/onboarding/payouts'),
      headers: await _headers(),
      body: jsonEncode({'paypal_email': email}),
    );
    if (res.statusCode != 200) throw ApiFailure(_detail(res));
    return load();
  }

  @override
  Future<String?> startBackgroundCheck() async {
    final res = await _client.post(
      Uri.parse('$baseUrl/v1/cleaner/onboarding/background-check'),
      headers: await _headers(),
    );
    if (res.statusCode != 200) throw ApiFailure(_detail(res));
    return (jsonDecode(res.body) as Map<String, dynamic>)['invitation_url'] as String?;
  }

  @override
  Future<void> submit() async {
    final res = await _client.post(
      Uri.parse('$baseUrl/v1/cleaner/onboarding/submit'),
      headers: await _headers(),
    );
    if (res.statusCode == 422) throw OnboardingIncomplete(_detail(res));
    if (res.statusCode != 200) throw ApiFailure(_detail(res));
  }

  String _detail(http.Response res) {
    try {
      return (jsonDecode(res.body) as Map<String, dynamic>)['detail'] as String;
    } catch (_) {
      return 'Something went wrong. Try again in a moment.';
    }
  }

  // The backend checks this against what actually landed in S3, so it must be
  // the digest of the exact bytes we PUT — same `bytes`, no re-encoding.
  String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();
}
