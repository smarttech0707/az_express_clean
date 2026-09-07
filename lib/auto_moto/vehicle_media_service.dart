import 'dart:async';
import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import 'models/vehicle_media.dart';

class PendingVehicleMedia {
  const PendingVehicleMedia(
      {required this.id, required this.type, required this.file});

  final String id;
  final VehicleMediaType type;
  final XFile file;
}

class VehicleMediaSelection {
  VehicleMediaSelection({Iterable<VehicleMedia> existing = const []})
      : existing = List.of(existing) {
    final images =
        this.existing.where((item) => item.type == VehicleMediaType.image);
    imageOrder.addAll(images.map((item) => item.id));
    coverMediaId = images.isEmpty ? null : images.first.id;
  }

  final List<VehicleMedia> existing;
  final List<PendingVehicleMedia> pending = [];
  final List<VehicleMedia> removed = [];
  final List<String> imageOrder = [];
  String? coverMediaId;

  int get imageCount =>
      existing.where(_isImage).length + pending.where(_isPendingImage).length;
  int get videoCount =>
      existing.where(_isVideo).length + pending.where(_isPendingVideo).length;

  void add(PendingVehicleMedia media) {
    VehicleMediaService.validateSelection(
      imageCount: imageCount + (media.type == VehicleMediaType.image ? 1 : 0),
      videoCount: videoCount + (media.type == VehicleMediaType.video ? 1 : 0),
    );
    pending.add(media);
    if (media.type == VehicleMediaType.image && coverMediaId == null) {
      coverMediaId = media.id;
    }
    if (media.type == VehicleMediaType.image) imageOrder.add(media.id);
  }

  void removeExisting(String id) {
    final index = existing.indexWhere((item) => item.id == id);
    if (index < 0) return;
    removed.add(existing.removeAt(index));
    imageOrder.remove(id);
    _repairCover();
  }

  void removePending(String id) {
    pending.removeWhere((item) => item.id == id);
    imageOrder.remove(id);
    _repairCover();
  }

  void setCover(String id) {
    final isImage = existing.any((item) => item.id == id && _isImage(item)) ||
        pending.any((item) => item.id == id && _isPendingImage(item));
    if (!isImage) {
      throw const VehicleMediaException('La couverture doit être une photo.');
    }
    coverMediaId = id;
  }

  void reorderImage(int oldIndex, int newIndex) {
    final moved = imageOrder.removeAt(oldIndex);
    imageOrder.insert(newIndex, moved);
  }

  List<Object> get orderedItems {
    final byId = <String, Object>{
      for (final item in existing) item.id: item,
      for (final item in pending) item.id: item,
    };
    return [
      ...imageOrder.map((id) => byId[id]).whereType<Object>(),
      ...existing.where(_isVideo),
      ...pending.where(_isPendingVideo),
    ];
  }

  void _repairCover() {
    final ids = <String>[
      ...existing.where(_isImage).map((item) => item.id),
      ...pending.where(_isPendingImage).map((item) => item.id),
    ];
    if (!ids.contains(coverMediaId)) {
      coverMediaId = ids.isEmpty ? null : ids.first;
    }
  }

  static bool _isImage(VehicleMedia item) =>
      item.type == VehicleMediaType.image;
  static bool _isVideo(VehicleMedia item) =>
      item.type == VehicleMediaType.video;
  static bool _isPendingImage(PendingVehicleMedia item) =>
      item.type == VehicleMediaType.image;
  static bool _isPendingVideo(PendingVehicleMedia item) =>
      item.type == VehicleMediaType.video;
}

typedef VehicleUploadProgress = void Function(double progress);
typedef VehicleMediaUpload = Future<VehicleMedia> Function(
  PendingVehicleMedia media,
  int position,
);
typedef VehicleMediaCleanup = Future<void> Function(
    Iterable<VehicleMedia> media);

class VehicleMediaBatchUploader {
  const VehicleMediaBatchUploader(
      {required this.upload, required this.cleanup});

  final VehicleMediaUpload upload;
  final VehicleMediaCleanup cleanup;

  Future<List<VehicleMedia>> run(
    List<PendingVehicleMedia> pending, {
    int positionOffset = 0,
  }) async {
    final uploaded = <VehicleMedia>[];
    try {
      for (var index = 0; index < pending.length; index++) {
        uploaded.add(await upload(pending[index], positionOffset + index));
      }
      return uploaded;
    } catch (_) {
      await cleanup(uploaded);
      rethrow;
    }
  }
}

class VehicleMediaService {
  VehicleMediaService({FirebaseStorage? storage, Uuid? uuid})
      : _storage = storage ?? FirebaseStorage.instance,
        _uuid = uuid ?? const Uuid();

  static const maxImages = 8;
  static const maxVideos = 1;
  static const maxImageBytes = 5 * 1024 * 1024;
  static const maxVideoBytes = 20 * 1024 * 1024;
  static const maxSellerLogoBytes = 2 * 1024 * 1024;

  final FirebaseStorage _storage;
  final Uuid _uuid;

  String newMediaId() => _uuid.v4();

  Future<({String downloadUrl, String storagePath})> uploadSellerLogo({
    required XFile file,
    required String ownerId,
    required String mediaId,
    VehicleUploadProgress? onProgress,
  }) async {
    final bytes = await file.readAsBytes();
    final detected = _detect(bytes);
    if (detected.type != VehicleMediaType.image) {
      throw const VehicleMediaException('Le logo doit être une image.');
    }
    if (bytes.length > maxSellerLogoBytes) {
      throw const VehicleMediaException(
          'Le logo dépasse 2 Mo après traitement.');
    }
    final path =
        'vehicle_seller_profiles/$ownerId/logo/$mediaId.${detected.extension}';
    final reference = _storage.ref(path);
    final task = reference.putData(
      bytes,
      SettableMetadata(contentType: detected.contentType),
    );
    final subscription = task.snapshotEvents.listen((snapshot) {
      if (snapshot.totalBytes > 0) {
        onProgress?.call(snapshot.bytesTransferred / snapshot.totalBytes);
      }
    });
    try {
      await task.timeout(const Duration(minutes: 2));
      return (
        downloadUrl: await reference
            .getDownloadURL()
            .timeout(const Duration(seconds: 30)),
        storagePath: path,
      );
    } on TimeoutException {
      throw const VehicleMediaException(
          'Le téléchargement a expiré. Réessayez.');
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> deleteSellerLogo(String storagePath, String ownerId) async {
    if (!storagePath.startsWith('vehicle_seller_profiles/$ownerId/logo/')) {
      return;
    }
    await _storage.ref(storagePath).delete();
  }

  static void validateSelection({
    required int imageCount,
    required int videoCount,
  }) {
    if (imageCount > maxImages) {
      throw const VehicleMediaException('Maximum 8 photos par annonce.');
    }
    if (videoCount > maxVideos) {
      throw const VehicleMediaException('Une seule vidéo est autorisée.');
    }
  }

  Future<VehicleMedia> upload({
    required PendingVehicleMedia media,
    required String sellerId,
    required String listingId,
    required int position,
    VehicleUploadProgress? onProgress,
  }) async {
    final bytes = await media.file.readAsBytes();
    final detected = _detect(bytes);
    if (detected.type != media.type) {
      throw const VehicleMediaException('Le contenu du fichier est invalide.');
    }
    final maxBytes =
        media.type == VehicleMediaType.image ? maxImageBytes : maxVideoBytes;
    if (bytes.length > maxBytes) {
      throw VehicleMediaException(media.type == VehicleMediaType.image
          ? 'Cette photo dépasse 5 Mo après traitement.'
          : 'Cette vidéo dépasse 20 Mo.');
    }
    final folder = media.type == VehicleMediaType.image ? 'images' : 'videos';
    final path =
        'vehicle_listings/$sellerId/$listingId/$folder/${media.id}.${detected.extension}';
    final reference = _storage.ref(path);
    final task = reference.putData(
      bytes,
      SettableMetadata(contentType: detected.contentType),
    );
    final subscription = task.snapshotEvents.listen((snapshot) {
      if (snapshot.totalBytes > 0) {
        onProgress?.call(snapshot.bytesTransferred / snapshot.totalBytes);
      }
    });
    try {
      await task.timeout(const Duration(minutes: 2));
      final url = await reference.getDownloadURL().timeout(
            const Duration(seconds: 30),
          );
      return VehicleMedia(
        id: media.id,
        type: media.type,
        storagePath: path,
        downloadUrl: url,
        position: position,
      );
    } on TimeoutException {
      throw const VehicleMediaException(
          'Le téléchargement a expiré. Réessayez.');
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> deleteByPath(String storagePath) async {
    if (!storagePath.startsWith('vehicle_listings/')) return;
    await _storage.ref(storagePath).delete();
  }

  Future<void> cleanup(Iterable<VehicleMedia> media) async {
    for (final item in media) {
      try {
        await deleteByPath(item.storagePath);
      } catch (_) {}
    }
  }

  static ({VehicleMediaType type, String contentType, String extension})
      _detect(
    Uint8List bytes,
  ) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return (
        type: VehicleMediaType.image,
        contentType: 'image/jpeg',
        extension: 'jpg'
      );
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return (
        type: VehicleMediaType.image,
        contentType: 'image/png',
        extension: 'png'
      );
    }
    if (bytes.length >= 12 &&
        bytes[4] == 0x66 &&
        bytes[5] == 0x74 &&
        bytes[6] == 0x79 &&
        bytes[7] == 0x70) {
      return (
        type: VehicleMediaType.video,
        contentType: 'video/mp4',
        extension: 'mp4'
      );
    }
    throw const VehicleMediaException('Format accepté : JPEG, PNG ou MP4.');
  }
}

class VehicleMediaException implements Exception {
  const VehicleMediaException(this.message);
  final String message;
  @override
  String toString() => message;
}
