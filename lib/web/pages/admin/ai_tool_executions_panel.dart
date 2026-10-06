import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Supervision ADMIN des exécutions d'outils AZ IA — **lecture seule**.
///
/// La collection `ai_tool_executions` est totalement fermée aux clients dans
/// `firestore.rules` : ce panneau ne lit donc JAMAIS Firestore directement.
/// Il appelle la Cloud Function `listAiToolExecutions`, qui vérifie l'identité
/// et la permission admin côté serveur puis lit via l'Admin SDK.
///
/// Aucune action corrective n'est proposée (ni relance, ni suppression, ni
/// forçage de statut) : un état `failed`/`abandoned` peut masquer un effet
/// métier déjà appliqué, et le rejouer risquerait un double paiement.
class AiToolExecutionsPanel extends StatefulWidget {
  const AiToolExecutionsPanel({super.key});

  @override
  State<AiToolExecutionsPanel> createState() => _AiToolExecutionsPanelState();
}

class _AiToolExecutionsPanelState extends State<AiToolExecutionsPanel> {
  static const _statuses = <String?>[null, 'failed', 'abandoned', 'running', 'completed'];
  static const _labels = <String, String>{
    'failed': 'Échecs',
    'abandoned': 'Abandonnées',
    'running': 'En cours',
    'completed': 'Terminées',
  };

  String? _status;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('listAiToolExecutions');
      final result = await callable.call(<String, dynamic>{
        if (_status != null) 'status': _status,
        'limit': 50,
      });
      final data = Map<String, dynamic>.from(result.data as Map);
      final rows = (data['rows'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      // Message générique : aucun détail technique ni identifiant interne.
      setState(() {
        _error = "Impossible de charger les exécutions. Vérifiez vos droits d'accès.";
        _loading = false;
      });
    }
  }

  String _date(dynamic millis) {
    if (millis is! num) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(millis.toInt()).toLocal();
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Color _statusColor(String? status, bool stale) {
    if (stale) return Colors.orange.shade700;
    switch (status) {
      case 'completed':
        return Colors.green.shade700;
      case 'failed':
      case 'abandoned':
        return Colors.red.shade700;
      default:
        return Colors.blueGrey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final status in _statuses)
                ChoiceChip(
                  label: Text(status == null ? 'Tous' : _labels[status]!),
                  selected: _status == status,
                  onSelected: (_) {
                    setState(() => _status = status);
                    _load();
                  },
                ),
              const SizedBox(width: 12),
              TextButton.icon(
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Actualiser'),
              ),
            ],
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(color: Colors.grey.shade700)),
        ),
      );
    }
    if (_rows.isEmpty) {
      return Center(
        child: Text('Aucune exécution pour ce filtre.',
            style: GoogleFonts.inter(color: Colors.grey.shade600)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      itemCount: _rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _row(_rows[i]),
    );
  }

  Widget _row(Map<String, dynamic> row) {
    final status = row['status'] as String?;
    final stale = row['stale'] == true;
    final warning = row['replayWarning'] as String?;
    final color = _statusColor(status, stale);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: stale ? color : Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(row['toolName']?.toString() ?? '—',
                  style: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 14)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(stale ? 'STALE / À VÉRIFIER' : (status ?? '—'),
                  style: GoogleFonts.inter(
                      fontSize: 11, fontWeight: FontWeight.w700, color: color)),
            ),
          ]),
          const SizedBox(height: 6),
          Text('Créée : ${_date(row['createdAtMs'])}   ·   '
              'Démarrée : ${_date(row['startedAtMs'])}   ·   '
              'Expire : ${_date(row['expiresAtMs'])}',
              style: GoogleFonts.inter(fontSize: 12, color: Colors.grey.shade700)),
          Text('Utilisateur : ${row['uid'] ?? '—'}   ·   '
              'Conversation : ${row['conversationId'] ?? '—'}',
              style: GoogleFonts.inter(fontSize: 12, color: Colors.grey.shade700)),
          if (row['failureReason'] != null) ...[
            const SizedBox(height: 4),
            Text('Motif : ${row['failureReason']}',
                style: GoogleFonts.inter(fontSize: 12, color: Colors.red.shade700)),
          ],
          if (warning != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange.shade800),
              const SizedBox(width: 6),
              Expanded(
                child: Text(warning,
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.orange.shade900)),
              ),
            ]),
          ],
        ],
      ),
    );
  }
}
