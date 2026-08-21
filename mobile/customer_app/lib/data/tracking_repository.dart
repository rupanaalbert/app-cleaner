import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;

/// A single position update from the cleaner's phone.
class TrackingPing {
  final double lat;
  final double lng;
  final double? heading;
  final int? etaMinutes;
  final DateTime updatedAt;

  const TrackingPing({
    required this.lat,
    required this.lng,
    required this.updatedAt,
    this.heading,
    this.etaMinutes,
  });

  /// Pings older than a minute mean the cleaner's phone lost signal. Say that
  /// rather than leaving a stale dot on the map implying live movement.
  bool get isStale => DateTime.now().difference(updatedAt) > const Duration(seconds: 60);

  factory TrackingPing.fromMap(Map<Object?, Object?> map) => TrackingPing(
        lat: (map['lat'] as num).toDouble(),
        lng: (map['lng'] as num).toDouble(),
        heading: (map['heading'] as num?)?.toDouble(),
        etaMinutes: (map['eta_minutes'] as num?)?.round(),
        updatedAt: DateTime.fromMillisecondsSinceEpoch((map['updated_at'] as num).toInt()),
      );
}

class BookingProgress {
  final String status;
  final String? cleanerName;
  final String? cleanerAvatarUrl;
  final double? cleanerRating;
  final int cleanerJobsCompleted;
  final DateTime scheduledAt;
  final DateTime? enRouteAt;
  final DateTime? arrivedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final double propertyLat;
  final double propertyLng;

  const BookingProgress({
    required this.status,
    required this.scheduledAt,
    required this.propertyLat,
    required this.propertyLng,
    this.cleanerName,
    this.cleanerAvatarUrl,
    this.cleanerRating,
    this.cleanerJobsCompleted = 0,
    this.enRouteAt,
    this.arrivedAt,
    this.startedAt,
    this.completedAt,
  });

  bool get isTrackable => status == 'en_route';
  bool get hasCleaner => cleanerName != null;

  static DateTime? _at(Map<String, dynamic> m, String key) =>
      m[key] == null ? null : DateTime.parse(m[key] as String).toLocal();

  factory BookingProgress.fromJson(Map<String, dynamic> json) {
    final b = json['booking'] as Map<String, dynamic>;
    return BookingProgress(
      status: b['status'] as String,
      cleanerName: b['cleaner_name'] as String?,
      cleanerAvatarUrl: b['cleaner_avatar'] as String?,
      cleanerRating: (b['cleaner_rating'] as num?)?.toDouble(),
      cleanerJobsCompleted: (b['cleaner_jobs_completed'] as num?)?.toInt() ?? 0,
      scheduledAt: DateTime.parse(b['scheduled_at'] as String).toLocal(),
      enRouteAt: _at(b, 'en_route_at'),
      arrivedAt: _at(b, 'arrived_at'),
      startedAt: _at(b, 'started_at'),
      completedAt: _at(b, 'completed_at'),
      propertyLat: (b['property_lat'] as num).toDouble(),
      propertyLng: (b['property_lng'] as num).toDouble(),
    );
  }
}

class MaskedCall {
  final String proxyNumber;
  const MaskedCall(this.proxyNumber);
}

abstract class TrackingRepository {
  Future<BookingProgress> loadProgress(String bookingId);
  Stream<TrackingPing> watchLocation(String bookingId);
  Stream<String> watchStatus(String bookingId);
  Future<MaskedCall> openCall(String bookingId);
}

class FirebaseTrackingRepository implements TrackingRepository {
  FirebaseTrackingRepository({
    required this.baseUrl,
    required this.tokenProvider,
    FirebaseDatabase? database,
    http.Client? client,
  })  : _db = database ?? FirebaseDatabase.instance,
        _client = client ?? http.Client();

  final String baseUrl;
  final Future<String> Function() tokenProvider;
  final FirebaseDatabase _db;
  final http.Client _client;

  Future<Map<String, String>> _headers() async => {
        'authorization': 'Bearer ${await tokenProvider()}',
        'content-type': 'application/json',
      };

  @override
  Future<BookingProgress> loadProgress(String bookingId) async {
    final res = await _client.get(
      Uri.parse('$baseUrl/v1/bookings/$bookingId'),
      headers: await _headers(),
    );
    if (res.statusCode != 200) throw Exception('Could not load this booking.');
    return BookingProgress.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// The live stream. This never touches our API — Firebase rules already
  /// restrict this path to the booking's customer, and a 10-second write
  /// cadence has no business hitting Express.
  @override
  Stream<TrackingPing> watchLocation(String bookingId) => _db
      .ref('tracking/$bookingId')
      .onValue
      .where((event) => event.snapshot.value != null)
      .map((event) => TrackingPing.fromMap(event.snapshot.value! as Map<Object?, Object?>));

  @override
  Stream<String> watchStatus(String bookingId) => _db
      .ref('booking_access/$bookingId/status')
      .onValue
      .where((event) => event.snapshot.value != null)
      .map((event) => event.snapshot.value! as String);

  @override
  Future<MaskedCall> openCall(String bookingId) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/v1/bookings/$bookingId/call'),
      headers: await _headers(),
    );
    if (res.statusCode != 200) throw Exception('Could not start the call right now.');
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return MaskedCall(body['proxy_number'] as String);
  }
}

/// Straight-line fallback ETA, used only until the cleaner's app publishes a
/// road-distance figure. Deliberately pessimistic on speed — an ETA that slips
/// is worse than one that lands early.
int estimateEtaMinutes(TrackingPing ping, double destLat, double destLng) {
  if (ping.etaMinutes != null) return ping.etaMinutes!;
  const earthKm = 6371.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(destLat - ping.lat);
  final dLng = rad(destLng - ping.lng);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(ping.lat)) * math.cos(rad(destLat)) * math.sin(dLng / 2) * math.sin(dLng / 2);
  final km = earthKm * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return math.max(1, (km / 28 * 60).round()); // 28 km/h effective city speed
}
