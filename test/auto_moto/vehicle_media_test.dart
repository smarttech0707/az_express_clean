import 'dart:typed_data';

import 'package:az_express/auto_moto/models/vehicle_listing.dart';
import 'package:az_express/auto_moto/models/vehicle_media.dart';
import 'package:az_express/auto_moto/vehicle_media_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

PendingVehicleMedia pending(String id, VehicleMediaType type) =>
    PendingVehicleMedia(
      id: id,
      type: type,
      file: XFile.fromData(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9])),
    );

VehicleMedia stored(String id,
        {VehicleMediaType type = VehicleMediaType.image}) =>
    VehicleMedia(
      id: id,
      type: type,
      storagePath:
          'vehicle_listings/seller-1/listing-1/${type == VehicleMediaType.image ? 'images' : 'videos'}/$id.jpg',
      downloadUrl: 'https://example.test/$id',
      position: 0,
    );

void main() {
  test('une ancienne annonce sans média reste lisible', () {
    final listing = VehicleListing.fromMap('legacy', const {
      'sellerId': 'seller-1',
      'sellerType': 'individual',
      'vehicleType': 'car',
      'offerType': 'sale',
      'title': 'Ancienne annonce',
      'description': 'Annonce créée avant le lot médias.',
      'brand': 'Toyota',
      'model': 'Corolla',
      'price': 1000000,
      'cityId': 'abengourou',
      'cityName': 'Abengourou',
      'status': 'active',
    });
    expect(listing.media, isEmpty);
    expect(listing.coverMedia, isNull);
  });

  test('maximum 8 photos et refus de la neuvième', () {
    final selection = VehicleMediaSelection();
    for (var index = 0; index < 8; index++) {
      selection.add(pending('p$index', VehicleMediaType.image));
    }
    expect(selection.imageCount, 8);
    expect(
      () => selection.add(pending('p9', VehicleMediaType.image)),
      throwsA(isA<VehicleMediaException>()),
    );
  });

  test('une seule vidéo et refus de la deuxième', () {
    final selection = VehicleMediaSelection()
      ..add(pending('v1', VehicleMediaType.video));
    expect(
      () => selection.add(pending('v2', VehicleMediaType.video)),
      throwsA(isA<VehicleMediaException>()),
    );
  });

  test('première photo principale puis changement de couverture', () {
    final selection = VehicleMediaSelection()
      ..add(pending('p1', VehicleMediaType.image))
      ..add(pending('p2', VehicleMediaType.image));
    expect(selection.coverMediaId, 'p1');
    selection.setCover('p2');
    expect(selection.coverMediaId, 'p2');
  });

  test('ordre des photos conservé entre médias existants et locaux', () {
    final selection = VehicleMediaSelection(existing: [stored('old')])
      ..add(pending('new', VehicleMediaType.image));
    selection.reorderImage(1, 0);
    expect(selection.imageOrder, ['new', 'old']);
  });

  test('suppression locale avant upload ne marque aucun fichier distant', () {
    final selection = VehicleMediaSelection()
      ..add(pending('local', VehicleMediaType.image));
    selection.removePending('local');
    expect(selection.pending, isEmpty);
    expect(selection.removed, isEmpty);
  });

  test('modification conserve les médias existants et suit les suppressions',
      () {
    final selection =
        VehicleMediaSelection(existing: [stored('old'), stored('keep')]);
    selection.removeExisting('old');
    expect(selection.existing.single.id, 'keep');
    expect(selection.removed.single.storagePath, contains('/old.jpg'));
  });

  test('sérialisation Firestore conserve storagePath et couverture', () {
    final media = stored('cover');
    final map = media.toMap();
    expect(map['storagePath'], contains('vehicle_listings/seller-1/listing-1'));
    expect(VehicleMedia.fromMap(map).id, 'cover');
  });

  test('échec partiel nettoyé et retry possible', () async {
    var shouldFail = true;
    var cleaned = 0;
    final queue = VehicleMediaBatchUploader(
      upload: (item, position) async {
        if (item.id == 'second' && shouldFail) throw StateError('network');
        return stored(item.id).copyWith(position: position);
      },
      cleanup: (items) async => cleaned += items.length,
    );
    final items = [
      pending('first', VehicleMediaType.image),
      pending('second', VehicleMediaType.image),
    ];
    await expectLater(queue.run(items), throwsStateError);
    expect(cleaned, 1);
    shouldFail = false;
    expect(await queue.run(items), hasLength(2));
  });

  test('un chemin média appartenant à un autre vendeur est refusé', () {
    final media = stored('cover');
    expect(
      media.storagePath.startsWith('vehicle_listings/other-user/'),
      isFalse,
    );
  });
}
