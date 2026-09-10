import 'package:az_express/services/realtime_tracking_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  group('RealtimeTrackingService visual interpolation', () {
    test('emits intermediate positions and reaches the exact target',
        () async {
      final service = RealtimeTrackingService(
        driverId: '',
        clientPosition: const LatLng(6.73, -3.49),
      );
      final positions = <LatLng>[];
      service.addListener(() {
        final position = service.animatedDriverPos;
        if (position != null) positions.add(position);
      });

      const target = LatLng(6.74, -3.48);
      service.debugStartVisualTransition(
        from: const LatLng(6.73, -3.49),
        to: target,
        fromHeading: 10,
        toHeading: 90,
      );

      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(positions, isNotEmpty);
      expect(service.animatedDriverPos, isNot(target));
      expect(service.routeRevision, 0);

      await Future<void>.delayed(const Duration(milliseconds: 1000));
      expect(positions.length, greaterThan(2));
      expect(service.animatedDriverPos, target);
      expect(service.isAnimating, isFalse);
      final notificationsAtEnd = positions.length;
      await Future<void>.delayed(const Duration(milliseconds: 64));
      expect(positions.length, notificationsAtEnd);
      service.dispose();
    });

    test('dispose stops the visual timer and later notifications', () async {
      final service = RealtimeTrackingService(
        driverId: '',
        clientPosition: const LatLng(6.73, -3.49),
      );
      var notifications = 0;
      service.addListener(() => notifications++);
      service.debugStartVisualTransition(
        from: const LatLng(6.73, -3.49),
        to: const LatLng(6.74, -3.48),
      );

      await Future<void>.delayed(const Duration(milliseconds: 80));
      service.dispose();
      final countAtDispose = notifications;
      await Future<void>.delayed(const Duration(milliseconds: 64));

      expect(notifications, countAtDispose);
    });
  });
}
