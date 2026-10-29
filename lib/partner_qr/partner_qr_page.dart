import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'save_qr.dart';

Future<Uint8List> renderPartnerQrPng(String url) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
  canvas.translate(64, 64);
  QrPainter(
          data: url,
          version: QrVersions.auto,
          errorCorrectionLevel: QrErrorCorrectLevel.M,
          gapless: true)
      .paint(canvas, const Size(1024, 1024));
  final picture = recorder.endRecording();
  final image = await picture.toImage(1152, 1152);
  picture.dispose();
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw StateError('PNG unavailable');
    }
    return data.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

class PartnerQrPage extends StatefulWidget {
  final String kind;
  final String establishmentId;
  const PartnerQrPage(
      {super.key, required this.kind, required this.establishmentId});
  @override
  State<PartnerQrPage> createState() => _PartnerQrPageState();
}

class _PartnerQrPageState extends State<PartnerQrPage> {
  late Future<Map<String, dynamic>> result = _load();
  bool busy = false;
  Future<Map<String, dynamic>> _load() async {
    final response = await FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('getPartnerQr')
        .call({'kind': widget.kind, 'establishmentId': widget.establishmentId});
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<void> _export(String url, bool share) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final bytes = await renderPartnerQrPng(url);
      if (!mounted) return;
      if (share) {
        final box = context.findRenderObject() as RenderBox?;
        await Share.shareXFiles([
          XFile.fromData(bytes,
              mimeType: 'image/png', name: 'az-express-qr.png')
        ],
            text: url,
            sharePositionOrigin:
                box == null ? null : box.localToGlobal(Offset.zero) & box.size);
      } else {
        final message = await saveQr(bytes);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(message)));
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Export non confirme. Reessayez.')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Mon QR code')),
      body: FutureBuilder<Map<String, dynamic>>(
          future: result,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('QR indisponible ou etablissement non autorise.'),
                TextButton(
                    onPressed: () => setState(() => result = _load()),
                    child: const Text('Reessayer'))
              ]));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final data = snapshot.data!, url = data['url'] as String;
            return SingleChildScrollView(
                child: Center(
                    child: Column(children: [
              Text(data['name'] as String),
              QrImageView(
                  data: url,
                  size: 280,
                  backgroundColor: Colors.white,
                  padding: const EdgeInsets.all(20)),
              const Text(
                  'Identification publique. Ne valide aucune livraison.'),
              SelectableText(url),
              ElevatedButton(
                  onPressed: busy ? null : () => _export(url, false),
                  child: const Text('Telecharger PNG')),
              ElevatedButton(
                  onPressed: busy ? null : () => _export(url, true),
                  child: const Text('Partager')),
            ])));
          }));
}

class PublicPartnerPage extends StatefulWidget {
  final String token;
  final Future<Map<String, dynamic>> Function(String)? load;
  const PublicPartnerPage({super.key, required this.token, this.load});
  @override
  State<PublicPartnerPage> createState() => _PublicPartnerPageState();
}

class _PublicPartnerPageState extends State<PublicPartnerPage> {
  late final Future<Map<String, dynamic>> result =
      widget.load != null ? widget.load!(widget.token) : _load();
  Future<Map<String, dynamic>> _load() async {
    final response = await FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('resolvePartnerQr')
        .call({'token': widget.token});
    return Map<String, dynamic>.from(response.data as Map);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('AZ Express')),
      body: FutureBuilder<Map<String, dynamic>>(
          future: result,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Center(
                  child:
                      Text('Verification indisponible. Reessayez plus tard.'));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final data = snapshot.data!;
            if (data['available'] != true) {
              return const Center(
                  child: Text(
                      'Etablissement indisponible, suspendu ou supprime.'));
            }
            return Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(data['name'] as String),
              Text(data['kind'] as String),
              const Text(
                  'Cette fiche identifie un etablissement, pas une preuve de livraison.'),
              TextButton(
                  onPressed: () => launchUrl(
                      Uri.parse('https://az-express-b0469.web.app/connexion')),
                  child: const Text('Acceder a AZ Express sur le Web')),
              TextButton(
                  onPressed: () => launchUrl(Uri.parse(
                      'https://az-express-b0469.web.app/telecharger/')),
                  child: const Text('Telecharger AZ Express pour Android')),
              const Text('iPhone : application en cours de validation Apple. Telechargement pas encore confirme.'),
            ]));
          }));
}

class AdminPartnerQrPage extends StatefulWidget {
  const AdminPartnerQrPage({super.key});
  @override
  State<AdminPartnerQrPage> createState() => _AdminPartnerQrPageState();
}

class _AdminPartnerQrPageState extends State<AdminPartnerQrPage> {
  final id = TextEditingController();
  final manager = TextEditingController();
  bool saving = false;
  Future<void> setManager(bool active) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('setPartnerQrManager')
          .call({
        'kind': kind,
        'establishmentId': id.text.trim(),
        'uid': manager.text.trim(),
        'active': active
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Autorisation QR mise a jour.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Modification non confirmee. Verifiez les identifiants et vos droits.')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  String kind = 'restaurant';
  @override
  void dispose() {
    id.dispose();
    manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('QR des etablissements')),
      body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            DropdownButton<String>(
                value: kind,
                items: const [
                  'restaurant',
                  'seller',
                  'pharmacie',
                  'boulangerie'
                ]
                    .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => kind = v);
                }),
            TextField(
                controller: id,
                decoration: const InputDecoration(
                    labelText: 'Identifiant de l’etablissement')),
            ElevatedButton(
                onPressed: () {
                  if (id.text.trim().isNotEmpty) {
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => PartnerQrPage(
                            kind: kind, establishmentId: id.text.trim())));
                  }
                },
                child: const Text('Afficher le QR')),
            TextField(
                controller: manager,
                decoration: const InputDecoration(
                    labelText: 'UID Firebase du gestionnaire QR')),
            const Text(
                'Cette autorisation donne acces au QR uniquement, pas aux commandes ni au wallet.'),
            TextButton(
                onPressed: saving ? null : () => setManager(true),
                child: const Text('Autoriser ce gestionnaire')),
            TextButton(
                onPressed: saving ? null : () => setManager(false),
                child: const Text('Revoquer cette autorisation QR')),
          ])));
}

class PartnerQrEstablishmentsPage extends StatefulWidget {
  final Future<List<dynamic>> Function()? loader;
  const PartnerQrEstablishmentsPage({super.key,this.loader});
  @override
  State<PartnerQrEstablishmentsPage> createState() =>
      _PartnerQrEstablishmentsPageState();
}

class _PartnerQrEstablishmentsPageState
    extends State<PartnerQrEstablishmentsPage> {
  late Future<List<dynamic>> result = load();
  Future<List<dynamic>> load() async {
    if(widget.loader!=null){return widget.loader!();}
    final r = await FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('listPartnerQrEstablishments')
        .call();
    return List<dynamic>.from(r.data['establishments'] as List);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Mes etablissements')),
      body: FutureBuilder<List<dynamic>>(
          future: result,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                  child: TextButton(
                      onPressed: () => setState(() => result = load()),
                      child: const Text('Liste indisponible. Reessayer')));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.data!.isEmpty) {
              return const Center(
                  child: Text(
                      'Aucun etablissement autorise. Contactez l’administrateur.'));
            }
            return ListView(
                children: snapshot.data!
                    .map((entry) => ListTile(
                        title: Text(entry['name'] as String),
                        subtitle: Text(
                            '${entry['kind']} — ${entry['establishmentId']}'),
                        trailing: const Icon(Icons.qr_code),
                        enabled: entry['available'] == true,
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => PartnerQrPage(
                                    kind: entry['kind'] as String,
                                    establishmentId:
                                        entry['establishmentId'] as String)))))
                    .toList());
          }));
}
