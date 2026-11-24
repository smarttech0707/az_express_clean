// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';

Future<String> saveQr(Uint8List bytes) async {
  final url = html.Url.createObjectUrlFromBlob(html.Blob([bytes], 'image/png'));
  final anchor = html.AnchorElement(href: url)..download = 'az-express-qr.png';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  await Future<void>.delayed(const Duration(seconds: 1));
  html.Url.revokeObjectUrl(url);
  return 'Telechargement PNG demande au navigateur.';
}
