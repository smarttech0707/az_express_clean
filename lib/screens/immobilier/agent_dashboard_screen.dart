import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../models/real_estate_agent.dart';
import '../../models/real_estate_listing.dart';
import '../../models/real_estate_visit_request.dart';
import '../../services/real_estate_service.dart';
import '../../theme/app_theme.dart';

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
    if (mounted) setState(() { _agent = agent; _loading = false; });
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
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_agent == null)
              ? _AgentRequestForm(sent: _requestSent, onSent: () => setState(() => _requestSent = true))
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
        const SnackBar(content: Text('Nom et téléphone requis'), backgroundColor: Colors.orange),
      );
      return;
    }
    setState(() => _sending = true);
    try {
      await RealEstateService.submitAgentRequest(
        name: _nameCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        agencyName: _agencyCtrl.text.trim().isEmpty ? null : _agencyCtrl.text.trim(),
        city: _cityCtrl.text.trim().isEmpty ? null : _cityCtrl.text.trim(),
      );
      widget.onSent();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur : $e'), backgroundColor: Colors.red));
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
              const Icon(Icons.hourglass_top_rounded, size: 56, color: AppColors.primary),
              const SizedBox(height: 16),
              const Text('Demande envoyée', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 8),
              Text('Un administrateur va examiner votre demande.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600)),
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
          const Text('Devenir agent immobilier', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('Publiez vos annonces sur AZ Express après validation.', style: TextStyle(color: Colors.grey.shade600)),
          const SizedBox(height: 20),
          TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Nom complet')),
          const SizedBox(height: 12),
          TextField(controller: _phoneCtrl, decoration: const InputDecoration(labelText: 'Téléphone'), keyboardType: TextInputType.phone),
          const SizedBox(height: 12),
          TextField(controller: _agencyCtrl, decoration: const InputDecoration(labelText: 'Nom de l\'agence (optionnel)')),
          const SizedBox(height: 12),
          TextField(controller: _cityCtrl, decoration: const InputDecoration(labelText: 'Ville (optionnel)')),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _sending ? null : _submit,
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
              child: _sending ? const CircularProgressIndicator(color: Colors.white) : const Text('Envoyer la demande'),
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
            Icon(Icons.hourglass_top_rounded, size: 56, color: AppColors.primary),
            SizedBox(height: 16),
            Text('Compte en attente de validation', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
    await Navigator.push(context, AppTransitions.fadeSlide(_ListingFormScreen(agentId: agentId)));
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
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final listings = snap.data!;
          if (listings.isEmpty) {
            return Center(child: Text('Aucune annonce — ajoutez-en une.', style: TextStyle(color: Colors.grey.shade600)));
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
                  subtitle: Text('${l.price} FCFA · ${l.status == 'active' ? 'Active' : 'Masquée'}'),
                  trailing: IconButton(
                    icon: Icon(l.status == 'active' ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    onPressed: () => l.status == 'active'
                        ? RealEstateService.softDelete(l.id)
                        : RealEstateService.reactivate(l.id),
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
  const _ListingFormScreen({required this.agentId});

  @override
  State<_ListingFormScreen> createState() => _ListingFormScreenState();
}

class _ListingFormScreenState extends State<_ListingFormScreen> {
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  String _propertyType = 'Maison';
  String _priceType = 'sale';
  bool _saving = false;

  static const _propertyTypes = [
    'Maison', 'Villa', 'Appartement', 'Studio', 'Chambre', 'Terrain',
    'Bureau', 'Magasin', 'Entrepôt', 'Immeuble', 'Ferme', 'Local commercial',
  ];

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _priceCtrl.dispose();
    _cityCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    final price = int.tryParse(_priceCtrl.text.trim());
    if (title.isEmpty || price == null || price <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Titre et prix valides requis'), backgroundColor: Colors.orange),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      Position? position;
      try {
        position = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium));
      } catch (_) {}

      final listing = RealEstateListing(
        id: '',
        agentId: widget.agentId,
        title: title,
        description: _descCtrl.text.trim(),
        price: price,
        priceType: _priceType,
        propertyType: _propertyType,
        city: _cityCtrl.text.trim(),
        lat: position?.latitude ?? 0,
        lng: position?.longitude ?? 0,
      );
      await RealEstateService.addListing(listing.toMap());
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur : $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nouvelle annonce'), backgroundColor: AppColors.primary, foregroundColor: Colors.white),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(controller: _titleCtrl, decoration: const InputDecoration(labelText: 'Titre')),
            const SizedBox(height: 12),
            TextField(controller: _descCtrl, maxLines: 3, decoration: const InputDecoration(labelText: 'Description')),
            const SizedBox(height: 12),
            TextField(controller: _priceCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Prix (FCFA)')),
            const SizedBox(height: 12),
            TextField(controller: _cityCtrl, decoration: const InputDecoration(labelText: 'Ville / quartier')),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _propertyType,
              decoration: const InputDecoration(labelText: 'Type de bien'),
              items: _propertyTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
              onChanged: (v) => setState(() => _propertyType = v ?? _propertyType),
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
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
                child: _saving ? const CircularProgressIndicator(color: Colors.white) : const Text('Publier l\'annonce'),
              ),
            ),
          ],
        ),
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
        content: TextField(controller: dateCtrl, decoration: const InputDecoration(labelText: 'Date/heure proposée')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Proposer')),
        ],
      ),
    );
    if (confirmed != true || dateCtrl.text.trim().isEmpty) return;
    await RealEstateService.respondToVisit(requestId: requestId, action: 'propose', proposedDate: dateCtrl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<RealEstateVisitRequest>>(
      stream: RealEstateService.visitRequestsAsAgent(agentId),
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final requests = snap.data!;
        if (requests.isEmpty) {
          return Center(child: Text('Aucune demande de visite', style: TextStyle(color: Colors.grey.shade600)));
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
                subtitle: Text('Statut : ${r.status}${r.preferredDate != null ? ' · Souhaité : ${r.preferredDate}' : ''}'),
                trailing: r.status == 'pending'
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.event_available, color: AppColors.primary),
                            tooltip: 'Proposer une date',
                            onPressed: () => _propose(context, r.id),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.red),
                            tooltip: 'Refuser',
                            onPressed: () => RealEstateService.respondToVisit(requestId: r.id, action: 'decline'),
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
