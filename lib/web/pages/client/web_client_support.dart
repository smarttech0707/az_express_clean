import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../constants/app_constants.dart';
import '../../../constants/support_categories.dart';
// Fonction pure, réutilisée telle quelle (mobile et web doivent produire
// exactement le même document) — aucune dépendance `dart:io` dans ce
// fichier, donc sans risque de compilation pour le web.
import '../../../screens/support/support_screen.dart' show buildSupportTicketData;
import '../../../services/permission_primer.dart';
import '../../web_theme.dart';
import '../../../widgets/stream_error_state.dart';

/// Support client — équivalent web de `lib/screens/support/support_screen.dart`.
///
/// Mêmes règles : la collection `support_tickets` (Cloud-Function-only ?
/// Non — voir `firestore.rules:1418` : écriture directe autorisée au
/// propriétaire, qui ne peut créer qu'avec `status: 'open'` et ne peut
/// ensuite modifier que le champ `messages`). On reproduit ces deux
/// contraintes exactement, sans Cloud Function supplémentaire.
class WebClientSupportTab extends StatefulWidget {
  const WebClientSupportTab({super.key});

  @override
  State<WebClientSupportTab> createState() => _WebClientSupportTabState();
}

class _WebClientSupportTabState extends State<WebClientSupportTab> {
  String? _openTicketId;

  @override
  Widget build(BuildContext context) {
    if (_openTicketId != null) {
      return _TicketDetail(
        ticketId: _openTicketId!,
        onBack: () => setState(() => _openTicketId = null),
      );
    }
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return SingleChildScrollView(
      padding: EdgeInsets.all(hPad(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text('Mes tickets de support',
                  style: GoogleFonts.inter(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
            ),
            ElevatedButton.icon(
              onPressed: () => showDialog(
                context: context,
                builder: (_) => const _NewTicketDialog(),
              ),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Nouveau ticket'),
              style: ElevatedButton.styleFrom(
                backgroundColor: kOrange,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ]),
          const SizedBox(height: 20),
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection(Collections.supportTickets)
                .where('userId', isEqualTo: uid)
                .orderBy('createdAt', descending: true)
                .snapshots(),
            builder: (ctx, snap) {
              if (snap.hasError) {
                return StreamErrorState(
                  message: 'Impossible de charger vos tickets pour le moment.',
                  onRetry: () => setState(() {}),
                );
              }
              if (snap.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                      child: CircularProgressIndicator(color: kOrange)),
                );
              }
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                    child: Column(children: [
                      const Icon(Icons.support_agent_rounded,
                          color: kTextMuted, size: 56),
                      const SizedBox(height: 12),
                      Text('Aucun ticket pour le moment',
                          style:
                              GoogleFonts.inter(color: kTextMuted, fontSize: 15)),
                    ]),
                  ),
                );
              }
              return Column(
                children: docs.map((d) {
                  final data = d.data() as Map<String, dynamic>;
                  return _TicketListCard(
                    id: d.id,
                    data: data,
                    onTap: () => setState(() => _openTicketId = d.id),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _TicketListCard extends StatelessWidget {
  final String id;
  final Map<String, dynamic> data;
  final VoidCallback onTap;
  const _TicketListCard(
      {required this.id, required this.data, required this.onTap});

  Color _statusColor(String s) {
    switch (s) {
      case 'closed':
        return kTextMuted;
      case 'resolved':
        return kSuccess;
      case 'in_progress':
        return kBlue;
      default:
        return kOrange;
    }
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'open':
        return 'Ouvert';
      case 'in_progress':
        return 'En cours';
      case 'resolved':
        return 'Résolu';
      case 'closed':
        return 'Fermé';
      default:
        return s;
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = data['status'] as String? ?? 'open';
    final color = _statusColor(status);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.support_agent_rounded, color: color, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(data['subject'] as String? ?? '',
                    style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text(data['category'] as String? ?? '',
                    style: GoogleFonts.inter(color: kTextMuted, fontSize: 12)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(_statusLabel(status),
                style: GoogleFonts.inter(
                    color: color, fontSize: 11, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    );
  }
}

class _NewTicketDialog extends StatefulWidget {
  const _NewTicketDialog();

  @override
  State<_NewTicketDialog> createState() => _NewTicketDialogState();
}

class _NewTicketDialogState extends State<_NewTicketDialog> {
  final _subjectCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();
  String _category = SupportCategories.all.first;
  Uint8List? _screenshotBytes;
  bool _sending = false;

  @override
  void dispose() {
    _subjectCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickScreenshot() async {
    if (!await PermissionPrimer.prepareImage(ImageSource.gallery, context: context)) return;
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: 70, maxWidth: 1280);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() => _screenshotBytes = bytes);
  }

  Future<void> _submit() async {
    final subject = _subjectCtrl.text.trim();
    final message = _messageCtrl.text.trim();
    if (subject.isEmpty || message.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Remplissez le sujet et le message.'),
          backgroundColor: Colors.orange));
      return;
    }
    setState(() => _sending = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) throw Exception('Session expirée');
      String? screenshotUrl;
      if (_screenshotBytes != null) {
        final ref = FirebaseStorage.instance.ref(
            'support_screenshots/$uid/${DateTime.now().millisecondsSinceEpoch}.jpg');
        await ref.putData(
            _screenshotBytes!, SettableMetadata(contentType: 'image/jpeg'));
        screenshotUrl = await ref.getDownloadURL();
      }
      await FirebaseFirestore.instance
          .collection(Collections.supportTickets)
          .add(buildSupportTicketData(
            userId: uid,
            subject: subject,
            message: message,
            category: _category,
            screenshotUrl: screenshotUrl,
            createdAt: FieldValue.serverTimestamp(),
          ));
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Ticket envoyé ! Nous vous répondrons rapidement.'),
          backgroundColor: Colors.green));
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erreur : $e'), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Nouveau ticket'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _category,
              decoration: const InputDecoration(labelText: 'Catégorie'),
              items: SupportCategories.all
                  .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                  .toList(),
              onChanged: (v) => setState(() => _category = v!),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _subjectCtrl,
              decoration: const InputDecoration(labelText: 'Sujet'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _messageCtrl,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Message'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pickScreenshot,
              icon: const Icon(Icons.image_rounded),
              label: Text(_screenshotBytes == null
                  ? 'Ajouter une capture d\'écran (optionnel)'
                  : 'Capture jointe ✓'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler')),
        ElevatedButton(
          onPressed: _sending ? null : _submit,
          style: ElevatedButton.styleFrom(backgroundColor: kOrange),
          child: Text(_sending ? 'Envoi…' : 'Envoyer',
              style: const TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

class _TicketDetail extends StatefulWidget {
  final String ticketId;
  final VoidCallback onBack;
  const _TicketDetail({required this.ticketId, required this.onBack});

  @override
  State<_TicketDetail> createState() => _TicketDetailState();
}

class _TicketDetailState extends State<_TicketDetail> {
  final _replyCtrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _replyCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendReply() async {
    final text = _replyCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      final ref = FirebaseFirestore.instance
          .collection(Collections.supportTickets)
          .doc(widget.ticketId);
      final snap = await ref.get();
      final messages = List<Map<String, dynamic>>.from(
          (snap.data()?['messages'] as List?) ?? []);
      messages.add({
        'sender': 'user',
        'text': text,
        'timestamp': DateTime.now().toIso8601String(),
      });
      // Seul le champ `messages` est modifié : c'est l'unique écriture que
      // les règles Firestore autorisent au propriétaire d'un ticket déjà
      // créé (voir `firestore.rules:1423-1425`).
      await ref.update({'messages': messages});
      if (!mounted) return;
      _replyCtrl.clear();
      setState(() => _sending = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erreur : $e'), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            IconButton(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white)),
            Text('Mon ticket',
                style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
          ]),
        ),
        Expanded(
          child: StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection(Collections.supportTickets)
                .doc(widget.ticketId)
                .snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return StreamErrorState(
                  message: 'Impossible de charger ce ticket.',
                  onRetry: () => setState(() {}),
                );
              }
              if (!snap.hasData || !snap.data!.exists) {
                return const Center(
                    child: CircularProgressIndicator(color: kOrange));
              }
              final data = snap.data!.data() as Map<String, dynamic>;
              final messages = List<Map<String, dynamic>>.from(
                  (data['messages'] as List?) ?? []);
              final closed = data['status'] == 'closed';
              return Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.symmetric(horizontal: hPad(context)),
                      children: [
                        Text(data['subject'] as String? ?? '',
                            style: GoogleFonts.inter(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 16),
                        ...messages.map((m) {
                          final isAdmin = m['sender'] == 'admin';
                          return Align(
                            alignment: isAdmin
                                ? Alignment.centerLeft
                                : Alignment.centerRight,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.all(12),
                              constraints: const BoxConstraints(maxWidth: 420),
                              decoration: BoxDecoration(
                                color: isAdmin
                                    ? kBlue.withValues(alpha: 0.15)
                                    : kOrange.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(isAdmin ? 'Support AZ Express' : 'Vous',
                                      style: GoogleFonts.inter(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: isAdmin ? kBlue : kOrange)),
                                  const SizedBox(height: 4),
                                  Text(m['text'] as String? ?? '',
                                      style: const TextStyle(color: Colors.white)),
                                ],
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                  if (!closed)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(children: [
                        Expanded(
                          child: TextField(
                            controller: _replyCtrl,
                            decoration: const InputDecoration(
                                hintText: 'Écrire un message…'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        IconButton(
                          onPressed: _sending ? null : _sendReply,
                          icon: const Icon(Icons.send_rounded, color: kOrange),
                        ),
                      ]),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
