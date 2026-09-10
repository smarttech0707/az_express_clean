import 'package:az_express/screens/driver/driver_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  test('camera throttle avoids a command for every close GPS event', () {
    final throttle = DriverMapCameraThrottle(
      minInterval: const Duration(milliseconds: 200),
    );
    final start = DateTime(2026, 1, 1);
    var commands = 0;
    for (var elapsed = 0; elapsed < 1000; elapsed += 20) {
      if (throttle.shouldMove(start.add(Duration(milliseconds: elapsed)))) {
        commands++;
      }
    }
    expect(commands, lessThan(10));
    expect(commands, greaterThan(1));
  });

  test('write throttle keeps the latest eligible movement without every event', () {
    final throttle = DriverMapWriteThrottle(
      minInterval: const Duration(seconds: 5),
      minDistanceMeters: 15,
    );
    final start = DateTime(2026, 1, 1);
    const first = LatLng(6.73, -3.49);

    expect(throttle.shouldWrite(start, first), isTrue);
    expect(
      throttle.shouldWrite(
        start.add(const Duration(seconds: 1)),
        const LatLng(6.73001, -3.49),
      ),
      isFalse,
    );
    expect(
      throttle.shouldWrite(
        start.add(const Duration(seconds: 6)),
        const LatLng(6.7302, -3.49),
      ),
      isTrue,
    );
  });
}
