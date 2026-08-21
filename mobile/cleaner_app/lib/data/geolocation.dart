import 'package:geolocator/geolocator.dart';

/// A single position fix. The backend geofences `arrived` and `completed`
/// against the property, so these two transitions must carry a real point.
class GeoPoint {
  final double lat;
  final double lng;
  final double? accuracyM;
  const GeoPoint(this.lat, this.lng, {this.accuracyM});
}

/// Raised when we can't get a fix — services off, or permission refused. The
/// caller turns this into an explanation, never a silent failure: a cleaner
/// standing on the doorstep needs to know *why* the button won't advance.
class LocationUnavailable implements Exception {
  final String message;
  const LocationUnavailable(this.message);
  @override
  String toString() => message;
}

/// Point-in-time location, behind an interface so screens can be driven by a
/// fake — the same reason the repositories are interfaces.
abstract class Locator {
  Future<GeoPoint> current();
}

class GeolocatorLocator implements Locator {
  const GeolocatorLocator();

  @override
  Future<GeoPoint> current() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationUnavailable('Turn on location services to update your status.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      throw const LocationUnavailable(
          'Location permission is needed to confirm you\'re at the property.');
    }
    final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.best);
    return GeoPoint(pos.latitude, pos.longitude, accuracyM: pos.accuracy);
  }
}

/// Fixed fix for fakes and widget tests. Defaults to the seed's Methuen point.
class FakeLocator implements Locator {
  const FakeLocator({this.point = const GeoPoint(42.7262, -71.1909, accuracyM: 8)});
  final GeoPoint point;

  @override
  Future<GeoPoint> current() async => point;
}
