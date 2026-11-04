import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/partner_orders_config_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_button.dart';
import '../../widgets/driver_partner_order_panel.dart' show SingleFlight;
import '../../widgets/stream_error_state.dart';

/// Flux du document de configuration (null = document absent). Remplaçable dans les tests.
typedef PilotConfigSource = Stream<Map<String, dynamic>?> Function();

/// Modification via `setPartnerOrdersConfig`. Remplaçable dans les tests.
typedef PilotConfigRunner = Future<PartnerOrdersConfig> Function({
  required int expectedVersion,
  required Map<String, dynamic> patch,
  required String reason,
});

/// Lecture seule : les administrateurs peuvent lire `config/partnerOrdersV2`, personne ne peut l'écrire depuis l'app.
Stream<Map<String, dynamic>?> firestorePilotConfig() => FirebaseFirestore
    .instance
    .collection('config')
    .doc('partnerOrdersV2')
    .snapshots()
    .map((s) => s.data());

Future<PartnerOrdersConfig> _defaultRunner({
  required int expectedVersion,
  required Map<String, dynamic> patch,
  required String reason,
}) =>
    PartnerOrdersConfigService.update(
        expectedVersion: expectedVersion, patch: patch, reason: reason);

/// Pilotage des commandes Restaurant/Boulangerie v2 (super-administrateur) : restaurants pilotes, ouverture/fermeture de la
/// création, gel d'urgence. Chaque changement passe par le serveur (super-administrateur vérifié, version contrôlée, audit) ;
/// l'écran n'affiche jamais un état supposé : seul le document relu fait foi. Rien ne s'ouvre automatiquement.
class AdminPartnerPilotPage extends StatefulWidget {
  final PilotConfigSource? source;
  final PilotConfigRunner? runner;
  const AdminPartnerPilotPage({super.key, this.source, this.runner});

  @override
  State<AdminPartnerPilotPage> createState() => _AdminPartnerPilotPageState();
}

class _AdminPartnerPilotPageState extends State<AdminPartnerPilotPage> {
  final SingleFlight _flight = SingleFlight();
  late final Stream<Map<String, dynamic>?> _stream =
      (widget.source ?? firestorePilotConfig)();
  final _newId = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _idError;

  @override
  void dispose() {
    _newId.dispose();
    super.dispose();
  }

  PilotConfigRunner get _run => widget.runner ?? _defaultRunner;

  /// Reçoit la version AFFICHÉE au moment du clic : si le document change entre-temps, le serveur refuse (conflit).
  Future<void> _apply(
    PartnerOrdersConfig current, {
    required String title,
    required String body,
    required Map<String, dynamic> patch,
    String? suggestedReason,
    bool danger = false,
  }) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => _ReasonDialog(
          title: title,
          body: body,
          initialReason: suggestedReason,
          danger: danger),
    );
    if (reason == null || !mounted) return;
    await _flight.run(() async {
      setState(() {
        _busy = true;
        _error = null;
      });
      String? failure;
      PartnerOrdersConfig? done;
      try {
        done = await _run(
            expectedVersion: current.version, patch: patch, reason: reason);
      } on PartnerOrdersConfigException catch (e) {
        failure = e.userMessage;
      } catch (_) {
        failure = const PartnerOrdersConfigException('NETWORK', '',
                retryable: true)
            .userMessage;
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = failure;
      });
      if (done != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Configuration enregistrée (version ${done.version}).')));
      }
    });
  }

  void _addPilot(PartnerOrdersConfig c) {
    final id = _newId.text.trim();
    String? err;
    if (!PartnerOrdersConfig.validPartnerId(id)) {
      err = 'Identifiant invalide (lettres, chiffres, - et _ ; 128 max).';
    } else if (c.pilotPartnerIds.contains(id)) {
      err = 'Ce partenaire est déjà pilote.';
    } else if (c.pilotPartnerIds.length >= PartnerOrdersConfig.maxPilots) {
      err = 'Maximum ${PartnerOrdersConfig.maxPilots} partenaires pilotes.';
    }
    setState(() => _idError = err);
    if (err != null) return;
    _apply(
      c,
      title: 'Ajouter un restaurant pilote',
      body:
          'Le partenaire « $id » n’acceptera plus de commande créée au format historique : ses nouvelles commandes passeront par '
          'le devis serveur dès que la création sera ouverte. Son application doit être à jour.',
      patch: {
        'pilotPartnerIds': [...c.pilotPartnerIds, id],
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pilote restaurants v2'),
        backgroundColor: AppColors.primaryAction,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: StreamBuilder<Map<String, dynamic>?>(
        stream: _stream,
        builder: (context, snap) {
          if (snap.hasError) {
            return const StreamErrorState(
                message:
                    'Impossible de lire la configuration.\nVérifiez votre connexion et vos droits.');
          }
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final c = PartnerOrdersConfig.fromDoc(snap.data);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _notice(),
              const SizedBox(height: 12),
              _creationCard(c),
              const SizedBox(height: 12),
              _freezeCard(c),
              const SizedBox(height: 12),
              _pilotsCard(c),
              const SizedBox(height: 12),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!,
                      key: const ValueKey('pilot-error'),
                      style: GoogleFonts.urbanist(
                          color: AppColors.errorStrong,
                          fontWeight: FontWeight.w700)),
                ),
              Text(
                'Version ${c.version}${c.updatedAtMs != null ? ' · modifiée le ${_date(c.updatedAtMs!)}' : ''}'
                '${c.lastReason != null ? '\nDernier motif : ${c.lastReason}' : ''}',
                style: GoogleFonts.urbanist(
                    fontSize: 12, color: AppColors.textMuted),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _notice() => _card(
        child: Text(
          'Tout est fermé par défaut : rien ne s’ouvre automatiquement. La création de commandes v2 exige aussi la variable '
          'PARTNER_ORDERS_V2=on dans le déploiement des fonctions. Fermer la création ou activer le gel n’annule aucune commande '
          'existante.',
          style: GoogleFonts.urbanist(fontSize: 12, color: AppColors.textMuted),
        ),
      );

  Widget _creationCard(PartnerOrdersConfig c) {
    final open = c.creationOpen;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title('Création de commandes v2'),
          Text(open ? 'OUVERTE' : 'FERMÉE',
              key: const ValueKey('creation-state'),
              style: GoogleFonts.urbanist(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  color: open ? AppColors.errorStrong : AppColors.successStrong)),
          const SizedBox(height: 4),
          Text(
              open
                  ? 'Les restaurants pilotes reçoivent de nouvelles commandes v2.'
                  : 'Aucune nouvelle commande v2 (les commandes existantes continuent).',
              style: GoogleFonts.urbanist(fontSize: 12)),
          const SizedBox(height: 8),
          if (open)
            AppButton(
              label: 'Fermer la création',
              icon: Icons.lock_rounded,
              variant: AppButtonVariant.danger,
              loading: _busy,
              onPressed: _busy
                  ? null
                  : () => _apply(c,
                      title: 'Fermer la création',
                      body:
                          'Plus aucune nouvelle commande v2 ne pourra être créée. Les commandes existantes ne sont pas touchées.',
                      patch: {'creationOpen': false},
                      suggestedReason: 'Fermeture du pilote',
                      danger: true),
            )
          else
            AppButton(
              label: 'Ouvrir la création',
              icon: Icons.lock_open_rounded,
              loading: _busy,
              onPressed: _busy
                  ? null
                  : () => _apply(c,
                      title: 'Ouvrir la création',
                      body: c.pilotPartnerIds.isEmpty
                          ? 'Aucun restaurant pilote n’est listé : aucune commande ne sera possible tant qu’aucun n’est ajouté.'
                          : 'Les restaurants pilotes (${c.pilotPartnerIds.length}) pourront recevoir de vraies commandes v2.',
                      patch: {'creationOpen': true}),
            ),
        ],
      ),
    );
  }

  Widget _freezeCard(PartnerOrdersConfig c) {
    final frozen = c.managementFrozen;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title('Gel d’urgence de la gestion'),
          Text(frozen ? 'GEL ACTIF' : 'Aucun gel',
              key: const ValueKey('freeze-state'),
              style: GoogleFonts.urbanist(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  color: frozen ? AppColors.errorStrong : AppColors.successStrong)),
          const SizedBox(height: 4),
          Text(
              'Le gel suspend l’acceptation, la préparation et le reversement cash des commandes v2 existantes. '
              'L’annulation par le client, l’expiration et la livraison restent actives.',
              style: GoogleFonts.urbanist(fontSize: 12)),
          const SizedBox(height: 8),
          if (frozen)
            AppButton(
              label: 'Lever le gel',
              icon: Icons.play_arrow_rounded,
              loading: _busy,
              onPressed: _busy
                  ? null
                  : () => _apply(c,
                      title: 'Lever le gel',
                      body: 'La gestion des commandes v2 reprend immédiatement.',
                      patch: {'managementFrozen': false}),
            )
          else
            AppButton(
              label: 'Activer le gel d’urgence',
              icon: Icons.pause_circle_rounded,
              variant: AppButtonVariant.danger,
              loading: _busy,
              onPressed: _busy
                  ? null
                  : () => _apply(c,
                      title: 'Activer le gel d’urgence',
                      body:
                          'Les restaurateurs et livreurs ne pourront plus faire avancer les commandes v2 existantes tant que le gel est actif.',
                      patch: {'managementFrozen': true},
                      suggestedReason: 'Gel d’urgence du pilote',
                      danger: true),
            ),
        ],
      ),
    );
  }

  Widget _pilotsCard(PartnerOrdersConfig c) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title('Restaurants pilotes (${c.pilotPartnerIds.length}/${PartnerOrdersConfig.maxPilots})'),
          if (c.pilotPartnerIds.isEmpty)
            Text('Aucun restaurant pilote.',
                key: const ValueKey('no-pilots'),
                style: GoogleFonts.urbanist(fontSize: 13)),
          for (final id in c.pilotPartnerIds)
            Row(children: [
              Expanded(
                  child: Text(id,
                      style: GoogleFonts.urbanist(
                          fontWeight: FontWeight.w700, fontSize: 13))),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _apply(c,
                        title: 'Retirer un restaurant pilote',
                        body:
                            'Le partenaire « $id » ne sera plus pilote : il retrouve l’ancien parcours de commande. Ses commandes v2 existantes continuent.',
                        patch: {
                          'pilotPartnerIds': [
                            for (final p in c.pilotPartnerIds)
                              if (p != id) p
                          ],
                        },
                        danger: true),
                child: Text('Retirer',
                    semanticsLabel: 'Retirer $id',
                    style: const TextStyle(color: AppColors.errorStrong)),
              ),
            ]),
          const SizedBox(height: 8),
          TextField(
            controller: _newId,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: 'Identifiant du restaurant (document restaurants/…)',
              errorText: _idError,
            ),
          ),
          const SizedBox(height: 8),
          AppButton(
            label: 'Ajouter ce restaurant',
            icon: Icons.add_business_rounded,
            variant: AppButtonVariant.outlined,
            onPressed: _busy ? null : () => _addPilot(c),
          ),
        ],
      ),
    );
  }

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t,
            style: GoogleFonts.urbanist(
                fontWeight: FontWeight.w800, fontSize: 14)),
      );

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadius.lg)),
        child: child,
      );
}

/// Résumé du changement + justification (10 à 300 caractères, exigée par le serveur). Le contrôleur appartient à la boîte.
class _ReasonDialog extends StatefulWidget {
  final String title;
  final String body;
  final String? initialReason;
  final bool danger;
  const _ReasonDialog(
      {required this.title,
      required this.body,
      this.initialReason,
      this.danger = false});

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  late final _controller = TextEditingController(text: widget.initialReason);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final t = _controller.text.trim();
    if (t.length < 10 || t.length > 300) {
      setState(() => _error = 'Justification de 10 à 300 caractères.');
      return;
    }
    Navigator.pop(context, t);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.body, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 10),
              TextField(
                controller: _controller,
                maxLength: 300,
                maxLines: 3,
                decoration: InputDecoration(
                    labelText: 'Justification (10 à 300 caractères)',
                    errorText: _error),
              ),
            ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler')),
        ElevatedButton(
          onPressed: _submit,
          style: ElevatedButton.styleFrom(
              backgroundColor:
                  widget.danger ? AppColors.error : AppColors.primary),
          child: const Text('Confirmer', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
