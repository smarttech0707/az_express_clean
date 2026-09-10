import 'package:az_express/widgets/live_marker_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

Marker marker(String id, double latitude) => Marker(
      markerId: MarkerId(id),
      position: LatLng(latitude, -3.49),
    );

void main() {
  test('applies added modified removed and invalid marker changes incrementally', () {
    final initial = applyLiveMarkerChanges({}, [
      LiveMarkerChange('a', LiveMarkerChangeType.added, marker: marker('a', 6.7)),
      LiveMarkerChange('b', LiveMarkerChangeType.added, marker: marker('b', 6.8)),
      LiveMarkerChange('c', LiveMarkerChangeType.added, marker: marker('c', 6.9)),
    ]);
    final unchangedA = initial['a'];
    final updated = applyLiveMarkerChanges(initial, [
      LiveMarkerChange('b', LiveMarkerChangeType.modified, marker: marker('b', 7.0)),
      LiveMarkerChange('d', LiveMarkerChangeType.added, marker: marker('d', 7.1)),
      const LiveMarkerChange('c', LiveMarkerChangeType.removed),
      const LiveMarkerChange('missing', LiveMarkerChangeType.modified),
    ]);
    expect(initial, hasLength(3));
    expect(updated, hasLength(3));
    expect(updated['a'], same(unchangedA));
    expect(updated['b']!.position.latitude, 7.0);
    expect(updated.containsKey('c'), isFalse);
    expect(updated.containsKey('missing'), isFalse);
    expect(updated.containsKey('d'), isTrue);
  });
}
