import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

Future<String> saveQr(Uint8List bytes) async {
  final directory = await getApplicationDocumentsDirectory();
  final file = File(
      '${directory.path}/az-express-qr-${DateTime.now().microsecondsSinceEpoch}.png');
  await file.writeAsBytes(bytes, flush: true);
  return 'PNG enregistre : ${file.path}. Utilisez Partager pour exporter vers Fichiers ou WhatsApp.';
}
