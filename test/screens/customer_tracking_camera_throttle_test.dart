import 'package:az_express/screens/customer_tracking_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('camera throttle is much lower than 16ms interpolation ticks', () {
    final throttle = TrackingCameraThrottle(
      minInterval: const Duration(milliseconds: 200),
    );
    final start = DateTime(2026, 1, 1);
    var commands = 0;

    for (var elapsed = 0; elapsed <= 1600; elapsed += 16) {
      if (throttle.shouldMove(
        start.add(Duration(milliseconds: elapsed)),
        force: elapsed >= 1600,
      )) {
        commands++;
      }
    }

    expect(commands, lessThan(12));
    expect(commands, lessThan(1600 ~/ 16));
  });
}
