import 'dart:convert';
import 'package:http/http.dart' as http;

import 'geolocation.dart';

String _serviceName(String code, String? given) =>
    given ?? (code == 'deep' ? 'Deep Clean' : 'Standard Clean');

/// A job on the cleaner's schedule. Money in integer cents, everywhere.
class ScheduledJob {
  final String bookingId;
  final String reference;
  final String serviceCode;
  final String serviceName;
  final DateTime scheduledAt;
  final int durationMin;
  final int payoutCents;
  final String status;

  const ScheduledJob({
    required this.bookingId,
    required this.reference,
    required this.serviceCode,
    required this.serviceName,
    required this.scheduledAt,
    required this.durationMin,
    required this.payoutCents,
    required this.status,
  });

  bool get isDeepClean => serviceCode == 'deep';
  bool get isActive => const {'en_route', 'arrived', 'in_progress'}.contains(status);

  bool get isToday {
    final now = DateTime.now();
    return scheduledAt.year == now.year &&
        scheduledAt.month == now.month &&
        scheduledAt.day == now.day;
  }

  factory ScheduledJob.fromJson(Map<String, dynamic> json) => ScheduledJob(
        bookingId: json['id'] as String,
        reference: json['reference'] as String,
        serviceCode: json['service_code'] as String,
        serviceName: _serviceName(json['service_code'] as String, json['service_name'] as String?),
        scheduledAt: DateTime.parse(json['scheduled_at'] as String).toLocal(),
        durationMin: json['duration_min'] as int,
        payoutCents: json['payout_cents'] as int,
        status: json['status'] as String,
      );
}

/// Everything the active-job screen needs, including the address — which the
/// API reveals only while the job window is open (assigned through 24h after
/// completion). Before that, the address fields come back null and the screen
/// shows the neighbourhood only.
class JobDetail {
  final String bookingId;
  final String reference;
  final String serviceCode;
  final String serviceName;
  final DateTime scheduledAt;
  final int durationMin;
  final int payoutCents;
  final int tipCents;
  final String status;
  final String? specialInstructions;
  final String? line1;
  final String? line2;
  final String? city;
  final String? region;
  final String? postalCode;
  final String? accessNotes;

  const JobDetail({
    required this.bookingId,
    required this.reference,
    required this.serviceCode,
    required this.serviceName,
    required this.scheduledAt,
    required this.durationMin,
    required this.payoutCents,
    required this.tipCents,
    required this.status,
    required this.specialInstructions,
    required this.line1,
    required this.line2,
    required this.city,
    required this.region,
    required this.postalCode,
    required this.accessNotes,
  });

  bool get isDeepClean => serviceCode == 'deep';
  bool get hasAddress => line1 != null && (line1 as String).isNotEmpty;
  String get cityLine =>
      [city, region, postalCode].where((s) => s != null && s.isNotEmpty).join(', ');

  factory JobDetail.fromJson(Map<String, dynamic> json) => JobDetail(
        bookingId: json['id'] as String,
        reference: json['reference'] as String,
        serviceCode: json['service_code'] as String,
        serviceName: _serviceName(json['service_code'] as String, json['service_name'] as String?),
        scheduledAt: DateTime.parse(json['scheduled_at'] as String).toLocal(),
        durationMin: json['duration_min'] as int,
        payoutCents: json['payout_cents'] as int,
        tipCents: json['tip_cents'] as int? ?? 0,
        status: json['status'] as String,
        specialInstructions: json['special_instructions'] as String?,
        line1: json['line1'] as String?,
        line2: json['line2'] as String?,
        city: json['city'] as String?,
        region: json['region'] as String?,
        postalCode: json['postal_code'] as String?,
        accessNotes: json['access_notes'] as String?,
      );
}

/// One presigned S3 target for a job photo. The bytes go straight to S3; the
/// row that satisfies the completion gate is written by the presign call.
class PhotoTarget {
  final String key;
  final String url;
  const PhotoTarget({required this.key, required this.url});

  factory PhotoTarget.fromJson(Map<String, dynamic> json) =>
      PhotoTarget(key: json['key'] as String, url: json['url'] as String);
}

// --- Typed outcomes the UI treats as information, not crashes. ---------------

/// The move isn't legal from the current status — usually a stale screen (the
/// job was canceled, or already advanced elsewhere). The UI reloads.
class IllegalTransition implements Exception {
  final String message;
  const IllegalTransition(this.message);
  @override
  String toString() => message;
}

/// Reported point is outside the geofence around the property.
class GeofenceFailed implements Exception {
  final String message;
  const GeofenceFailed(this.message);
  @override
  String toString() => message;
}

/// A Deep Clean can't be completed without the required after-photos.
class PhotosRequired implements Exception {
  final String message;
  const PhotosRequired(this.message);
  @override
  String toString() => message;
}

/// The status needs a location the request didn't carry.
class LocationRequired implements Exception {
  final String message;
  const LocationRequired(this.message);
  @override
  String toString() => message;
}

class ApiFailure implements Exception {
  final String message;
  const ApiFailure(this.message);
  @override
  String toString() => message;
}

abstract class JobsRepository {
  /// Today and upcoming: the cleaner's assigned and live jobs, soonest first.
  Future<List<ScheduledJob>> schedule();

  /// Full detail for one booking, including the address when the window is open.
  Future<JobDetail> job(String bookingId);

  /// Advance the job. `arrived` and `completed` require a location.
  Future<ScheduledJob> updateStatus(
    String bookingId,
    String status, {
    GeoPoint? location,
    int? actualDurationMin,
  });

  /// Presign N photo uploads for a phase ('before' | 'after').
  Future<List<PhotoTarget>> presignPhotos(String bookingId, String phase, int count);

  /// PUT the image bytes straight to the presigned S3 URL.
  Future<void> uploadPhoto(String uploadUrl, List<int> bytes);
}

class HttpJobsRepository implements JobsRepository {
  HttpJobsRepository({required this.baseUrl, required this.tokenProvider, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final Future<String> Function() tokenProvider;
  final http.Client _client;

  Future<Map<String, String>> _headers() async => {
        'authorization': 'Bearer ${await tokenProvider()}',
        'content-type': 'application/json',
      };

  @override
  Future<List<ScheduledJob>> schedule() async {
    // Two server-side filters, merged: live jobs and still-to-come assignments.
    final lists = await Future.wait([_list('active'), _list('upcoming')]);
    final jobs = [...lists[0], ...lists[1]];
    jobs.sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
    return jobs;
  }

  Future<List<ScheduledJob>> _list(String status) async {
    final res = await _client
        .get(Uri.parse('$baseUrl/v1/bookings?status=$status&limit=50'), headers: await _headers())
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiFailure(_detail(res));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['bookings'] as List)
        .map((e) => ScheduledJob.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<JobDetail> job(String bookingId) async {
    final res = await _client
        .get(Uri.parse('$baseUrl/v1/bookings/$bookingId'), headers: await _headers())
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiFailure(_detail(res));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return JobDetail.fromJson(body['booking'] as Map<String, dynamic>);
  }

  @override
  Future<ScheduledJob> updateStatus(
    String bookingId,
    String status, {
    GeoPoint? location,
    int? actualDurationMin,
  }) async {
    final res = await _client.patch(
      Uri.parse('$baseUrl/v1/bookings/$bookingId/status'),
      headers: await _headers(),
      body: jsonEncode({
        'status': status,
        if (location != null)
          'location': {
            'lat': location.lat,
            'lng': location.lng,
            if (location.accuracyM != null) 'accuracy_m': location.accuracyM,
          },
        if (actualDurationMin != null) 'actual_duration_min': actualDurationMin,
      }),
    );
    if (res.statusCode == 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return ScheduledJob.fromJson(body['booking'] as Map<String, dynamic>);
    }
    final code = _code(res);
    final detail = _detail(res);
    if (res.statusCode == 422 && code == 'GEOFENCE_FAILED') throw GeofenceFailed(detail);
    if (res.statusCode == 422 && code == 'PHOTOS_REQUIRED') throw PhotosRequired(detail);
    if (res.statusCode == 400 && code == 'LOCATION_REQUIRED') throw LocationRequired(detail);
    if (res.statusCode == 409) throw IllegalTransition(detail);
    throw ApiFailure(detail);
  }

  @override
  Future<List<PhotoTarget>> presignPhotos(String bookingId, String phase, int count) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/v1/bookings/$bookingId/photos'),
      headers: await _headers(),
      body: jsonEncode({'phase': phase, 'count': count}),
    );
    if (res.statusCode != 200) throw ApiFailure(_detail(res));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['uploads'] as List)
        .map((e) => PhotoTarget.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<void> uploadPhoto(String uploadUrl, List<int> bytes) async {
    final res = await _client.put(
      Uri.parse(uploadUrl),
      headers: {'content-type': 'image/jpeg'},
      body: bytes,
    );
    if (res.statusCode >= 300) {
      throw const ApiFailure('Photo upload failed. Check your connection and retry.');
    }
  }

  String _code(http.Response res) {
    try {
      return (jsonDecode(res.body) as Map<String, dynamic>)['code'] as String? ?? '';
    } catch (_) {
      return '';
    }
  }

  String _detail(http.Response res) {
    try {
      return (jsonDecode(res.body) as Map<String, dynamic>)['detail'] as String;
    } catch (_) {
      return 'Something went wrong. Try again in a moment.';
    }
  }
}
