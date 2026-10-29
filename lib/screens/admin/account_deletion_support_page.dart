import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

class AccountDeletionSupportPage extends StatefulWidget {
  const AccountDeletionSupportPage({super.key});
  @override
  State<AccountDeletionSupportPage> createState() => _AccountDeletionSupportPageState();
}

class _AccountDeletionSupportPageState extends State<AccountDeletionSupportPage> {
  final _call = FirebaseFunctions.instanceFor(region: 'europe-west1').httpsCallable('manageAccountDeletionCF');
  final List<Map<String, dynamic>> _items = [];
  String _kind = 'verified';
  String? _cursor, _error;
  bool _busy = false;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load({bool more = false}) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final response = await _call.call({'action':'list','kind':_kind,if(more) 'cursor':_cursor});
      final data = Map<String,dynamic>.from(response.data as Map);
      if (!mounted) return;
      setState(() { if(!more) _items.clear();
        _items.addAll((data['items'] as List).map((e)=>Map<String,dynamic>.from(e as Map)));
        _cursor = data['cursor'] as String?;
      });
    } catch (_) { if(mounted) setState(()=>_error='Lecture refusee ou indisponible. Aucune suppression confirmee.'); }
    finally { if(mounted) setState(()=>_busy=false); }
  }
  Future<void> _action(String id, String action) async {
    if(_busy) return;
    setState(() { _busy=true; _error=null; });
    try {
      await _call.call({'kind':_kind,'id':id,'action':action,if(action=='retry') 'resolution':'technical_retry'});
    } catch (_) { if(mounted) setState(()=>_error='Action non confirmee. Aucun contournement des obligations autorise.'); }
    finally { if(mounted) setState(()=>_busy=false); }
    if(mounted && _error==null) await _load();
  }
  /// Suppression manuelle (artisan, pharmacie historique, prestataire d'événements) : le serveur revérifie le téléphone
  /// et l'identité ; ici l'admin atteste seulement avoir vérifié le demandeur (méthode + note, journalisées).
  Future<void> _completeManual(String id) async {
    final note = TextEditingController();
    var method = 'callback';
    final ok = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) => AlertDialog(
      title: const Text('Finaliser la suppression'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Irréversible. Soldes et justificatifs financiers sont conservés ; identifiants, fichiers et données personnelles sont supprimés.'),
        DropdownButton<String>(value: method, isExpanded: true, onChanged: (v) => setLocal(() => method = v ?? method), items: const [
          DropdownMenuItem(value: 'callback', child: Text('Rappel au numéro du dossier')),
          DropdownMenuItem(value: 'in_person', child: Text('Présentation en personne')),
          DropdownMenuItem(value: 'document', child: Text('Pièce justificative vérifiée'))]),
        TextField(controller: note, maxLength: 300, decoration: const InputDecoration(labelText: 'Note de vérification (10 caractères min.)')),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Supprimer définitivement'))])));
    final text = note.text.trim();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    note.dispose();
    if (ok != true || !mounted || _busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final response = await FirebaseFunctions.instanceFor(region: 'europe-west1').httpsCallable('completeManualAccountDeletionCF')
          .call({'requestId': id, 'identityVerification': {'method': method, 'note': text}});
      final data = Map<String, dynamic>.from((response.data as Map)['data'] as Map);
      if (mounted && data['status'] != 'completed') setState(() => _error = 'Bloqué : ${data['reason'] ?? 'vérification requise'}. Aucune suppression effectuée.');
    } on FirebaseFunctionsException catch (e) {
      if (mounted) setState(() => _error = e.message ?? 'Suppression non confirmée.');
    } catch (_) {
      if (mounted) setState(() => _error = 'Suppression non confirmée. Aucune suppression annoncée.');
    } finally { if (mounted) setState(() => _busy = false); }
    if (mounted) await _load();
  }

  Future<void> _nominatePharmacyOwner() async {
    final uid=TextEditingController(), pharmacy=TextEditingController();
    final values=await showDialog<Map<String,String>>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Lier un responsable pharmacie'),
      content:Column(mainAxisSize:MainAxisSize.min,children:[
        const Text('Verifier son identite avant nomination. Le titulaire devra accepter avec son compte personnel. Aucune suppression ne sera effectuee.'),
        TextField(controller:uid,decoration:const InputDecoration(labelText:'UID Firebase du responsable')),
        TextField(controller:pharmacy,decoration:const InputDecoration(labelText:'Identifiant de la pharmacie')),
      ]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Annuler')),
        TextButton(onPressed:()=>Navigator.pop(ctx,{'uid':uid.text.trim(),'pharmacyId':pharmacy.text.trim()}),child:const Text('Nommer'))]));
    // Controllers stay alive through the dialog's closing animation.
    await Future<void>.delayed(const Duration(milliseconds:300));uid.dispose();pharmacy.dispose();
    if(values==null||!mounted)return;
    setState(()=>_busy=true);
    try {
      await FirebaseFunctions.instanceFor(region:'europe-west1').httpsCallable('managePharmacyOwnerIdentityCF').call({'action':'nominate',...values});
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Nomination enregistree. Acceptation personnelle encore requise.')));
    } catch (_) {if(mounted)setState(()=>_error='Nomination non confirmee. Reconnexion recente et verification des identifiants requises.');}
    finally {if(mounted)setState(()=>_busy=false);}
  }
  @override
  Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Text('Demandes de suppression')),
    body:Column(children:[
      const Padding(padding:EdgeInsets.all(12),child:Text('Regulariser les missions et soldes avec les procedures existantes. Reexaminer ne force jamais la suppression et ne modifie aucun montant.')),
      DropdownButton<String>(value:_kind,onChanged:_busy?null:(value){setState((){_kind=value!;_cursor=null;_items.clear();});_load();},items:const [
        DropdownMenuItem(value:'verified',child:Text('Demandes authentifiees')),
        DropdownMenuItem(value:'manual',child:Text('Demandes manuelles — identite a verifier'))]),
      if(_busy) const LinearProgressIndicator(),
      if(_error!=null) Text(_error!),
      TextButton(onPressed:_busy?null:_nominatePharmacyOwner,child:const Text('Nommer un responsable pharmacie')),
      Expanded(child:ListView(children:_items.map((item)=>ListTile(
        title:Text('${item['role']} — ${item['state']}'),
        subtitle:Text('${item['id']}\n${item['reason']??''}\n${item['supportState']}${item['overdue']==true?' — Revue en retard':''}'),
        trailing:Wrap(children:[
          TextButton(onPressed:_busy?null:()=>_action(item['id'] as String,'claim'),child:const Text('Prendre en charge')),
          if(_kind=='verified') TextButton(onPressed:_busy?null:()=>_action(item['id'] as String,'retry'),child:const Text('Reexaminer')),
          if(_kind=='manual' && const ['artisan','pharmacie','event_provider'].contains(item['role'])) TextButton(onPressed:_busy?null:()=>_completeManual(item['id'] as String),child:const Text('Finaliser')),
        ]),
      )).toList())),
      TextButton(onPressed:_busy?null:()=>_load(),child:const Text('Actualiser')),
      if(_cursor!=null) TextButton(onPressed:_busy?null:()=>_load(more:true),child:const Text('Suite')),
    ]),
  );
}
