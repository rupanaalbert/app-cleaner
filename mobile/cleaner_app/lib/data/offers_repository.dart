import 'dart:convert';
import 'package:http/http.dart' as http;

/// An open job offer. Money stays in integer cents all the way to the
/// formatter — no doubles anywhere near a payout.
class JobOffer {
  final String offerId;
  final String bookingId;
  final String serviceCode;
  final String serviceName;
  final DateTime scheduledAt;
  final int durationMin;
  final int payoutCents;
  final double distanceKm;
  final String neighborhood;
  final double lat;
  final double lng;
  final int bedrooms;
  final int bathrooms;
  final int? squareFeet;
  final bool hasPets;
  final DateTime expiresAt;

  const JobOffer({
    required this.offerId,
    required this.bookingId,
    required this.serviceCode,
    required this.serviceName,
    required this.scheduledAt,
    required this.durationMin,
    required this.payoutCents,
    required this.distanceKm,
    required this.neighborhood,
    required this.lat,
    required this.lng,
    required this.bedrooms,
    required this.bathrooms,
    required this.squareFeet,
    required this.hasPets,
    required this.expiresAt,
  });

  bool get isDeepClean => serviceCode == 'deep';
  Duration get remaining => expiresAt.difference(DateTime.now());
  bool get isExpired => remaining.isNegative;

  /// What the cleaner actually earns per hour on site — the number that decides
  /// whether a job is worth taking, and the one the API doesn't send.
  int get hourlyCents => durationMin == 0 ? 0 : (payoutCents * 60 / durationMin).round();

  factory JobOffer.fromJson(Map<String, dynamic> json) {
    final property = json['property'] as Map<String, dynamic>;
    final location = json['approx_location'] as Map<String, dynamic>;
    final service = json['service'] as Map<String, dynamic>;
    return JobOffer(
      offerId: json['offer_id'] as String,
      bookingId: json['booking_id'] as String,
      serviceCode: service['code'] as String,
      serviceName: service['name'] as String,
      scheduledAt: DateTime.parse(json['scheduled_at'] as String).toLocal(),
      durationMin: json['duration_min'] as int,
      payoutCents: json['payout_cents'] as int,
      distanceKm: (json['distance_km'] as num).toDouble(),
      neighborhood: json['neighborhood'] as String,
      lat: (location['lat'] as num).toDouble(),
      lng: (location['lng'] as num).toDouble(),
      bedrooms: property['bedrooms'] as int,
      bathrooms: property['bathrooms'] as int,
      squareFeet: property['square_feet'] as int?,
      hasPets: property['has_pets'] as bool? ?? false,
      expiresAt: DateTime.parse(json['expires_at'] as String).toLocal(),
    );
  }
}

class OfferTaken implements Exception {
  const OfferTaken();
}

class OfferExpired implements Exception {
  const OfferExpired();
}

class ApiFailure implements Exception {
  final String message;
  const ApiFailure(this.message);
  @override
  String toString() => message;
}

/// Thin API client. Kept as an interface so the screen can be driven by a
/// fake in widget tests without a live backend.
abstract class OffersRepository {
  Future<List<JobOffer>> fetchOpenOffers();
  Future<void> accept(String offerId);
  Future<void> decline(String offerId, String reason);
  Future<void> setAvailability(bool online);
}

class HttpOffersRepository implements OffersRepository {
  HttpOffersRepository({required this.baseUrl, required this.tokenProvider, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final Future<String> Function() tokenProvider;
  final http.Client _client;

  Future<Map<String, String>> _headers() async => {
        'authorization': 'Bearer ${await tokenProvider()}',
        'content-type': 'application/json',
      };

  @override
  Future<List<JobOffer>> fetchOpenOffers() async {
    final res = await _client
        .get(Uri.parse('$baseUrl/v1/cleaner/offers'), headers: await _headers())
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiFailure(_detail(res));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['offers'] as List)
        .map((e) => JobOffer.fromJson(e as Map<String, dynamic>))
        .where((o) => !o.isExpired)
        .toList();
  }

  @override
  Future<void> accept(String offerId) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/v1/offers/$offerId/accept'),
      headers: await _headers(),
    );
    if (res.statusCode == 200) return;
    // These two are normal, not errors: another cleaner was faster, or the
    // 90-second window closed. The UI treats them as information.
    if (res.statusCode == 409) throw const OfferTaken();
    if (res.statusCode == 410) throw const OfferExpired();
    throw ApiFailure(_detail(res));
  }

  @override
  Future<void> decline(String offerId, String reason) async {
    await _client.post(
      Uri.parse('$baseUrl/v1/offers/$offerId/decline'),
      headers: await _headers(),
      body: jsonEncode({'reason': reason}),
    );
  }

  @override
  Future<void> setAvailability(bool online) async {
    await _client.patch(
      Uri.parse('$baseUrl/v1/cleaner/availability'),
      headers: await _headers(),
      body: jsonEncode({'is_available': online}),
    );
  }

  String _detail(http.Response res) {
    try {
      return (jsonDecode(res.body) as Map<String, dynamic>)['detail'] as String;
    } catch (_) {
      return 'Something went wrong. Pull down to try again.';
    }
  }
}
