import 'package:az_express/services/tracking_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  testWidgets('animates intermediate positions and reaches the exact target',
      (tester) async {
    final service = TrackingService(
      driverId: '',
      clientPosition: const LatLng(6.73, -3.49),
    );
    final positions = <LatLng>[];
    service.addListener(() {
      final position = service.state.driverPosition;
      if (position != null) positions.add(position);
    });

    const start = LatLng(6.73, -3.49);
    const target = LatLng(6.74, -3.48);
    service.debugStartVisualTransition(from: start, to: target);

    await tester.pump(const Duration(milliseconds: 16));
    expect(positions, isNotEmpty);
    expect(service.state.driverPosition, isNot(start));
    expect(service.state.driverPosition, isNot(target));
    expect(service.routeRevision, 0);

    for (var i = 1; i < 63; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Timer.periodic dépend du scheduler : 1 000 / 16 donne environ 63 ticks,
    // avec une petite variation admissible autour de cette valeur.
    expect(positions.length, inInclusiveRange(60, 70));
    expect(service.state.driverPosition, target);
    expect(service.isAnimating, isFalse);
    final notificationsAtEnd = positions.length;
    await tester.pump(const Duration(milliseconds: 64));
    expect(positions.length, notificationsAtEnd);
    service.dispose();
  });

  testWidgets('dispose stops the animation timer', (tester) async {
    final service = TrackingService(
      driverId: '',
      clientPosition: const LatLng(6.73, -3.49),
    );
    var notifications = 0;
    service.addListener(() => notifications++);
    service.debugStartVisualTransition(
      from: const LatLng(6.73, -3.49),
      to: const LatLng(6.74, -3.48),
    );

    await tester.pump(const Duration(milliseconds: 16));
    service.dispose();
    final notificationsAtDispose = notifications;
    await tester.pump(const Duration(seconds: 2));
    expect(notifications, notificationsAtDispose);
  });
}
