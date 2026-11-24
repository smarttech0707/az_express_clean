import 'package:flutter/material.dart';
import '../models/ek_deposit_account.dart';

/// Boîte de dialogue d'ajout/édition d'un numéro de dépôt E-Kbine — extraite
/// pour être partagée entre `ek_deposit_accounts_screen.dart` (gestion après
/// inscription) et `ek_agent_register.dart` (inscription multi-lignes), sans
/// dupliquer la logique de saisie/validation à deux endroits.
Future<EkDepositAccount?> showEkDepositAccountDialog(
  BuildContext context, {
  EkDepositAccount? existing,
}) {
  return showDialog<EkDepositAccount>(
    context: context,
    useSafeArea: true,
    builder: (_) => _EkDepositAccountDialog(account: existing),
  );
}

/// Boîte de dialogue de confirmation avant suppression d'un numéro de dépôt
/// (Mission 2) — "Annuler" par défaut, ne renvoie `true` qu'après un appui
/// explicite sur "Supprimer". Extraite en fonction indépendante pour rester
/// testable sans avoir à monter tout l'écran de gestion des numéros.
Future<bool> showEkDeleteAccountConfirmDialog(
  BuildContext context,
  EkDepositAccount account, {
  required String operatorLabel,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Supprimer ce numéro ?'),
      content: Text(
        '$operatorLabel · ${account.phoneNumber}\n\n'
        'Cette action est définitive. Les commandes déjà en cours ou terminées avec ce numéro ne seront pas modifiées — seuls les futurs dépôts ne pourront plus y être dirigés.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Supprimer'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

class _EkDepositAccountDialog extends StatefulWidget {
  final EkDepositAccount? account;
  const _EkDepositAccountDialog({this.account});

  @override
  State<_EkDepositAccountDialog> createState() =>
      _EkDepositAccountDialogState();
}

class _EkDepositAccountDialogState extends State<_EkDepositAccountDialog> {
  late String _operator;
  late bool _primary;
  late bool _active;
  late final TextEditingController _phone;
  late final TextEditingController _label;
  String? _error;

  @override
  void initState() {
    super.initState();
    final a = widget.account;
    _operator = a?.operator ?? 'orange';
    _primary = a?.isPrimary ?? false;
    _active = a?.isActive ?? true;
    _phone = TextEditingController(text: a?.phoneNumber);
    _label = TextEditingController(text: a?.label);
  }

  @override
  void dispose() {
    _phone.dispose();
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        // AlertDialog tient déjà compte de MediaQuery.viewInsets. Avec
        // [scrollable], le titre et le formulaire partagent la hauteur restante
        // quand le clavier est ouvert, au lieu de laisser le Column déborder.
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        title: Text(widget.account == null
            ? 'Ajouter un numéro'
            : 'Modifier le numéro'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField(
            initialValue: _operator,
            decoration: const InputDecoration(labelText: 'Opérateur'),
            items: const ['orange', 'mtn', 'moov', 'wave']
                .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                .toList(),
            onChanged: (v) => setState(() => _operator = v!),
          ),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Numéro'),
          ),
          TextField(
            controller: _label,
            decoration:
                const InputDecoration(labelText: 'Libellé (facultatif)'),
          ),
          SwitchListTile(
            value: _primary,
            onChanged: (v) => setState(() => _primary = v),
            title: const Text('Numéro principal'),
          ),
          SwitchListTile(
            value: _active,
            onChanged: (v) => setState(() => _active = v),
            title: const Text('Actif'),
          ),
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              '⚠️ Ne communiquez jamais votre code PIN Mobile Money à qui que ce soit, y compris à l\'équipe AZ Express.',
              style: TextStyle(fontSize: 11),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12)),
            ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              final account = EkDepositAccount(
                id: widget.account?.id ??
                    DateTime.now().microsecondsSinceEpoch.toString(),
                operator: _operator,
                phoneNumber: _phone.text,
                label: _label.text.trim().isEmpty ? null : _label.text.trim(),
                isPrimary: _primary,
                isActive: _active,
              );
              if (!account.isValid) {
                setState(() => _error = 'Numéro invalide (8 chiffres minimum)');
                return;
              }
              Navigator.pop(context, account);
            },
            child: const Text('Valider'),
          ),
        ],
        actionsOverflowAlignment: OverflowBarAlignment.end,
      );
}
