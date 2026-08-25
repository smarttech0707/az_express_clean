import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart' show FieldValue;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/real_estate_agent.dart';
import '../../models/real_estate_listing.dart';
import '../../models/real_estate_property_type.dart';
import '../../models/real_estate_visit_request.dart';
import '../../services/real_estate_service.dart';
import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';
import '../home/home_screen.dart';
import '../../widgets/immobilier/property_details_form_section.dart';
import '../../widgets/partner_account_sheet.dart';
import '../../widgets/stream_error_state.dart';
import '../../widgets/logout_confirm_dialog.dart';

class AgentDashboardScreen extends StatefulWidget {
  const AgentDashboardScreen({super.key});

  @override
  State<AgentDashboardScreen> createState() => _AgentDashboardScreenState();
}

class _AgentDashboardScreenState extends State<AgentDashboardScreen> {
  RealEstateAgent? _agent;
  bool _loading = true;
  bool _requestSent = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() => _loading = false);
      return;
    }
    final agent = await RealEstateService.getAgent(uid);
    if (mounted)
      setState(() {
        _agent = agent;
        _loading = false;
      });
  }

  // Master Prompt 135 — _logout() affiche désormais une confirmation avant
  // d'appeler _doLogout(), qui porte l'intégralité de la logique déjà
  // existante et inchangée (signOut, redirection).
  void _logout() => showLogoutConfirmDialog(context, onConfirm: _doLogout);

  Future<void> _doLogout() async {
    AuthService().logAuthEvent('logout', 'real_estate_agent');
    await FirebaseAuth.instance.signOut();
    try {
      await FirebaseAuth.instance.signInAnonymously();
    } catch (_) {}
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Espace agent immobilier'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
        actions: [
          if (_agent != null)
            IconButton(
              icon: const Icon(Icons.account_circle_outlined),
              tooltip: 'Mon compte',
              onPressed: () => showPartnerAccountSheet(
                context,
                role: 'real_estate_agent',
                roleLabel: 'Agent immobilier',
                name: _agent!.name,
                phone: _agent!.phone,
                onLogout: _logout,
                photoUrl: _agent!.photoUrl,
                photoStoragePath:
                    'real_estate_agent_photos/${_agent!.uid}/profile.jpg',
                onPhotoUploaded: (url) async {
                  await RealEstateService.updateAgentPhoto(_agent!.uid, url);
                  if (mounted) {
                    setState(() => _agent = RealEstateAgent(
                          uid: _agent!.uid,
                          name: _agent!.name,
                          phone: _agent!.phone,
                          agencyName: _agent!.agencyName,
                          city: _agent!.city,
                          photoUrl: url,
                          isVerified: _agent!.isVerified,
                          isActive: _agent!.isActive,
                          createdAt: _agent!.createdAt,
                        ));
                  }
                },
                onPhotoDeleted: () async {
                  await RealEstateService.updateAgentPhoto(_agent!.uid, null);
                  if (mounted) {
                    setState(() => _agent = RealEstateAgent(
                          uid: _agent!.uid,
                          name: _agent!.name,
                          phone: _agent!.phone,
                          agencyName: _agent!.agencyName,
                          city: _agent!.city,
                          isVerified: _agent!.isVerified,
                          isActive: _agent!.isActive,
                          createdAt: _agent!.createdAt,
                        ));
                  }
                },
              ),
            ),
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            tooltip: 'Déconnexion',
            onPressed: _logout,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_agent == null)
              ? _AgentRequestForm(
                  sent: _requestSent,
                  onSent: () => setState(() => _requestSent = true))
              : (!_agent!.isVerified || !_agent!.isActive)
                  ? const _PendingApprovalMessage()
                  : _AgentDashboard(agent: _agent!),
    );
  }
}

class _AgentRequestForm extends StatefulWidget {
  final bool sent;
  final VoidCallback onSent;
  const _AgentRequestForm({required this.sent, required this.onSent});

  @override
  State<_AgentRequestForm> createState() => _AgentRequestFormState();
}

class _AgentRequestFormState extends State<_AgentRequestForm> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _agencyCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _agencyCtrl.dispose();
    _cityCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_nameCtrl.text.trim().isEmpty || _phoneCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Nom et téléphone requis'),
            backgroundColor: Colors.orange),
      );
      return;
    }
    setState(() => _sending = true);
    try {
      await RealEstateService.submitAgentRequest(
        name: _nameCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        agencyName:
            _agencyCtrl.text.trim().isEmpty ? null : _agencyCtrl.text.trim(),
        city: _cityCtrl.text.trim().isEmpty ? null : _cityCtrl.text.trim(),
      );
      widget.onSent();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Erreur : $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sent) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.hourglass_top_rounded,
                  size: 56, color: AppColors.primary),
              const SizedBox(height: 16),
              const Text('Demande envoyée',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 8),
              Text('Un administrateur va examiner votre demande.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600)),
            ],
          ),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Devenir agent immobilier',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('Publiez vos annonces sur AZ Express après validation.',
              style: TextStyle(color: Colors.grey.shade600)),
          const SizedBox(height: 20),
          TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Nom complet')),
          const SizedBox(height: 12),
          TextField(
              controller: _phoneCtrl,
              decoration: const InputDecoration(labelText: 'Téléphone'),
              keyboardType: TextInputType.phone),
          const SizedBox(height: 12),
          TextField(
              controller: _agencyCtrl,
              decoration: const InputDecoration(
                  labelText: 'Nom de l\'agence (optionnel)')),
          const SizedBox(height: 12),
          TextField(
              controller: _cityCtrl,
              decoration:
                  const InputDecoration(labelText: 'Ville (optionnel)')),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _sending ? null : _submit,
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              child: _sending
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Text('Envoyer la demande'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PendingApprovalMessage extends StatelessWidget {
  const _PendingApprovalMessage();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.hourglass_top_rounded,
                size: 56, color: AppColors.primary),
            SizedBox(height: 16),
            Text('Compte en attente de validation',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
      ),
    );
  }
}

class _AgentDashboard extends StatelessWidget {
  final RealEstateAgent agent;
  const _AgentDashboard({required this.agent});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            labelColor: AppColors.primary,
            unselectedLabelColor: Colors.grey,
            indicatorColor: AppColors.primary,
            tabs: [Tab(text: 'Mes annonces'), Tab(text: 'Demandes de visite')],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _MyListingsTab(agentId: agent.uid),
                _VisitRequestsTab(agentId: agent.uid),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MyListingsTab extends StatelessWidget {
  final String agentId;
  const _MyListingsTab({required this.agentId});

  Future<void> _openAddListing(BuildContext context) async {
    await Navigator.push(context,
        AppTransitions.fadeSlide(_ListingFormScreen(agentId: agentId)));
  }

  /// Master Prompt "Immobilier V6.2" — Mission 3 : action "Modifier". La
  /// liste de cette page est déjà scopée à l'agent courant
  /// (`streamByAgent(agentId)`, `agentId` provenant de `FirebaseAuth`, jamais
  /// d'un autre agent) — aucune annonce d'un tiers n'apparaît jamais ici,
  /// donc ce bouton ne peut structurellement jamais cibler l'annonce d'un
  /// autre agent. La protection réelle contre un contournement (appel direct
  /// hors de cette UI) reste côté Firestore Rules (`resource.data.agentId ==
  /// uid()`), inchangée par cette passe — pas dupliquée ici inutilement.
  Future<void> _openEditListing(
      BuildContext context, RealEstateListing listing) async {
    await Navigator.push(
        context,
        AppTransitions.fadeSlide(
            _ListingFormScreen(agentId: agentId, existingListing: listing)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openAddListing(context),
        backgroundColor: AppColors.primary,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('Ajouter', style: TextStyle(color: Colors.white)),
      ),
      body: StreamBuilder<List<RealEstateListing>>(
        stream: RealEstateService.streamByAgent(agentId),
        builder: (context, snap) {
          if (snap.hasError) {
            return const StreamErrorState(
                message: "Impossible de charger vos annonces.");
          }
          if (!snap.hasData)
            return const Center(child: CircularProgressIndicator());
          final listings = snap.data!;
          if (listings.isEmpty) {
            return Center(
                child: Text('Aucune annonce — ajoutez-en une.',
                    style: TextStyle(color: Colors.grey.shade600)));
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
            itemCount: listings.length,
            itemBuilder: (context, i) {
              final l = listings[i];
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text(l.title),
                  subtitle: Text(
                      '${l.price} FCFA · ${l.status == 'active' ? 'Active' : 'Masquée'}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: 'Modifier',
                        onPressed: () => _openEditListing(context, l),
                      ),
                      IconButton(
                        icon: Icon(l.status == 'active'
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined),
                        onPressed: () => l.status == 'active'
                            ? RealEstateService.softDelete(l.id)
                            : RealEstateService.reactivate(l.id),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ListingFormScreen extends StatefulWidget {
  final String agentId;

  /// Master Prompt "Immobilier V6.2" — Mission 2 : `null` = création (flux
  /// déjà validé en V6/V6.1, inchangé) ; non-null = édition d'une annonce
  /// déjà existante et déjà possédée par cet agent (voir le commentaire de
  /// `_openEditListing`, seul point d'entrée réel vers ce mode).
  final RealEstateListing? existingListing;

  const _ListingFormScreen({required this.agentId, this.existingListing});

  @override
  State<_ListingFormScreen> createState() => _ListingFormScreenState();
}

class _ListingFormScreenState extends State<_ListingFormScreen> {
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  // Master Prompt "Immobilier V6" — Mission 2 : toute NOUVELLE annonce
  // utilise désormais les valeurs canoniques (`RealEstatePropertyType`),
  // jamais les anciens libellés français en dur — mais ces derniers restent
  // lisibles/filtrables pour les annonces déjà créées (voir le modèle).
  String _propertyType = RealEstatePropertyType.house;
  String _priceType = 'sale';
  // Master Prompt "GPS privé V2" — aucune valeur par défaut : force l'agent
  // à choisir explicitement, jamais une confidentialité devinée pour lui.
  String? _locationPrivacy;
  bool _saving = false;
  final List<XFile> _pickedImages = [];
  String? _uploadStatus;
  final _propertyDetails = PropertyDetailsFormController();

  // ── Master Prompt "Immobilier V6.2" — état propre au mode édition ────────
  bool get _isEditing => widget.existingListing != null;
  RealEstateListing? get _existing => widget.existingListing;

  /// Photos déjà en ligne (URLs) — réordonnables/supprimables (Mission 8).
  /// Séparé de `_pickedImages` (nouveaux fichiers locaux pas encore
  /// uploadés) : les deux listes sont fusionnées uniquement au moment de
  /// construire le tableau `images` final envoyé à Firestore.
  final List<String> _existingImageUrls = [];

  /// URLs retirées par l'agent — supprimées de Storage seulement APRÈS
  /// confirmation que la sauvegarde Firestore a réussi (Mission 8).
  final List<String> _removedImageUrls = [];

  /// Liens vidéo externes — un contrôleur par lien, Mission 8.
  final List<TextEditingController> _videoCtrls = [];

  /// Mission 7 : la position/confidentialité n'est renvoyée au serveur que
  /// si l'agent l'a explicitement modifiée pendant CETTE édition — jamais
  /// automatiquement à chaque sauvegarde (économise un appel Cloud Function
  /// et une lecture GPS inutiles, et surtout ne perturbe jamais un accès
  /// privé déjà accordé après visite si rien n'a changé).
  bool _locationPrivacyTouched = false;

  @override
  void initState() {
    super.initState();
    final existing = _existing;
    if (existing == null) return;
    _titleCtrl.text = existing.title;
    _descCtrl.text = existing.description;
    _priceCtrl.text = existing.price.toString();
    _cityCtrl.text = existing.city;
    _propertyType = existing.propertyType;
    _priceType = existing.priceType;
    _locationPrivacy = existing.locationPrivacy;
    _propertyDetails.loadFrom(existing);
    _existingImageUrls.addAll(existing.images);
    for (final v in existing.videos) {
      _videoCtrls.add(TextEditingController(text: v));
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _priceCtrl.dispose();
    _cityCtrl.dispose();
    _propertyDetails.dispose();
    for (final c in _videoCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  int get _totalMediaCount => _existingImageUrls.length + _pickedImages.length;

  Future<void> _pickImages() async {
    if (_totalMediaCount >= 10) return;
    try {
      final files =
          await ImagePicker().pickMultiImage(imageQuality: 70, maxWidth: 1600);
      if (files.isEmpty) return;
      setState(() => _pickedImages.addAll(files.take(10 - _totalMediaCount)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Impossible d\'accéder à la galerie.'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  void _removeExistingImage(int index) {
    setState(() => _removedImageUrls.add(_existingImageUrls.removeAt(index)));
  }

  void _moveExistingImage(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _existingImageUrls.length) return;
    setState(() {
      final item = _existingImageUrls.removeAt(index);
      _existingImageUrls.insert(target, item);
    });
  }

  void _addVideoField() =>
      setState(() => _videoCtrls.add(TextEditingController()));

  void _removeVideoField(int index) {
    setState(() => _videoCtrls.removeAt(index).dispose());
  }

  /// Mission 9 : validation d'URL simple mais réelle — un lien vidéo doit
  /// être une URL http(s) exploitable, jamais un texte arbitraire silencieux.
  String? _validateVideoUrls() {
    for (final c in _videoCtrls) {
      final text = c.text.trim();
      if (text.isEmpty) continue;
      final uri = Uri.tryParse(text);
      if (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http')) {
        return 'Lien vidéo invalide : "$text"';
      }
    }
    return null;
  }

  List<String> get _videoUrls =>
      _videoCtrls.map((c) => c.text.trim()).where((s) => s.isNotEmpty).toList();

  /// Master Prompt "Immobilier V6.2" — Mission 9 : point d'entrée unique du
  /// bouton Enregistrer/Publier — délègue au flux de création (déjà validé
  /// V6/V6.1, quasi inchangé) ou d'édition (nouveau, Missions 2-9) selon
  /// [_isEditing]. Un seul formulaire, jamais un second système divergent.
  Future<void> _save() => _isEditing ? _saveEdit() : _saveCreate();

  /// Validations communes aux deux modes — un message par défaut manquant
  /// ou invalide, jamais un échec silencieux. Retourne un message d'erreur
  /// ou `null` si tout est valide.
  String? _validateCommonFields(String title, int? price) {
    if (title.isEmpty || price == null || price <= 0) {
      return 'Titre et prix valides requis';
    }
    // Mission 3 (V6) : "Terrain → superficie obligatoire" — reste valable
    // pour le NOUVEAU type choisi, y compris en édition (Mission 5, V6.2).
    if (RealEstatePropertyType.isLand(_propertyType) &&
        !_propertyDetails.hasSurfaceTerrain) {
      return 'La superficie du terrain est obligatoire';
    }
    final videoError = _validateVideoUrls();
    if (videoError != null) return videoError;
    if (_totalMediaCount > 10) return 'Maximum 10 photos par annonce';
    return null;
  }

  // Master Prompt "GPS privé V2" — création en DEUX étapes, jamais les
  // coordonnées directement dans le document public (bloqué de toute façon
  // par les Rules) :
  //   1) créer l'annonce, TOUJOURS en `status: 'hidden'` au départ — jamais
  //      publique tant que la localisation n'est pas confirmée ;
  //   2) appeler upsertRealEstateLocation (Cloud Function) avec la position
  //      GPS réelle et le choix de confidentialité ;
  //   3) seulement si l'étape 2 réussit, republier via `reactivate()`
  //      (`status: 'active'`) — déjà une valeur d'enum existante, aucun
  //      nouveau statut "brouillon" inventé (aucun ne l'est dans le schéma
  //      réel : `status` ne vaut que 'active'/'hidden').
  // Si l'étape 2 échoue, l'annonce déjà créée (titre/prix/photos) N'EST PAS
  // perdue mais reste masquée — message clair affiché, pas de silence.
  Future<void> _saveCreate() async {
    final title = _titleCtrl.text.trim();
    final price = int.tryParse(_priceCtrl.text.trim());
    final commonError = _validateCommonFields(title, price);
    if (commonError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(commonError), backgroundColor: Colors.orange));
      return;
    }
    if (_locationPrivacy == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Choisissez un niveau de confidentialité de position'),
            backgroundColor: Colors.orange),
      );
      return;
    }
    setState(() {
      _saving = true;
      _uploadStatus = null;
    });
    try {
      Position? position;
      try {
        position = await Geolocator.getCurrentPosition(
            locationSettings:
                const LocationSettings(accuracy: LocationAccuracy.medium));
      } catch (_) {}

      if (position == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Position GPS indisponible — activez la localisation puis réessayez.'),
              backgroundColor: Colors.red));
        }
        return;
      }

      final city = _cityCtrl.text.trim();
      final detailsFields =
          _propertyDetails.toListingFieldsForCreate(_propertyType);
      final listing = RealEstateListing(
        id: '',
        agentId: widget.agentId,
        title: title,
        description: _descCtrl.text.trim(),
        price: price!,
        priceType: _priceType,
        propertyType: _propertyType,
        furnished:
            RealEstatePropertyType.isFurnishedResidenceType(_propertyType),
        city: city,
        status: 'hidden',
        videos: _videoUrls,
      );
      // Mission 2/3 : champs additionnels fusionnés dans le même payload de
      // création — additif, ne modifie jamais la logique GPS en deux étapes
      // ci-dessous (aucun champ de localisation dans `detailsFields`).
      final listingId = await RealEstateService.addListing(
          {...listing.toMap(), ...detailsFields});

      if (_pickedImages.isNotEmpty) {
        final urls = <String>[];
        for (var i = 0; i < _pickedImages.length; i++) {
          if (mounted) {
            setState(() => _uploadStatus =
                'Envoi des photos ${i + 1}/${_pickedImages.length}…');
          }
          urls.add(await RealEstateService.uploadImage(
              _pickedImages[i], listingId, i));
        }
        await RealEstateService.updateListing(listingId, {'images': urls});
      }

      if (mounted)
        setState(() => _uploadStatus = 'Confirmation de la position…');
      try {
        await RealEstateService.upsertLocation(
          listingId: listingId,
          latitude: position.latitude,
          longitude: position.longitude,
          locationPrivacy: _locationPrivacy!,
          city: city.isNotEmpty ? city : null,
        );
        await RealEstateService.reactivate(listingId);
        if (mounted) Navigator.pop(context);
      } catch (e) {
        // Étape 2 échouée : l'annonce existe déjà (titre/prix/photos
        // conservés) mais reste `hidden` — jamais publiée sans localisation
        // confirmée. On informe clairement plutôt que de faire disparaître
        // le travail déjà fait ou de masquer l'échec.
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Annonce enregistrée mais localisation à compléter (erreur : $e). '
                'Elle reste masquée tant que la position n\'est pas confirmée.'),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 6),
          ));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Erreur : $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Master Prompt "Immobilier V6.2" — Mission 4/6/7/8/9 : édition complète.
  /// `.update()` (jamais un `.set()` sans merge) — préserve implicitement
  /// tout champ système non mentionné ici (`agentId`, `createdAt`, `views`,
  /// `status`) : ce sont les Rules elles-mêmes qui interdisent déjà de les
  /// modifier depuis ce chemin (`unchanged('agentId')`, et `createdAt` après
  /// le durcissement de la Mission 11), donc ce formulaire ne les inclut
  /// jamais dans le payload envoyé, par construction.
  Future<void> _saveEdit() async {
    final existing = _existing!;
    final title = _titleCtrl.text.trim();
    final price = int.tryParse(_priceCtrl.text.trim());
    final commonError = _validateCommonFields(title, price);
    if (commonError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(commonError), backgroundColor: Colors.orange));
      return;
    }
    final city = _cityCtrl.text.trim();

    // Mission 9 : "ne pas envoyer une mise à jour si aucune donnée n'a changé".
    final typeChanged = _propertyType != existing.propertyType;
    final textChanged = title != existing.title ||
        _descCtrl.text.trim() != existing.description ||
        price != existing.price ||
        _priceType != existing.priceType ||
        city != existing.city;
    final imagesChanged = !listEquals(_existingImageUrls, existing.images) ||
        _pickedImages.isNotEmpty;
    final videosChanged = !listEquals(_videoUrls, existing.videos);
    final characteristicsChanged = _propertyDetails.hasChangesFrom(existing);
    final anyChange = typeChanged ||
        textChanged ||
        imagesChanged ||
        videosChanged ||
        characteristicsChanged ||
        _locationPrivacyTouched;

    if (!anyChange) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Aucune modification à enregistrer')));
      return;
    }

    setState(() {
      _saving = true;
      _uploadStatus = null;
    });
    try {
      final newUrls = <String>[];
      for (var i = 0; i < _pickedImages.length; i++) {
        if (mounted) {
          setState(() => _uploadStatus =
              'Envoi des photos ${i + 1}/${_pickedImages.length}…');
        }
        newUrls.add(await RealEstateService.uploadEditedImage(
            _pickedImages[i], existing.id));
      }
      final finalImages = [..._existingImageUrls, ...newUrls];

      final updateMap = <String, dynamic>{
        'title': title,
        'description': _descCtrl.text.trim(),
        'price': price,
        'priceType': _priceType,
        'propertyType': _propertyType,
        'furnished':
            RealEstatePropertyType.isFurnishedResidenceType(_propertyType),
        'city': city,
        'images': finalImages,
        'videos': _videoUrls,
        'updatedAt': FieldValue.serverTimestamp(),
        // Mission 5/6 : nettoie explicitement (FieldValue.delete()) tout
        // champ incompatible avec le NOUVEAU type — même si le type n'a pas
        // changé, réaffirme les valeurs actuelles pour les champs autorisés.
        ..._propertyDetails.toListingFieldsForUpdate(_propertyType),
      };

      if (mounted) setState(() => _uploadStatus = 'Enregistrement…');
      await RealEstateService.updateListing(existing.id, updateMap);

      // Mission 8 : suppression Storage best-effort UNIQUEMENT après le
      // succès de la mise à jour Firestore ci-dessus — jamais avant.
      for (final url in _removedImageUrls) {
        await RealEstateService.deleteImageByUrl(url);
      }

      // Mission 7 : la localisation n'est retouchée que si l'agent l'a
      // explicitement changée pendant cette édition, ou si l'annonce n'en
      // avait encore aucune (Mission 10 : annonce héritée jamais géolocalisée).
      var locationWarning = false;
      final needsLocationUpsert =
          _locationPrivacyTouched || existing.locationPrivacy == null;
      if (needsLocationUpsert) {
        if (_locationPrivacy == null) {
          locationWarning = true;
        } else {
          if (mounted) {
            setState(() => _uploadStatus = 'Confirmation de la position…');
          }
          try {
            Position? position;
            try {
              position = await Geolocator.getCurrentPosition(
                  locationSettings: const LocationSettings(
                      accuracy: LocationAccuracy.medium));
            } catch (_) {}
            if (position == null) {
              locationWarning = true;
            } else {
              await RealEstateService.upsertLocation(
                listingId: existing.id,
                latitude: position.latitude,
                longitude: position.longitude,
                locationPrivacy: _locationPrivacy!,
                city: city.isNotEmpty ? city : null,
              );
            }
          } catch (_) {
            locationWarning = true;
          }
        }
      }

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(locationWarning
              ? 'Annonce mise à jour, mais la position n\'a pas pu être confirmée.'
              : 'Annonce mise à jour.'),
          backgroundColor: locationWarning ? Colors.orange : Colors.green,
        ));
      }
    } catch (e) {
      // Mission 3 : erreur réseau/permission-denied/document introuvable —
      // toujours affichée clairement, jamais silencieuse.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Erreur : $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(_isEditing ? 'Modifier l\'annonce' : 'Nouvelle annonce'),
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
                controller: _titleCtrl,
                decoration: const InputDecoration(labelText: 'Titre')),
            const SizedBox(height: 12),
            TextField(
                controller: _descCtrl,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Description')),
            const SizedBox(height: 12),
            TextField(
                controller: _priceCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Prix (FCFA)')),
            const SizedBox(height: 12),
            TextField(
                controller: _cityCtrl,
                decoration:
                    const InputDecoration(labelText: 'Ville / quartier')),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              // Master Prompt "Immobilier V6.2" — Mission 10 : bug réel
              // trouvé en préparant l'édition — une annonce ANCIENNE peut
              // avoir un `propertyType` en texte libre français ("Villa",
              // jamais l'une des 10 valeurs canoniques de
              // `RealEstatePropertyType.all`). Sans cet ajout, ouvrir le
              // formulaire d'édition sur une telle annonce aurait fait
              // planter ce Dropdown (`initialValue` sans item correspondant)
              // — corrigé en injectant la valeur héritée comme item
              // supplémentaire, jamais en la forçant vers une valeur
              // canonique devinée (qui pourrait être fausse).
              initialValue: _propertyType,
              decoration: const InputDecoration(labelText: 'Type de bien'),
              items: [
                ...RealEstatePropertyType.all.map((t) => DropdownMenuItem(
                    value: t, child: Text(RealEstatePropertyType.label(t)))),
                if (!RealEstatePropertyType.all.contains(_propertyType))
                  DropdownMenuItem(
                      value: _propertyType,
                      child: Text(RealEstatePropertyType.label(_propertyType))),
              ],
              onChanged: (v) =>
                  setState(() => _propertyType = v ?? _propertyType),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: RadioListTile<String>(
                    title: const Text('Vente'),
                    value: 'sale',
                    groupValue: _priceType,
                    onChanged: (v) => setState(() => _priceType = v ?? 'sale'),
                  ),
                ),
                Expanded(
                  child: RadioListTile<String>(
                    title: const Text('Location'),
                    value: 'rent',
                    groupValue: _priceType,
                    onChanged: (v) => setState(() => _priceType = v ?? 'rent'),
                  ),
                ),
              ],
            ),
            PropertyDetailsFormSection(
              propertyType: _propertyType,
              controller: _propertyDetails,
            ),
            const SizedBox(height: 16),
            const Text('Confidentialité de la position',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 4),
            Text(
                _isEditing
                    ? 'Laissez tel quel pour conserver la position déjà '
                        'enregistrée — ne sélectionnez une option ci-dessous '
                        'QUE pour la remplacer par votre position actuelle.'
                    : 'Votre position GPS actuelle sera utilisée. Choisissez '
                        'ce que les clients voient sur l\'annonce publique :',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            _LocationPrivacyOption(
              value: 'exact',
              groupValue: _locationPrivacy,
              title: 'Position exacte',
              subtitle: 'L\'adresse précise du bien est visible publiquement.',
              onChanged: (v) => setState(() {
                _locationPrivacy = v;
                _locationPrivacyTouched = true;
              }),
            ),
            _LocationPrivacyOption(
              value: 'approximate',
              groupValue: _locationPrivacy,
              title: 'Position approximative',
              subtitle:
                  'Seule la zone/quartier est visible (~2 à 5 km) — jamais l\'adresse exacte.',
              onChanged: (v) => setState(() {
                _locationPrivacy = v;
                _locationPrivacyTouched = true;
              }),
            ),
            _LocationPrivacyOption(
              value: 'hidden',
              groupValue: _locationPrivacy,
              title: 'Position masquée',
              subtitle:
                  'Aucune coordonnée publique — visible uniquement après confirmation d\'une visite.',
              onChanged: (v) => setState(() {
                _locationPrivacy = v;
                _locationPrivacyTouched = true;
              }),
            ),
            const SizedBox(height: 16),
            Text('Photos ($_totalMediaCount/10)',
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 8),
            SizedBox(
              height: 90,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  // Master Prompt "Immobilier V6.2" — Mission 8 : photos déjà
                  // en ligne, réordonnables (flèches) et supprimables (X) —
                  // jamais réuploadées, jamais supprimées de Storage avant la
                  // confirmation de sauvegarde (voir `_saveEdit`).
                  for (var i = 0; i < _existingImageUrls.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: CachedNetworkImage(
                              imageUrl: _existingImageUrls[i],
                              width: 90,
                              height: 90,
                              fit: BoxFit.cover,
                              placeholder: (_, __) =>
                                  Container(color: AppColors.primaryBg),
                              errorWidget: (_, __, ___) => Container(
                                  color: AppColors.primaryBg,
                                  child:
                                      const Icon(Icons.broken_image_outlined)),
                            ),
                          ),
                          Positioned(
                            top: 2,
                            right: 2,
                            child: GestureDetector(
                              onTap: () => _removeExistingImage(i),
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: const BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle),
                                child: const Icon(Icons.close_rounded,
                                    size: 16, color: Colors.white),
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 2,
                            left: 2,
                            child: Row(children: [
                              if (i > 0)
                                _ReorderChip(
                                    icon: Icons.chevron_left_rounded,
                                    onTap: () => _moveExistingImage(i, -1)),
                              if (i < _existingImageUrls.length - 1)
                                _ReorderChip(
                                    icon: Icons.chevron_right_rounded,
                                    onTap: () => _moveExistingImage(i, 1)),
                            ]),
                          ),
                        ],
                      ),
                    ),
                  for (var i = 0; i < _pickedImages.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.file(File(_pickedImages[i].path),
                                width: 90, height: 90, fit: BoxFit.cover),
                          ),
                          Positioned(
                            top: 2,
                            right: 2,
                            child: GestureDetector(
                              onTap: () =>
                                  setState(() => _pickedImages.removeAt(i)),
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: const BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle),
                                child: const Icon(Icons.close_rounded,
                                    size: 16, color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_totalMediaCount < 10)
                    GestureDetector(
                      onTap: _pickImages,
                      child: Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          color: AppColors.primaryBg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: AppColors.primary.withValues(alpha: 0.4)),
                        ),
                        child: Icon(Icons.add_a_photo_rounded,
                            color: AppColors.primary),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text('Vidéos (liens externes)',
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 4),
            const Text(
                'Lien YouTube ou autre — pas d\'hébergement vidéo natif dans '
                'AZ Express, la vidéo s\'ouvre dans une autre application.',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            for (var i = 0; i < _videoCtrls.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _videoCtrls[i],
                      decoration: InputDecoration(
                          labelText: 'Lien vidéo ${i + 1}',
                          hintText: 'https://…'),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () => _removeVideoField(i),
                  ),
                ]),
              ),
            TextButton.icon(
              onPressed: _addVideoField,
              icon: const Icon(Icons.add_link_rounded),
              label: const Text('Ajouter un lien vidéo'),
            ),
            if (_uploadStatus != null) ...[
              const SizedBox(height: 10),
              Row(children: [
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text(_uploadStatus!, style: const TextStyle(fontSize: 13)),
              ]),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                child: _saving
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Text(_isEditing
                        ? 'Enregistrer les modifications'
                        : 'Publier l\'annonce'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Petite puce de réordonnancement (Mission 8) — volontairement des flèches
/// gauche/droite plutôt qu'un glisser-déposer : plus fiable à tester et à
/// utiliser sur un petit écran (Galaxy A11) qu'un `ReorderableListView`
/// horizontal, qui exige une zone de contrôle de drag précise sur mobile.
class _ReorderChip extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _ReorderChip({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(2),
        margin: const EdgeInsets.only(right: 2),
        decoration:
            const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
        child: Icon(icon, size: 16, color: Colors.white),
      ),
    );
  }
}

/// Option de confidentialité de position — même style que les
/// `RadioListTile` déjà utilisés dans ce formulaire, mais avec une
/// explication visible sous chaque choix (Mission 13 : "explication claire
/// de chaque choix").
class _LocationPrivacyOption extends StatelessWidget {
  final String value;
  final String? groupValue;
  final String title;
  final String subtitle;
  final ValueChanged<String?> onChanged;

  const _LocationPrivacyOption({
    required this.value,
    required this.groupValue,
    required this.title,
    required this.subtitle,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final selected = value == groupValue;
    return Semantics(
      button: true,
      selected: selected,
      label: '$title. $subtitle',
      child: RadioListTile<String>(
        value: value,
        groupValue: groupValue,
        onChanged: onChanged,
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}

class _VisitRequestsTab extends StatelessWidget {
  final String agentId;
  const _VisitRequestsTab({required this.agentId});

  Future<void> _propose(BuildContext context, String requestId) async {
    final dateCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Proposer une date'),
        content: TextField(
            controller: dateCtrl,
            decoration:
                const InputDecoration(labelText: 'Date/heure proposée')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Proposer')),
        ],
      ),
    );
    if (confirmed != true || dateCtrl.text.trim().isEmpty) return;
    await RealEstateService.respondToVisit(
        requestId: requestId,
        action: 'propose',
        proposedDate: dateCtrl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<RealEstateVisitRequest>>(
      stream: RealEstateService.visitRequestsAsAgent(agentId),
      builder: (context, snap) {
        if (snap.hasError) {
          return const StreamErrorState(
              message: "Impossible de charger les demandes de visite.");
        }
        if (!snap.hasData)
          return const Center(child: CircularProgressIndicator());
        final requests = snap.data!;
        if (requests.isEmpty) {
          return Center(
              child: Text('Aucune demande de visite',
                  style: TextStyle(color: Colors.grey.shade600)));
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: requests.length,
          itemBuilder: (context, i) {
            final r = requests[i];
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Text(r.listingTitle ?? r.listingId),
                subtitle: Text(
                    'Statut : ${r.status}${r.preferredDate != null ? ' · Souhaité : ${r.preferredDate}' : ''}'),
                trailing: r.status == 'pending'
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.event_available,
                                color: AppColors.primary),
                            tooltip: 'Proposer une date',
                            onPressed: () => _propose(context, r.id),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.red),
                            tooltip: 'Refuser',
                            onPressed: () => RealEstateService.respondToVisit(
                                requestId: r.id, action: 'decline'),
                          ),
                        ],
                      )
                    : null,
              ),
            );
          },
        );
      },
    );
  }
}
