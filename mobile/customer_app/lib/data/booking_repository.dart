import 'dart:convert';
import 'package:http/http.dart' as http;

/// One line in the price ledger. The API sends a resolved breakdown; the app
/// renders it as-is rather than recomputing, so the customer and the database
/// can never disagree about what a booking costs.
class PriceLine {
  final String label;
  final int cents;
  final bool isFee;
  const PriceLine(this.label, this.cents, {this.isFee = false});
}

class Quote {
  final String id;
  final DateTime expiresAt;
  final int durationMin;
  final int subtotalCents;
  final int trustFeeCents;
  final int taxCents;
  final int totalCents;
  final List<PriceLine> lines;
  final List<String> multipliers; // e.g. ['weekend']

  const Quote({
    required this.id,
    required this.expiresAt,
    required this.durationMin,
    required this.subtotalCents,
    required this.trustFeeCents,
    required this.taxCents,
    required this.totalCents,
    required this.lines,
    required this.multipliers,
  });

  bool get isStale => DateTime.now().isAfter(expiresAt);
  Duration get timeLeft => expiresAt.difference(DateTime.now());

  factory Quote.fromJson(Map<String, dynamic> json) {
    final b = json['breakdown'] as Map<String, dynamic>;
    final lines = <PriceLine>[
      PriceLine('Base rate', b['base_cents'] as int),
      PriceLine('${(b['bedrooms'] as Map)['count']} bedrooms', (b['bedrooms'] as Map)['cents'] as int),
      PriceLine('${(b['bathrooms'] as Map)['count']} bathrooms', (b['bathrooms'] as Map)['cents'] as int),
      if ((b['size_tier_cents'] as int) > 0)
        PriceLine('Home size', b['size_tier_cents'] as int),
      for (final a in (b['addons'] as List))
        PriceLine(_addonLabel((a as Map)['code'] as String), a['cents'] as int),
      PriceLine('Trust & Safety fee', b['trust_safety_fee_cents'] as int, isFee: true),
    ];

    return Quote(
      id: json['quote_id'] as String,
      expiresAt: DateTime.parse(json['expires_at'] as String).toLocal(),
      durationMin: json['duration_min'] as int,
      subtotalCents: b['subtotal_cents'] as int,
      trustFeeCents: b['trust_safety_fee_cents'] as int,
      taxCents: 0,
      totalCents: json['total_cents'] as int,
      lines: lines,
      multipliers: [
        for (final m in (b['multipliers'] as List))
          (m as Map)['code'] as String,
      ].where((c) => c != 'cap_applied').toList(),
    );
  }

  static String _addonLabel(String code) => switch (code) {
        'inside_fridge' => 'Inside fridge',
        'inside_oven' => 'Inside oven',
        'interior_windows' => 'Interior windows',
        'laundry' => 'Laundry',
        _ => code,
      };
}

class ServiceOption {
  final String code;
  final String name;
  final String pitch;
  final String detail;
  const ServiceOption(this.code, this.name, this.pitch, this.detail);

  static const catalog = [
    ServiceOption('standard', 'Standard Clean', 'Keeping on top of things',
        'Floors, surfaces, kitchen, bathrooms, and a general tidy.'),
    ServiceOption('deep', 'Deep Clean', 'First clean or a reset',
        'Everything in a standard clean, plus baseboards, inside appliances, grout, and behind furniture. Takes about twice as long.'),
  ];
}

class AddonOption {
  final String code;
  final String name;
  final int priceCents;
  const AddonOption(this.code, this.name, this.priceCents);

  static const catalog = [
    AddonOption('inside_fridge', 'Inside fridge', 2500),
    AddonOption('inside_oven', 'Inside oven', 2500),
    AddonOption('interior_windows', 'Interior windows', 3500),
    AddonOption('laundry', 'Laundry (1 load)', 1500),
  ];
}

/// Everything the customer has chosen so far. Nullable fields are the ones
/// that gate progress through the flow.
class BookingDraft {
  String? propertyId;
  String serviceCode = 'standard';
  Set<String> addonCodes = {};
  int bedrooms = 2;
  int bathrooms = 1;
  int? squareFeet;
  DateTime? scheduledAt;
  String? specialInstructions;
  String entryMethod = 'home';

  bool get hasSchedule => scheduledAt != null;
  bool get isQuotable => propertyId != null && scheduledAt != null;
}

class ConfirmedBooking {
  final String id;
  final String reference;
  final String status;
  final DateTime scheduledAt;
  final int totalCents;
  const ConfirmedBooking({
    required this.id,
    required this.reference,
    required this.status,
    required this.scheduledAt,
    required this.totalCents,
  });

  factory ConfirmedBooking.fromJson(Map<String, dynamic> json) {
    final b = json['booking'] as Map<String, dynamic>;
    return ConfirmedBooking(
      id: b['id'] as String,
      reference: b['reference'] as String,
      status: b['status'] as String,
      scheduledAt: DateTime.parse(b['scheduled_at'] as String).toLocal(),
      totalCents: b['total_cents'] as int,
    );
  }
}

/// The order the customer approves via [PaypalApprovalScreen] before
/// `confirm` is called. `approveUrl` is opened in a webview; PayPal redirects
/// back to `sparkle://booking/paypal/return` on approval.
///
/// [kDemoApprovedPaypalUrl] is a sentinel a fake repository can return to
/// skip the webview entirely — there's no real PayPal to redirect through in
/// a demo/offline build, and the flow should still complete like it always
/// has for `FakeBookingRepository`.
const kDemoApprovedPaypalUrl = 'demo:approved';

class PaypalOrder {
  final String orderId;
  final String approveUrl;
  const PaypalOrder({required this.orderId, required this.approveUrl});

  factory PaypalOrder.fromJson(Map<String, dynamic> json) => PaypalOrder(
        orderId: json['order_id'] as String,
        approveUrl: json['approve_url'] as String,
      );
}

class QuoteExpired implements Exception {
  const QuoteExpired();
}

class CardDeclined implements Exception {
  final String message;
  const CardDeclined(this.message);
}

class ApiFailure implements Exception {
  final String message;
  const ApiFailure(this.message);
  @override
  String toString() => message;
}

abstract class BookingRepository {
  Future<Quote> requestQuote(BookingDraft draft);
  Future<PaypalOrder> createPaypalOrder(String quoteId);
  Future<ConfirmedBooking> confirm({
    required String quoteId,
    required String paypalOrderId,
    required BookingDraft draft,
    required String idempotencyKey,
  });
}

class HttpBookingRepository implements BookingRepository {
  HttpBookingRepository({required this.baseUrl, required this.tokenProvider, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final Future<String> Function() tokenProvider;
  final http.Client _client;

  Future<Map<String, String>> _headers([String? idempotencyKey]) async => {
        'authorization': 'Bearer ${await tokenProvider()}',
        'content-type': 'application/json',
        if (idempotencyKey != null) 'idempotency-key': idempotencyKey,
      };

  @override
  Future<Quote> requestQuote(BookingDraft draft) async {
    final res = await _client
        .post(
          Uri.parse('$baseUrl/v1/quotes'),
          headers: await _headers(),
          body: jsonEncode({
            'property_id': draft.propertyId,
            'service_code': draft.serviceCode,
            'addon_codes': draft.addonCodes.toList(),
            'scheduled_at': draft.scheduledAt!.toUtc().toIso8601String(),
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 201) throw ApiFailure(_detail(res));
    return Quote.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  @override
  Future<PaypalOrder> createPaypalOrder(String quoteId) async {
    final res = await _client
        .post(Uri.parse('$baseUrl/v1/quotes/$quoteId/paypal-order'), headers: await _headers())
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 201) throw ApiFailure(_detail(res));
    return PaypalOrder.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  @override
  Future<ConfirmedBooking> confirm({
    required String quoteId,
    required String paypalOrderId,
    required BookingDraft draft,
    required String idempotencyKey,
  }) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/v1/bookings'),
      // The key is generated once per attempt and reused on retry, so a
      // flaky network can never produce two bookings and two card holds.
      headers: await _headers(idempotencyKey),
      body: jsonEncode({
        'quote_id': quoteId,
        'paypal_order_id': paypalOrderId,
        'special_instructions': draft.specialInstructions,
        'entry_method': draft.entryMethod,
      }),
    );
    if (res.statusCode == 201 || res.statusCode == 200) {
      return ConfirmedBooking.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    }
    if (res.statusCode == 409) throw const QuoteExpired();
    if (res.statusCode == 402) throw CardDeclined(_detail(res));
    throw ApiFailure(_detail(res));
  }

  String _detail(http.Response res) {
    try {
      return (jsonDecode(res.body) as Map<String, dynamic>)['detail'] as String;
    } catch (_) {
      return 'Something went wrong. Try again in a moment.';
    }
  }
}
