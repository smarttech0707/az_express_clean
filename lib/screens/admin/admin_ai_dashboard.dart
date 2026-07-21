import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Tableau de bord Admin IA (Master Prompt 118) — première visibilité admin
/// sur les données déjà collectées par `AIProviderService.js` (Prompt 108) et
/// `logAiObservability` (Prompt 31), jusqu'ici invisibles depuis aucun écran :
/// `ai_usage`/`ai_daily_stats`/`ai_logs` (lecture admin) et `request_logs`
/// (lecture **super-admin uniquement**, règle déjà plus stricte — voir
/// firestore.rules — donc la section "outils" reste masquée pour un
/// sous-admin plutôt que de tenter une lecture qui échouerait silencieusement).
/// Snapshot statique (bouton Actualiser), pas un flux temps réel — cohérent
/// avec admin_geo_stats_page.dart, déjà sur ce même modèle pour ce type
/// d'écran d'analyse.
class AdminAiDashboard extends StatefulWidget {
  final bool isSuper;
  const AdminAiDashboard({super.key, required this.isSuper});

  @override
  State<AdminAiDashboard> createState() => _AdminAiDashboardState();
}

class _AiSummary {
  int requests = 0;
  int errors = 0;
  int cacheHits = 0;
  double cost = 0;
  int inputTokens = 0;
  int outputTokens = 0;
  int totalResponseMs = 0;
  final Map<String, _ProviderStat> byProvider = {};
}

class _ProviderStat {
  int requests = 0;
  int errors = 0;
  int cacheHits = 0;
  double cost = 0;
  int inputTokens = 0;
  int outputTokens = 0;
}

class _ToolSummary {
  int turns = 0;
  int successCount = 0;
  int errorCount = 0;
  int hitTurnCapCount = 0;
  int totalDurationMs = 0;
  final Map<String, int> toolUsage = {};
}

class _AdminAiDashboardState extends State<AdminAiDashboard> {
  bool _loading = true;
  String? _error;
  _AiSummary? _summary;
  List<Map<String, dynamic>> _recentErrors = [];
  _ToolSummary? _toolSummary;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final since = DateTime.now().subtract(const Duration(days: 7));
      final sinceStr = since.toIso8601String().substring(0, 10);

      // Un seul filtre d'inégalité (date >= sinceStr), sans orderBy — évite
      // d'exiger un nouvel index composite (même discipline que Prompt 115).
      final dailySnap = await FirebaseFirestore.instance
          .collection('ai_daily_stats')
          .where('date', isGreaterThanOrEqualTo: sinceStr)
          .get();

      final summary = _AiSummary();
      for (final doc in dailySnap.docs) {
        final d = doc.data();
        final provider = d['provider'] as String? ?? 'inconnu';
        final stat = summary.byProvider.putIfAbsent(provider, () => _ProviderStat());
        final requests = (d['requestCount'] as num?)?.toInt() ?? 0;
        final errors = (d['errorCount'] as num?)?.toInt() ?? 0;
        final cacheHits = (d['cacheHitCount'] as num?)?.toInt() ?? 0;
        final cost = (d['totalCost'] as num?)?.toDouble() ?? 0;
        final inTok = (d['totalInputTokens'] as num?)?.toInt() ?? 0;
        final outTok = (d['totalOutputTokens'] as num?)?.toInt() ?? 0;
        final respMs = (d['totalResponseTimeMs'] as num?)?.toInt() ?? 0;

        stat.requests += requests;
        stat.errors += errors;
        stat.cacheHits += cacheHits;
        stat.cost += cost;
        stat.inputTokens += inTok;
        stat.outputTokens += outTok;

        summary.requests += requests;
        summary.errors += errors;
        summary.cacheHits += cacheHits;
        summary.cost += cost;
        summary.inputTokens += inTok;
        summary.outputTokens += outTok;
        summary.totalResponseMs += respMs;
      }

      // Échantillon borné, sans orderBy (même raison) — tri fait côté client.
      final errSnap = await FirebaseFirestore.instance
          .collection('ai_logs')
          .where('success', isEqualTo: false)
          .limit(20)
          .get();
      final recentErrors = errSnap.docs.map((d) => d.data()).toList()
        ..sort((a, b) {
          final ta = a['createdAt'] as Timestamp?;
          final tb = b['createdAt'] as Timestamp?;
          if (ta == null || tb == null) return 0;
          return tb.compareTo(ta);
        });

      _ToolSummary? toolSummary;
      if (widget.isSuper) {
        // `request_logs` exige isSuperAdmin() côté règles — un sous-admin
        // ne doit même pas tenter cette lecture (échouerait silencieusement
        // en permission-denied) : section entièrement masquée pour lui.
        final logsSnap = await FirebaseFirestore.instance
            .collection('request_logs')
            .where('functionName', isEqualTo: 'azIaChat')
            .limit(150)
            .get();
        toolSummary = _ToolSummary();
        for (final doc in logsSnap.docs) {
          final d = doc.data();
          toolSummary.turns++;
          if (d['status'] == 'success') {
            toolSummary.successCount++;
          } else {
            toolSummary.errorCount++;
          }
          if (d['hitTurnCap'] == true) toolSummary.hitTurnCapCount++;
          toolSummary.totalDurationMs += ((d['durationMs'] as num?)?.toInt() ?? 0);
          final tools = d['toolsUsed'];
          if (tools is List) {
            for (final t in tools) {
              final key = t.toString();
              toolSummary.toolUsage[key] = (toolSummary.toolUsage[key] ?? 0) + 1;
            }
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _summary = summary;
        _recentErrors = recentErrors;
        _toolSummary = toolSummary;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'Erreur de chargement : $e'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Tableau de bord IA'),
        backgroundColor: const Color(0xFF4527A0),
        foregroundColor: Colors.white,
        centerTitle: true,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loading ? null : _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(14),
                    children: [
                      Text('7 derniers jours', style: TextStyle(color: Colors.grey.shade600, fontSize: 12.5)),
                      const SizedBox(height: 8),
                      _buildSummaryGrid(),
                      const SizedBox(height: 20),
                      _sectionTitle('Répartition par fournisseur'),
                      _buildProviderTable(),
                      const SizedBox(height: 20),
                      _sectionTitle('Erreurs récentes (${_recentErrors.length})'),
                      _buildErrorsList(),
                      if (widget.isSuper) ...[
                        const SizedBox(height: 20),
                        _sectionTitle('Outils AZ IA (super-admin, échantillon récent)'),
                        _buildToolSection(),
                      ] else ...[
                        const SizedBox(height: 20),
                        Text(
                          'Section "Outils AZ IA" réservée aux super-admins.',
                          style: TextStyle(color: Colors.grey.shade500, fontSize: 12.5, fontStyle: FontStyle.italic),
                        ),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      );

  Widget _buildSummaryGrid() {
    final s = _summary!;
    final avgLatencyMs = s.requests > 0 ? (s.totalResponseMs / s.requests).round() : 0;
    final cacheableTotal = s.requests + s.cacheHits;
    final cacheHitRate = cacheableTotal > 0 ? (s.cacheHits / cacheableTotal * 100).toStringAsFixed(0) : '0';

    final tiles = [
      _StatTile(label: 'Appels IA', value: '${s.requests}', icon: Icons.forum_outlined, color: const Color(0xFF3949AB)),
      _StatTile(label: 'Coût estimé', value: '\$${s.cost.toStringAsFixed(4)}', icon: Icons.payments_outlined, color: const Color(0xFF2E7D32)),
      _StatTile(label: 'Latence moyenne', value: '${avgLatencyMs}ms', icon: Icons.speed_outlined, color: const Color(0xFFEF6C00)),
      _StatTile(label: 'Cache', value: '${s.cacheHits} ($cacheHitRate%)', icon: Icons.bolt_outlined, color: const Color(0xFF00897B)),
      _StatTile(label: 'Tokens entrée', value: '${s.inputTokens}', icon: Icons.arrow_downward, color: const Color(0xFF6A1B9A)),
      _StatTile(label: 'Tokens sortie', value: '${s.outputTokens}', icon: Icons.arrow_upward, color: const Color(0xFF6A1B9A)),
      _StatTile(label: 'Erreurs', value: '${s.errors}', icon: Icons.error_outline, color: const Color(0xFFE53935)),
    ];

    return Wrap(
      spacing: 10, runSpacing: 10,
      children: tiles,
    );
  }

  Widget _buildProviderTable() {
    final entries = _summary!.byProvider.entries.toList()
      ..sort((a, b) => b.value.requests.compareTo(a.value.requests));
    if (entries.isEmpty) {
      return const _EmptyHint(text: 'Aucune donnée sur les 7 derniers jours.');
    }
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          for (final e in entries)
            ListTile(
              dense: true,
              leading: const Icon(Icons.smart_toy_outlined),
              title: Text(e.key),
              subtitle: Text('${e.value.inputTokens} tok. entrée · ${e.value.outputTokens} tok. sortie · ${e.value.cacheHits} cache'),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${e.value.requests} appels', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
                  Text('\$${e.value.cost.toStringAsFixed(4)}', style: TextStyle(color: Colors.grey.shade600, fontSize: 11.5)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildErrorsList() {
    if (_recentErrors.isEmpty) {
      return const _EmptyHint(text: 'Aucune erreur récente 👍');
    }
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          for (final e in _recentErrors.take(10))
            ListTile(
              dense: true,
              leading: const Icon(Icons.error_outline, color: Colors.red),
              title: Text(e['errorMessage']?.toString() ?? 'Erreur inconnue', maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${e['provider'] ?? '?'} · ${e['model'] ?? '?'}'),
            ),
        ],
      ),
    );
  }

  Widget _buildToolSection() {
    final t = _toolSummary;
    if (t == null || t.turns == 0) {
      return const _EmptyHint(text: 'Aucune donnée disponible.');
    }
    final avgDuration = (t.totalDurationMs / t.turns).round();
    final topTools = t.toolUsage.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10, runSpacing: 10,
          children: [
            _StatTile(label: 'Tours (échantillon)', value: '${t.turns}', icon: Icons.forum_outlined, color: const Color(0xFF3949AB)),
            _StatTile(label: 'Succès', value: '${t.successCount}', icon: Icons.check_circle_outline, color: const Color(0xFF2E7D32)),
            _StatTile(label: 'Échecs', value: '${t.errorCount}', icon: Icons.error_outline, color: const Color(0xFFE53935)),
            _StatTile(label: 'Plafond de tours atteint', value: '${t.hitTurnCapCount}', icon: Icons.warning_amber_outlined, color: const Color(0xFFF9A825)),
            _StatTile(label: 'Durée moyenne', value: '${avgDuration}ms', icon: Icons.speed_outlined, color: const Color(0xFFEF6C00)),
          ],
        ),
        const SizedBox(height: 12),
        const Text('Outils les plus utilisés', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
          child: Column(
            children: [
              for (final e in topTools.take(10))
                ListTile(
                  dense: true,
                  title: Text(e.key),
                  trailing: Text('${e.value}', style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  const _StatTile({required this.label, required this.value, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 158,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 8),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 11.5)),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: Text(text, style: TextStyle(color: Colors.grey.shade600)),
    );
  }
}
