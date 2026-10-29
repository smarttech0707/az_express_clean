import '../screens/home/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../services/account_deletion_service.dart';

typedef AccountDeletionSubmit = Future<AccountDeletionRequestResult> Function({
  required String role, required String contactPhone, String? reason,
});
Future<void> showAccountDeletionRequestDialog(BuildContext context, {
  required String role, String? initialPhone, AccountDeletionSubmit? submit,
}) async {
  final result = await showDialog<AccountDeletionRequestResult>(
    context: context, barrierDismissible: false,
    builder: (_) => AccountDeletionRequestDialog(role: role, initialPhone: initialPhone, submit: submit),
  );
  if (result != null && context.mounted && result.accessClosed) {
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => AccountDeletionStatusPage(initial: result)), (_) => false);
  } else if (result != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${result.message}\n${result.details}')));
  }
}

class AccountDeletionRequestDialog extends StatefulWidget {
  final String role;
  final String? initialPhone;
  final AccountDeletionSubmit? submit;
  const AccountDeletionRequestDialog({super.key, required this.role, this.initialPhone, this.submit});
  @override State<AccountDeletionRequestDialog> createState() => _AccountDeletionRequestDialogState();
}
class _AccountDeletionRequestDialogState extends State<AccountDeletionRequestDialog> {
  late final _phone = TextEditingController(text: widget.initialPhone ?? '');
  final _reason = TextEditingController();
  final _password = TextEditingController();
  bool _sending = false;
  String? _error;
  @override void dispose() { _phone.dispose(); _reason.dispose(); _password.dispose(); super.dispose(); }
  Future<void> _acceptPharmacyIdentity() async {
    if(_sending)return;
    setState((){_sending=true;_error=null;});
    try {
      final callable=FirebaseFunctions.instanceFor(region:'europe-west1').httpsCallable('managePharmacyOwnerIdentityCF');
      final preview=await callable.call({'action':'inspect'});
      if(!mounted)return;
      final confirmed=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('Confirmer le responsable personnel'),
        content:Text('Accepter la liaison de votre compte personnel avec la pharmacie ${preview.data['pharmacyId']} ? Cette operation ne supprime aucun compte.'),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Annuler')),
          TextButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Accepter'))]));
      if(confirmed==true){await callable.call({'action':'accept'});if(mounted)setState(()=>_error='Liaison confirmee. La demande de suppression reste une operation distincte.');}
    } catch (_) {if(mounted)setState(()=>_error='Liaison non confirmee. Une nomination admin et une connexion personnelle recente sont requises.');}
    finally {if(mounted)setState(()=>_sending=false);}
  }
  Future<void> _send() async {
    if (_sending) return;
    if (_phone.text.trim().isEmpty) {
      setState(() => _error = 'Indiquez le numero associe a votre compte.'); return;
    }
    setState(() { _sending = true; _error = null; });
    try {
      final result = widget.submit != null
        ? await widget.submit!(role: widget.role, contactPhone: _phone.text.trim(), reason: _reason.text.trim())
        : await AccountDeletionService.submitRequest(role: widget.role, contactPhone: _phone.text.trim(),
            reason: _reason.text.trim(), password: _password.text);
      if (!mounted) return;
      setState(() => _sending = false);
      Navigator.of(context).pop(result);
    } on FirebaseException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = ['wrong-password','invalid-credential','requires-recent-login'].contains(e.code)
          ? 'Reauthentification requise ou mot de passe incorrect. Aucune suppression confirmee.'
          : e.code == 'permission-denied'
          ? 'Demande refusee par le serveur. Contactez le support. Votre compte reste inchange.'
          : 'Enregistrement non confirme. Verifiez votre connexion ou contactez le support. '
            'Aucune suppression confirmee.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() { _sending = false; _error = 'Demande non confirmee. Verifiez les informations '
        'et reessayez. Aucune suppression confirmee.'; });
    }
  }
  @override Widget build(BuildContext context) => PopScope(
    canPop: !_sending,
    child: AlertDialog(
      title: const Text('Demander la suppression du compte'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('En envoyant cette demande, vous demandez la suppression du compte personnel et de tous ses profils lies. Un etablissement partage et ses donnees comptables ne sont pas automatiquement supprimes.'),
        Text(['client','livreur'].contains(widget.role)
          ? 'La demande sera conservee si un solde ou une mission bloque la suppression. Sans blocage, le serveur supprimera votre acces et traitera vos donnees personnelles. Les donnees transactionnelles necessaires seront conservees. La suppression definitive est irreversible.'
          : 'Le serveur verifiera votre identite et vos obligations. Une demande peut rester en attente de regularisation par le support. Seule une confirmation definitive signifie que le compte est supprime.'),
        if(widget.role=='pharmacie') TextButton(onPressed:_sending?null:_acceptPharmacyIdentity,child:const Text('Verifier mon invitation de responsable')),
        TextField(controller: _password, enabled: !_sending,
          obscureText: true, enableSuggestions: false, autocorrect: false,
          decoration: const InputDecoration(labelText: 'Mot de passe (confirmation si necessaire)')),
        const SizedBox(height: 16),
        TextField(controller: _phone, enabled: !_sending, keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Numero de telephone')),
        TextField(controller: _reason, enabled: !_sending,
          decoration: const InputDecoration(labelText: 'Raison (optionnel)')),
        if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
      ])),
      actions: [
        TextButton(onPressed: _sending ? null : () => Navigator.pop(context), child: const Text('Annuler')),
        ElevatedButton(onPressed: _sending ? null : _send,
          child: _sending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator())
            : const Text('Envoyer la demande')),
      ],
    ),
  );
}

class AccountDeletionStatusPage extends StatefulWidget {
  final AccountDeletionRequestResult initial;
  const AccountDeletionStatusPage({super.key,required this.initial});
  @override State<AccountDeletionStatusPage> createState()=>_AccountDeletionStatusPageState();
}
class _AccountDeletionStatusPageState extends State<AccountDeletionStatusPage> {
  late AccountDeletionRequestResult result=widget.initial;
  bool loading=false;String? error;
  Future<void> refresh() async {
    if(loading)return;setState((){loading=true;error=null;});
    try{final next=await AccountDeletionService.checkLastRequest();if(mounted)setState(()=>result=next);}
    catch(_){if(mounted)setState(()=>error='Verification indisponible. Aucune nouvelle confirmation de suppression.');}
    finally{if(mounted)setState(()=>loading=false);}
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Suivi de suppression')),
    body:Padding(padding:const EdgeInsets.all(24),child:Column(children:[
      Text(result.message),const SizedBox(height:16),Text(result.details),
      if(error!=null)Text(error!),
      ElevatedButton(onPressed:loading?null:refresh,child:Text(loading?'Verification...':'Verifier le traitement')),
      TextButton(onPressed:()=>Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder:(_)=>const HomeScreen()),(_)=>false),child:const Text('Retour accueil')),
    ])));
}
