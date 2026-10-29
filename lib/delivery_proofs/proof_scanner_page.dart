import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'delivery_proof_service.dart';
import '../partner_qr/partner_qr_link.dart';
import '../partner_qr/partner_qr_page.dart';

/// Returns a credential to the existing confirmation flow. Never writes an order.
class ProofScannerPage extends StatefulWidget {
  final String orderId, type;
  const ProofScannerPage(
      {super.key, required this.orderId, required this.type});
  @override
  State<ProofScannerPage> createState() => _ProofScannerPageState();
}

class _ProofScannerPageState extends State<ProofScannerPage> {
  final pin = TextEditingController();
  String? error;
  bool camera = false, done = false;
  Future<void> identifyPartner(String token) async {
    if(done)return;
    setState((){done=true;camera=false;});
    await Navigator.of(context).push(MaterialPageRoute(builder:(_)=>PublicPartnerPage(token:token)));
    if(mounted){setState((){done=false;error='Etablissement identifie uniquement. Le code de cette commande reste obligatoire pour confirmer.';});}
  }
  void accept(ProofCredential credential) {
    if (done) return;
    done = true;
    Navigator.pop(context, credential);
  }

  @override
  void dispose() {
    pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Scanner le QR code')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          Text(widget.type == 'pickup'
              ? 'Code présenté par le partenaire ou l’expéditeur'
              : 'Code présenté par le destinataire'),
          if (camera)
            SizedBox(
                height: 260,
                child: MobileScanner(
                  onDetect: (capture) {
                    if (done) return;
                    for (final barcode in capture.barcodes) {
                      final raw = barcode.rawValue;
                      if (raw == null) continue;
                      final publicToken=partnerQrToken(raw);
                      if(publicToken!=null){identifyPartner(publicToken);break;}
                      try {
                        accept(ProofCredential.parse(
                            raw, widget.orderId, widget.type));
                      } catch (_) {
                        setState(() => error =
                            'QR invalide pour cette commande ou cette étape.');
                      }
                      break;
                    }
                  },
                  errorBuilder: (_, __) => const Center(
                      child: Text(
                          'Caméra indisponible ou permission refusée. Utilisez le PIN.')),
                ))
          else
            FilledButton.icon(
                onPressed: () => setState(() => camera = true),
                icon: const Icon(Icons.camera_alt),
                label: const Text('Ouvrir la caméra')),
          TextField(
              controller: pin,
              keyboardType: TextInputType.number,
              maxLength: 6,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'PIN de secours')),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
          FilledButton(
              onPressed: () {
                if (!RegExp(r'^\d{6}$').hasMatch(pin.text)) {
                  setState(() => error = 'Saisissez les 6 chiffres.');
                  return;
                }
                accept(ProofCredential(pin: pin.text));
              },
              child: const Text('Utiliser ce PIN')),
          const Text(
              'La confirmation sera vérifiée par le serveur. Ne demandez pas le code avant la remise effective.'),
        ]),
      );
}
