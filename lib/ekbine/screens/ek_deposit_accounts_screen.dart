import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/ek_deposit_account.dart';
import '../providers/ek_provider.dart';
import '../services/ek_service.dart';
import '../utils/ek_deposit_accounts_logic.dart';
import '../widgets/ek_deposit_account_dialog.dart';

class EkDepositAccountsScreen extends StatefulWidget {
  const EkDepositAccountsScreen({super.key});
  @override
  State<EkDepositAccountsScreen> createState() =>
      _EkDepositAccountsScreenState();
}

class _EkDepositAccountsScreenState extends State<EkDepositAccountsScreen> {
  List<EkDepositAccount> _accounts = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _accounts = context.read<EkProvider>().myAgent?.depositAccounts ?? [];
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await EkService.updateDepositAccounts(_accounts);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  void _makePrimary(EkDepositAccount target) => setState(() {
        _accounts = _accounts
            .map((a) => a.operator == target.operator
                ? a.copyWith(isPrimary: a.id == target.id, isActive: true)
                : a)
            .toList();
      });

  Future<void> _edit([EkDepositAccount? existing]) async {
    final result =
        await showEkDepositAccountDialog(context, existing: existing);
    if (result == null) return;
    setState(() {
      _accounts = EkDepositAccountsLogic.merge(_accounts, result);
    });
  }

  // Master Prompt — Mission 2 : suppression d'un numéro de dépôt uniquement
  // après confirmation explicite. "Annuler" reste l'action par défaut du
  // dialogue (focus/premier bouton), rien n'est retiré tant que l'utilisateur
  // n'a pas explicitement appuyé sur "Supprimer". Le retrait local ici ne
  // devient réel qu'après le prochain appui sur "Enregistrer" (comme pour
  // toute autre modification de cette liste) — les anciennes commandes déjà
  // créées avec ce numéro (agentDepositNumber figé, voir ekbineAcceptOrder)
  // ne sont jamais modifiées par cette suppression.
  Future<void> _confirmDelete(EkDepositAccount account) async {
    final confirmed = await showEkDeleteAccountConfirmDialog(
      context,
      account,
      operatorLabel: EkService.operatorLabel(account.operator),
    );
    if (confirmed) {
      setState(() => _accounts.removeWhere((x) => x.id == account.id));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Mes numéros de dépôt'), actions: [
          TextButton(
              onPressed: _saving ? null : _save,
              child: const Text('Enregistrer'))
        ]),
        floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _edit(),
            icon: const Icon(Icons.add),
            label: const Text('Ajouter un numéro')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text(
              'Les clients effectueront leurs dépôts sur ces numéros. Vérifiez-les attentivement. Ne communiquez jamais votre code PIN.'),
          const SizedBox(height: 16),
          if (_accounts.isEmpty)
            const Text(
                'Aucun numéro actif : vous ne pourrez accepter aucune demande.'),
          ..._accounts.map((a) => Card(
                  child: ListTile(
                title: Text(
                    '${EkService.operatorLabel(a.operator)} · ${a.phoneNumber}'),
                subtitle: Text(
                    '${a.label ?? 'Sans libellé'} · ${a.isActive ? 'Actif' : 'Désactivé'}'),
                leading: Icon(
                    a.isActive ? Icons.phone_android : Icons.phone_disabled),
                trailing: Wrap(spacing: 2, children: [
                  if (a.isPrimary) const Chip(label: Text('Principal')),
                  IconButton(
                      icon: const Icon(Icons.edit), onPressed: () => _edit(a)),
                  IconButton(
                      icon: Icon(
                          a.isActive ? Icons.pause_circle : Icons.play_circle),
                      onPressed: () => setState(() => _accounts = _accounts
                          .map((x) => x.id == a.id
                              ? x.copyWith(isActive: !x.isActive)
                              : x)
                          .toList())),
                  IconButton(
                      icon: const Icon(Icons.star),
                      onPressed: () => _makePrimary(a)),
                  IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _confirmDelete(a)),
                ]),
              ))),
        ]),
      );
}
