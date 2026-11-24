import 'package:flutter_sound/flutter_sound.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class AudioService {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  String? _currentPath;

  Future<void> startRecording() async {
    await _recorder.openRecorder();
    final dir = await getTemporaryDirectory();
    _currentPath =
        "${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.aac";
    await _recorder.startRecorder(toFile: _currentPath);
  }

  Future<String?> stopRecording(String orderId) async {
    final path = await _recorder.stopRecorder();
    await _recorder.closeRecorder();

    final filePath = path ?? _currentPath;
    if (filePath == null) return null;

    final ref = FirebaseStorage.instance
        .ref()
        .child("voice_messages/$orderId/voice.aac");

    await ref.putFile(
        File(filePath), SettableMetadata(contentType: 'audio/aac'));
    return await ref.getDownloadURL();
  }
}
