enum VehicleMediaType { image, video, unknown }

VehicleMediaType vehicleMediaTypeFromFirestore(Object? value) =>
    switch (value) {
      'image' => VehicleMediaType.image,
      'video' => VehicleMediaType.video,
      _ => VehicleMediaType.unknown,
    };

extension VehicleMediaTypeFirestore on VehicleMediaType {
  String toFirestore() => switch (this) {
        VehicleMediaType.image => 'image',
        VehicleMediaType.video => 'video',
        VehicleMediaType.unknown => throw StateError('Type de média inconnu'),
      };
}

class VehicleMedia {
  const VehicleMedia({
    required this.id,
    required this.type,
    required this.storagePath,
    required this.downloadUrl,
    required this.position,
    this.thumbnailUrl,
  });

  final String id;
  final VehicleMediaType type;
  final String storagePath;
  final String downloadUrl;
  final int position;
  final String? thumbnailUrl;

  factory VehicleMedia.fromMap(Map<String, dynamic> data) => VehicleMedia(
        id: data['id'] as String? ?? '',
        type: vehicleMediaTypeFromFirestore(data['type']),
        storagePath: data['storagePath'] as String? ?? '',
        downloadUrl: data['downloadUrl'] as String? ?? '',
        thumbnailUrl: data['thumbnailUrl'] as String?,
        position: (data['position'] as num? ?? 0).toInt(),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'type': type.toFirestore(),
        'storagePath': storagePath,
        'downloadUrl': downloadUrl,
        if (thumbnailUrl != null && thumbnailUrl!.isNotEmpty)
          'thumbnailUrl': thumbnailUrl,
        'position': position,
      };

  VehicleMedia copyWith({int? position}) => VehicleMedia(
        id: id,
        type: type,
        storagePath: storagePath,
        downloadUrl: downloadUrl,
        thumbnailUrl: thumbnailUrl,
        position: position ?? this.position,
      );
}
