import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../constants/app_constants.dart';
import '../../theme/app_theme.dart';

class SupportScreen extends StatefulWidget {
  const SupportScreen({super.key});

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Aide & Support'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
        bottom: TabBar(
          controller: _tabs,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          indicatorColor: Colors.white,
          tabs: const [
            Tab(text: 'Nouveau ticket'),
            Tab(text: 'Mes tickets'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _NewTicketTab(),
          _TicketHistoryTab(),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ONGLET NOUVEAU TICKET
// ─────────────────────────────────────────────────────────────────────────────
class _NewTicketTab extends StatefulWidget {
  const _NewTicketTab();

  @override
  State<_NewTicketTab> createState() => _NewTicketTabState();
}

class _NewTicketTabState extends State<_NewTicketTab> {
  final _subjectCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();
  String _category   = 'Livraison';
  bool   _sending    = false;
  Uint8List? _screenshotBytes;
  String?    _screenshotName;

  static const _categories = [
    'Livraison',
    'Paiement / Wallet',
    'Commande',
    'Compte',
    'E-Kbine',
    'Marketplace',
    'Autre',
  ];

  @override
  void dispose() {
    _subjectCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickScreenshot() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 70,
        maxWidth: 1280,
      );
      if (picked != null && mounted) {
        final bytes = await picked.readAsBytes();
        setState(() {
          _screenshotBytes = bytes;
          _screenshotName  = picked.name;
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Impossible d'accéder à la galerie. Vérifiez les permissions."),
          backgroundColor: Colors.orange,
        ));
      }
    }
  }

  Future<void> _submit() async {
    final subject = _subjectCtrl.text.trim();
    final message = _messageCtrl.text.trim();

    if (subject.isEmpty || message.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Remplissez le sujet et le message.'),
        backgroundColor: Colors.orange,
      ));
      return;
    }

    setState(() => _sending = true);

    try {
      final uid  = FirebaseAuth.instance.currentUser?.uid ?? 'anonymous';
      String? screenshotUrl;

      if (_screenshotBytes != null) {
        final ref = FirebaseStorage.instance
            .ref('support_screenshots/$uid/${DateTime.now().millisecondsSinceEpoch}.jpg');
        await ref.putData(
          _screenshotBytes!,
          SettableMetadata(contentType: 'image/jpeg'),
        );
        screenshotUrl = await ref.getDownloadURL();
      }

      await FirebaseFirestore.instance
          .collection(Collections.supportTickets)
          .add({
        'userId':        uid,
        'subject':       subject,
        'message':       message,
        'category':      _category,
        'status':        'open',
        'screenshotUrl': screenshotUrl,
        'createdAt':     FieldValue.serverTimestamp(),
        'messages': [
          {
            'sender':    'user',
            'text':      message,
            'timestamp': DateTime.now().toIso8601String(),
          }
        ],
      });

      if (!mounted) return;
      setState(() {
        _sending = false;
        _subjectCtrl.clear();
        _messageCtrl.clear();
        _screenshotBytes = null;
        _screenshotName  = null;
        _category = 'Livraison';
      });

      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Ticket envoyé ! Nous vous répondrons rapidement.'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 3),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Erreur : ${e.toString()}'),
        backgroundColor: Colors.red,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Contacts rapides ──────────────────────────────────────────────
          _QuickContacts(),
          const SizedBox(height: 20),

          // ── Formulaire ───────────────────────────────────────────────────
          const Text('Signaler un problème',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey)),
          const SizedBox(height: 10),

          _card(children: [
            // Catégorie
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: DropdownButtonFormField<String>(
                // ignore: deprecated_member_use
                value: _category,
                decoration: const InputDecoration(
                  labelText: 'Catégorie',
                  prefixIcon: Icon(Icons.category_outlined,
                      color: AppColors.primary),
                  border: InputBorder.none,
                ),
                items: _categories
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (v) => setState(() => _category = v!),
              ),
            ),
            const Divider(height: 1),

            // Sujet
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _subjectCtrl,
                decoration: const InputDecoration(
                  labelText: 'Sujet',
                  prefixIcon:
                      Icon(Icons.title_rounded, color: AppColors.primary),
                  border: InputBorder.none,
                ),
              ),
            ),
            const Divider(height: 1),

            // Message
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextField(
                controller: _messageCtrl,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Décrivez votre problème',
                  alignLabelWithHint: true,
                  prefixIcon: Padding(
                    padding: EdgeInsets.only(bottom: 80),
                    child: Icon(Icons.message_outlined,
                        color: AppColors.primary),
                  ),
                  border: InputBorder.none,
                ),
              ),
            ),
          ]),

          const SizedBox(height: 12),

          // ── Capture d'écran ───────────────────────────────────────────────
          GestureDetector(
            onTap: _pickScreenshot,
            child: _card(children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.add_photo_alternate_outlined,
                          color: AppColors.primary, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Ajouter une capture d\'écran',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 14)),
                          Text(
                            _screenshotName ?? 'Optionnel — aide à comprendre le problème',
                            style: TextStyle(
                                color: _screenshotName != null
                                    ? Colors.green
                                    : Colors.grey,
                                fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (_screenshotBytes != null)
                      IconButton(
                        icon: const Icon(Icons.close,
                            size: 18, color: Colors.grey),
                        onPressed: () => setState(() {
                          _screenshotBytes = null;
                          _screenshotName  = null;
                        }),
                      ),
                  ],
                ),
              ),
              if (_screenshotBytes != null)
                Padding(
                  padding:
                      const EdgeInsets.only(left: 16, right: 16, bottom: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.memory(_screenshotBytes!,
                        height: 160, width: double.infinity,
                        fit: BoxFit.cover),
                  ),
                ),
            ]),
          ),

          const SizedBox(height: 20),

          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _sending ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded),
              label: Text(_sending ? 'Envoi...' : 'Envoyer le ticket',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _card({required List<Widget> children}) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)
          ],
        ),
        child: Column(children: children),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// CONTACTS RAPIDES
// ─────────────────────────────────────────────────────────────────────────────
class _QuickContacts extends StatelessWidget {
  Future<void> _openWhatsApp() async {
    final uri = Uri.parse(AppConfig.whatsAppUrl);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _callSupport() async {
    final uri = Uri.parse('tel:${AppConfig.supportPhone}');
    try {
      await launchUrl(uri);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Contacter AZ Express',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey)),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _ContactButton(
                icon:     Icons.chat_rounded,
                label:    'WhatsApp',
                sublabel: 'Réponse rapide',
                color:    const Color(0xFF25D366),
                onTap:    _openWhatsApp,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ContactButton(
                icon:     Icons.phone_rounded,
                label:    'Appeler',
                sublabel: AppConfig.supportPhone,
                color:    const Color(0xFF1E88E5),
                onTap:    _callSupport,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ContactButton extends StatelessWidget {
  final IconData   icon;
  final String     label;
  final String     sublabel;
  final Color      color;
  final VoidCallback onTap;

  const _ContactButton({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: GoogleFonts.urbanist(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Colors.black87)),
                  Text(sublabel,
                      style: GoogleFonts.urbanist(
                          fontSize: 10,
                          color: Colors.grey),
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ONGLET HISTORIQUE DES TICKETS
// ─────────────────────────────────────────────────────────────────────────────
class _TicketHistoryTab extends StatelessWidget {
  const _TicketHistoryTab();

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const Center(
          child: Text('Connectez-vous pour voir vos tickets.'));
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection(Collections.supportTickets)
          .where('userId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .limit(20)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snap.data?.docs ?? [];

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.support_agent_rounded,
                    size: 64, color: Colors.grey.shade300),
                const SizedBox(height: 12),
                Text('Aucun ticket pour l\'instant',
                    style: GoogleFonts.urbanist(
                        color: Colors.grey, fontSize: 15)),
                const SizedBox(height: 6),
                Text('Signalez un problème depuis l\'onglet "Nouveau ticket"',
                    style: GoogleFonts.urbanist(
                        color: Colors.grey.shade400, fontSize: 12),
                    textAlign: TextAlign.center),
              ],
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, i) {
            final data = docs[i].data() as Map<String, dynamic>;
            return _TicketCard(data: data, id: docs[i].id);
          },
        );
      },
    );
  }
}

class _TicketCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final String               id;
  const _TicketCard({required this.data, required this.id});

  Color _statusColor(String s) {
    switch (s) {
      case 'open':       return Colors.orange;
      case 'in_progress': return Colors.blue;
      case 'resolved':   return Colors.green;
      case 'closed':     return Colors.grey;
      default:           return Colors.orange;
    }
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'open':        return 'Ouvert';
      case 'in_progress': return 'En cours';
      case 'resolved':    return 'Résolu';
      case 'closed':      return 'Fermé';
      default:            return s;
    }
  }

  String _formatDate(dynamic ts) {
    if (ts == null) return '—';
    final d = (ts as Timestamp).toDate();
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final status   = data['status'] as String? ?? 'open';
    final subject  = data['subject'] as String? ?? 'Sans sujet';
    final category = data['category'] as String? ?? '';
    final color    = _statusColor(status);
    final hasScreenshot = (data['screenshotUrl'] as String?) != null;
    final messages = (data['messages'] as List?) ?? [];
    final hasReply = messages.any((m) => (m as Map)['sender'] == 'admin');

    return GestureDetector(
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => _TicketDetailScreen(ticketId: id))),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(subject,
                        style: GoogleFonts.urbanist(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: Colors.black87),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(_statusLabel(status),
                        style: TextStyle(
                            color: color,
                            fontSize: 11,
                            fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.label_outline,
                      size: 13, color: Colors.grey.shade400),
                  const SizedBox(width: 4),
                  Text(category,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500)),
                  const Spacer(),
                  Icon(Icons.calendar_today_outlined,
                      size: 12, color: Colors.grey.shade400),
                  const SizedBox(width: 4),
                  Text(_formatDate(data['createdAt']),
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade400)),
                  if (hasScreenshot) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.image_outlined,
                        size: 13, color: Colors.grey.shade400),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                data['message'] as String? ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                    height: 1.4),
              ),
              if (hasReply) ...[
                const SizedBox(height: 8),
                Row(children: [
                  Icon(Icons.reply_rounded, size: 13, color: Colors.blue.shade400),
                  const SizedBox(width: 4),
                  Text('Réponse du support disponible — touchez pour voir',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.blue.shade600,
                          fontWeight: FontWeight.w600)),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Détail d'un ticket — affiche le fil complet des messages (client + admin)
/// et permet au client de répondre. La règle Firestore autorisait déjà le
/// propriétaire du ticket à modifier `messages` (sans toucher `status`)
/// depuis le début — cet écran manquait simplement côté UI (Master Prompt 78,
/// 2026-07-09).
class _TicketDetailScreen extends StatefulWidget {
  final String ticketId;
  const _TicketDetailScreen({required this.ticketId});

  @override
  State<_TicketDetailScreen> createState() => _TicketDetailScreenState();
}

class _TicketDetailScreenState extends State<_TicketDetailScreen> {
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
      await ref.update({'messages': messages});
      if (!mounted) return;
      setState(() { _replyCtrl.clear(); _sending = false; });
    } catch (_) {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Mon ticket'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection(Collections.supportTickets)
            .doc(widget.ticketId)
            .snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(child: Text('Impossible de charger le ticket.'));
          }
          if (!snap.hasData || !snap.data!.exists) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data!.data() as Map<String, dynamic>;
          final messages = List<Map<String, dynamic>>.from(
              (data['messages'] as List?) ?? []);
          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(data['subject'] as String? ?? '',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
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
                          constraints: const BoxConstraints(maxWidth: 280),
                          decoration: BoxDecoration(
                            color: isAdmin
                                ? Colors.blue.shade50
                                : AppColors.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(isAdmin ? 'Support AZ Express' : 'Vous',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: isAdmin
                                          ? Colors.blue.shade700
                                          : AppColors.primary)),
                              const SizedBox(height: 4),
                              Text(m['text'] as String? ?? ''),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              if (data['status'] != 'closed')
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _replyCtrl,
                            decoration: const InputDecoration(
                              hintText: 'Écrire un message…',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: _sending ? null : _sendReply,
                          icon: _sending
                              ? const SizedBox(
                                  width: 18, height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.send_rounded,
                                  color: AppColors.primary),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
