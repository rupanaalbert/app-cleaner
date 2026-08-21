import 'dart:async';
import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

/// Publishes the cleaner's position while a job is `en_route`.
///
/// Two cadences, on purpose:
///   - every ~10 s to Firebase, so the customer's map moves smoothly. This
///     never touches our API; the rules already scope the path to this booking.
///   - every 60 s to the backend as a coarse breadcrumb, which is the trail
///     that survives for disputes. Everything else is discarded.
///
/// The stream starts at "En route" and is torn down at "Arrived" — the app
/// stops tracking before the cleaner walks in the door, and the Firebase rules
/// reject writes past that point anyway. Belt and braces, because a location
/// leak here is the kind of incident a marketplace does not recover from.
class LocationPublisher {
  LocationPublisher({
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

  StreamSubscription<Position>? _positions;
  Timer? _breadcrumbTimer;
  Position? _latest;
  String? _bookingId;

  bool get isPublishing => _bookingId != null;

  /// Returns false if the cleaner declined location — the caller should then
  /// explain why the job can't be started rather than failing silently.
  Future<bool> start(String bookingId) async {
    if (!await _ensurePermission()) return false;
    await stop();

    _bookingId = bookingId;
    final ref = _db.ref('tracking/$bookingId');

    _positions = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 25, // metres — no writes while sitting at a red light
        timeLimit: null,
      ),
    ).listen((position) {
      _latest = position;
      ref.set({
        'lat': position.latitude,
        'lng': position.longitude,
        'heading': position.heading.isNaN ? 0 : position.heading,
        'accuracy_m': position.accuracy,
        'updated_at': ServerValue.timestamp,
      });
    }, onError: (Object _) {
      // A dropped GPS fix is normal in a parking garage. The customer app
      // shows "location paused" from the stale timestamp; nothing to do here.
    });

    // set() overwrites a single node rather than pushing history, so this path
    // never grows — one document per active booking, removed on arrival.
    _breadcrumbTimer = Timer.periodic(const Duration(seconds: 60), (_) => _sendBreadcrumb());
    return true;
  }

  Future<void> stop() async {
    await _positions?.cancel();
    _positions = null;
    _breadcrumbTimer?.cancel();
    _breadcrumbTimer = null;
    if (_bookingId != null) {
      await _db.ref('tracking/$_bookingId').remove();
    }
    _bookingId = null;
    _latest = null;
  }

  Future<void> _sendBreadcrumb() async {
    final position = _latest;
    final bookingId = _bookingId;
    if (position == null || bookingId == null) return;
    try {
      await _client.post(
        Uri.parse('$baseUrl/v1/bookings/$bookingId/breadcrumb'),
        headers: {
          'authorization': 'Bearer ${await tokenProvider()}',
          'content-type': 'application/json',
        },
        body: jsonEncode({'lat': position.latitude, 'lng': position.longitude}),
      );
    } catch (_) {
      // Best effort. A missing breadcrumb is a weaker dispute record, not a
      // broken job — never block the cleaner's work on this call.
    }
  }

  /// The position the app sends with `arrived` and `completed`, which the
  /// backend geofences against the property.
  Future<Position> currentPosition() =>
      Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.best);

  Future<bool> _ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  Future<void> dispose() => stop();
}
