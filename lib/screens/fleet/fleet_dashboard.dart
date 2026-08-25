import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/firestore_service.dart';
import '../../services/auth_service.dart';
import '../../models/driver_earnings_summary.dart';
import '../home/home_screen.dart';
import '../../widgets/partner_account_sheet.dart';
import '../../widgets/stream_error_state.dart';
import '../../widgets/logout_confirm_dialog.dart';

class FleetDashboard extends StatefulWidget {
  final String ownerId;
  final String ownerName;

  const FleetDashboard({
    super.key,
    required this.ownerId,
    required this.ownerName,
  });

  @override
  State<FleetDashboard> createState() => _FleetDashboardState();
}

class _FleetDashboardState extends State<FleetDashboard>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  // Master Prompt 135 — _logout() affiche désormais une confirmation avant
  // d'appeler _doLogout(), qui porte l'intégralité de la logique déjà
  // existante et inchangée (signOut, redirection).
  void _logout() => showLogoutConfirmDialog(context, onConfirm: _doLogout);

  Future<void> _doLogout() async {
    AuthService().logAuthEvent('logout', 'fleet_owner');
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
      backgroundColor: const Color(0xFFF0F0F5),
      appBar: AppBar(
        title: Text("Flotte de ${widget.ownerName}"),
        backgroundColor: const Color(0xFF6A1B9A),
        foregroundColor: Colors.white,
        centerTitle: true,
        actions: [
          StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection('fleet_owners')
                .doc(widget.ownerId)
                .snapshots(),
            builder: (context, snap) {
              final photoUrl = snap.hasData && snap.data!.exists
                  ? (snap.data!.data() as Map<String, dynamic>)['photoUrl']
                      as String?
                  : null;
              return IconButton(
                icon: const Icon(Icons.account_circle_outlined),
                tooltip: 'Mon compte',
                onPressed: () => showPartnerAccountSheet(
                  context,
                  role: 'fleet_owner',
                  roleLabel: 'Patron de flotte',
                  name: widget.ownerName,
                  onLogout: _logout,
                  photoUrl: photoUrl,
                  photoStoragePath:
                      'fleet_photos/${widget.ownerId}/profile.jpg',
                  onPhotoUploaded: (url) => FirebaseFirestore.instance
                      .collection('fleet_owners')
                      .doc(widget.ownerId)
                      .update({'photoUrl': url}),
                  onPhotoDeleted: () => FirebaseFirestore.instance
                      .collection('fleet_owners')
                      .doc(widget.ownerId)
                      .update({'photoUrl': FieldValue.delete()}),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            tooltip: 'Déconnexion',
            onPressed: _logout,
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          indicatorColor: Colors.white,
          indicatorWeight: 3,
          tabs: const [
            Tab(icon: Icon(Icons.sensors), text: "En direct"),
            Tab(icon: Icon(Icons.bar_chart), text: "Gains"),
            Tab(icon: Icon(Icons.person_add), text: "Créer livreur"),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _LiveTab(ownerId: widget.ownerId),
          _GainsTab(ownerId: widget.ownerId),
          _CreateDriverTab(
              ownerId: widget.ownerId, ownerName: widget.ownerName),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// ONGLET 1 — EN DIRECT (statut online/offline temps réel)
// ══════════════════════════════════════════════════════════════

class _LiveTab extends StatelessWidget {
  final String ownerId;
  const _LiveTab({required this.ownerId});

  void _confirmRelease(BuildContext context, String driverId, String name) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [
          Icon(Icons.person_outline, color: Colors.blue),
          SizedBox(width: 8),
          Text("Libérer le livreur"),
        ]),
        content: Text(
            "$name sera retiré de votre flotte et deviendra livreur indépendant."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Annuler")),
          ScaleButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
            onPressed: () async {
              Navigator.pop(context);
              await FirestoreService().makeDriverIndependent(driverId);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text("$name est maintenant indépendant"),
                  backgroundColor: Colors.blue,
                ));
              }
            },
            child:
                const Text("Confirmer", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection("livreurs")
          .where("ownerId", isEqualTo: ownerId)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return const StreamErrorState(
              message: "Impossible de charger vos livreurs.");
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final drivers = snap.data!.docs;
        final online =
            drivers.where((d) => (d.data() as Map)["isOnline"] == true).length;

        if (drivers.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.group_off, size: 60, color: Colors.grey.shade300),
                const SizedBox(height: 16),
                const Text("Aucun livreur dans votre flotte",
                    style: TextStyle(color: Colors.grey)),
                const SizedBox(height: 8),
                const Text("Allez dans \"Créer livreur\" pour en ajouter",
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
          );
        }

        return Column(
          children: [
            // ── Résumé en haut ─────────────────────────────
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF6A1B9A), Color(0xFF8E24AA)],
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _statBadge("${drivers.length}", "Total", Icons.group),
                  Container(width: 1, height: 40, color: Colors.white24),
                  _statBadge("$online", "En ligne", Icons.wifi),
                  Container(width: 1, height: 40, color: Colors.white24),
                  _statBadge("${drivers.length - online}", "Hors ligne",
                      Icons.wifi_off),
                ],
              ),
            ),

            // ── Liste livreurs ─────────────────────────────
            Expanded(
              child: ListView.builder(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: drivers.length,
                itemBuilder: (context, i) {
                  final doc = drivers[i];
                  final data = doc.data() as Map<String, dynamic>;
                  final isOnline = data["isOnline"] == true;
                  final wallet = (data["wallet"] as num? ?? 0).toInt();

                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isOnline
                            ? Colors.green.shade200
                            : Colors.grey.shade200,
                        width: 1.5,
                      ),
                      boxShadow: const [
                        BoxShadow(color: Colors.black12, blurRadius: 4)
                      ],
                    ),
                    child: Row(
                      children: [
                        // Avatar avec indicateur en direct
                        Stack(
                          children: [
                            CircleAvatar(
                              radius: 24,
                              backgroundColor: isOnline
                                  ? Colors.green.shade100
                                  : Colors.grey.shade200,
                              child: Icon(Icons.delivery_dining,
                                  color: isOnline ? Colors.green : Colors.grey,
                                  size: 26),
                            ),
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                width: 13,
                                height: 13,
                                decoration: BoxDecoration(
                                  color: isOnline ? Colors.green : Colors.grey,
                                  shape: BoxShape.circle,
                                  border:
                                      Border.all(color: Colors.white, width: 2),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 12),

                        // Infos
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                data["name"] ?? "—",
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              Text(
                                data["phone"] ?? "—",
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 12),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                "ID : ${data['identifiant'] ?? '—'}",
                                style: TextStyle(
                                    color: Colors.purple.shade300,
                                    fontSize: 11),
                              ),
                            ],
                          ),
                        ),

                        // Statut + wallet + libérer
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: isOnline
                                    ? Colors.green.shade50
                                    : Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                isOnline ? "● En ligne" : "○ Hors ligne",
                                style: TextStyle(
                                  color: isOnline ? Colors.green : Colors.grey,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              "$wallet FCFA",
                              style: TextStyle(
                                color:
                                    wallet < 200 ? Colors.red : Colors.orange,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 6),
                            GestureDetector(
                              onTap: () => _confirmRelease(
                                  context, doc.id, data["name"] ?? "Livreur"),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.blue.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                  border:
                                      Border.all(color: Colors.blue.shade200),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.person_outline,
                                        color: Colors.blue, size: 13),
                                    SizedBox(width: 4),
                                    Text("Libérer",
                                        style: TextStyle(
                                            color: Colors.blue,
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _statBadge(String value, String label, IconData icon) {
    return Column(
      children: [
        Icon(icon, color: Colors.white70, size: 18),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold)),
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════
// ONGLET 2 — GAINS
// ══════════════════════════════════════════════════════════════

class _GainsTab extends StatefulWidget {
  final String ownerId;
  const _GainsTab({required this.ownerId});

  @override
  State<_GainsTab> createState() => _GainsTabState();
}

class _GainsTabState extends State<_GainsTab> {
  int _period = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              _periodBtn("Aujourd'hui", 0),
              const SizedBox(width: 8),
              _periodBtn("Semaine", 1),
              const SizedBox(width: 8),
              _periodBtn("Mois", 2),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection("livreurs")
                .where("ownerId", isEqualTo: widget.ownerId)
                .snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return const StreamErrorState(
                    message: "Impossible de charger vos livreurs.");
              }
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final drivers = snap.data!.docs;
              if (drivers.isEmpty) {
                return const Center(
                    child: Text("Aucun livreur",
                        style: TextStyle(color: Colors.grey)));
              }
              return ListView.builder(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: drivers.length,
                itemBuilder: (context, i) {
                  final doc = drivers[i];
                  final data = doc.data() as Map<String, dynamic>;
                  return _DriverEarningsCard(
                    driverId: doc.id,
                    driverData: data,
                    period: _period,
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _periodBtn(String label, int value) {
    final selected = _period == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _period = value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF6A1B9A) : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? const Color(0xFF6A1B9A) : Colors.grey.shade300,
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: selected ? Colors.white : Colors.grey,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}

class _DriverEarningsCard extends StatelessWidget {
  final String driverId;
  final Map<String, dynamic> driverData;
  final int period;
  const _DriverEarningsCard(
      {required this.driverId, required this.driverData, required this.period});

  @override
  Widget build(BuildContext context) {
    final isOnline = driverData["isOnline"] == true;
    return FutureBuilder<DriverEarningsSummary>(
      future: FirestoreService().driverEarningsSummary(driverId),
      builder: (context, snap) {
        final s = snap.data;
        final courses = s == null
            ? "—"
            : (period == 0
                    ? s.todayCourses
                    : period == 1
                        ? s.weekCourses
                        : s.monthCourses)
                .toString();
        final gain = s == null
            ? "—"
            : "${period == 0 ? s.todayGain : period == 1 ? s.weekGain : s.monthGain} FCFA";

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
          ),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor:
                    isOnline ? Colors.green.shade100 : Colors.grey.shade200,
                radius: 22,
                child: Icon(Icons.delivery_dining,
                    color: isOnline ? Colors.green : Colors.grey),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(driverData["name"] ?? "—",
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(driverData["phone"] ?? "—",
                        style:
                            const TextStyle(color: Colors.grey, fontSize: 12)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _chip("$courses courses", Colors.blue),
                        const SizedBox(width: 6),
                        _chip(gain, Colors.green),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text("Wallet",
                      style:
                          TextStyle(color: Colors.grey.shade500, fontSize: 11)),
                  Text(
                    "${driverData['wallet'] ?? 0} FCFA",
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.orange,
                        fontSize: 14),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6)),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// ONGLET 3 — CRÉER UN LIVREUR
// ══════════════════════════════════════════════════════════════

class _CreateDriverTab extends StatefulWidget {
  final String ownerId;
  final String ownerName;
  const _CreateDriverTab({required this.ownerId, required this.ownerName});

  @override
  State<_CreateDriverTab> createState() => _CreateDriverTabState();
}

class _CreateDriverTabState extends State<_CreateDriverTab> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _idCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  bool _showPass = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _idCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _createDriver() async {
    final name = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    final id = _idCtrl.text.trim().toLowerCase();
    final pass = _passCtrl.text;

    if (name.isEmpty || phone.isEmpty || id.isEmpty || pass.isEmpty) {
      _snack("Remplissez tous les champs", Colors.red);
      return;
    }
    if (pass.length < 6) {
      _snack("Mot de passe : minimum 6 caractères", Colors.red);
      return;
    }

    setState(() => _loading = true);

    try {
      final credential =
          await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: "$id@az-driver.ci",
        password: pass,
      );
      final driverUid = credential.user!.uid;

      // Créer le doc livreur avec ownerId du patron
      await FirebaseFirestore.instance
          .collection("livreurs")
          .doc(driverUid)
          .set({
        "name": name,
        "phone": phone,
        "identifiant": id,
        "ownerId": widget.ownerId,
        "ownerName": widget.ownerName,
        "wallet": 500,
        "isOnline": false,
        "createdAt": Timestamp.now(),
      });

      // Firebase Auth signe automatiquement le nouveau livreur à la création.
      // On déconnecte ce compte et on restaure une session anonyme pour que
      // les règles Firestore (isAuth()) continuent de fonctionner sur ce device.
      await FirebaseAuth.instance.signOut();
      try {
        await FirebaseAuth.instance.signInAnonymously();
      } catch (_) {}

      if (!mounted) return;
      setState(() => _loading = false);
      _nameCtrl.clear();
      _phoneCtrl.clear();
      _idCtrl.clear();
      _passCtrl.clear();

      _snack("Compte livreur créé pour $name !", Colors.green);

      // Afficher les identifiants créés
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green),
              SizedBox(width: 8),
              Text("Compte créé"),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Transmettez ces identifiants à votre livreur :",
                  style: TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 14),
              _credRow(Icons.person, "Nom", name),
              _credRow(Icons.badge, "Identifiant", id),
              _credRow(Icons.lock, "Mot de passe", pass),
            ],
          ),
          actions: [
            ScaleButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6A1B9A),
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text("OK"),
            ),
          ],
        ),
      );
    } on FirebaseAuthException catch (e) {
      setState(() => _loading = false);
      if (e.code == 'email-already-in-use') {
        _snack("Cet identifiant est déjà utilisé", Colors.red);
      } else {
        _snack("Erreur : ${e.message}", Colors.red);
      }
    } catch (e) {
      setState(() => _loading = false);
      _snack("Erreur inattendue", Colors.red);
    }
  }

  Widget _credRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: const Color(0xFF6A1B9A)),
          const SizedBox(width: 8),
          Text("$label : ",
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 13, color: Color(0xFF6A1B9A))),
          ),
        ],
      ),
    );
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF6A1B9A), Color(0xFF8E24AA)],
              ),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.person_add_alt_1, color: Colors.white, size: 32),
                SizedBox(height: 8),
                Text(
                  "Créer un compte livreur",
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 4),
                Text(
                  "Le livreur se connectera avec l'identifiant\net mot de passe que vous choisissez.",
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          _field(_nameCtrl, "Nom du livreur", Icons.person),
          const SizedBox(height: 14),
          _field(_phoneCtrl, "Numéro de téléphone", Icons.phone,
              type: TextInputType.phone),
          const SizedBox(height: 14),
          _field(_idCtrl, "Identifiant de connexion", Icons.badge,
              hint: "ex: ali2024"),
          const SizedBox(height: 14),

          // Mot de passe
          TextField(
            controller: _passCtrl,
            obscureText: !_showPass,
            decoration: InputDecoration(
              labelText: "Mot de passe",
              hintText: "Minimum 6 caractères",
              prefixIcon: const Icon(Icons.lock),
              suffixIcon: IconButton(
                icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _showPass = !_showPass),
              ),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              filled: true,
              fillColor: Colors.white,
            ),
          ),

          const SizedBox(height: 28),

          SizedBox(
            width: double.infinity,
            height: 55,
            child: ElevatedButton.icon(
              onPressed: _loading ? null : _createDriver,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6A1B9A),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              icon: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.add_circle, color: Colors.white),
              label: Text(
                _loading ? "Création..." : "Créer le compte",
                style: const TextStyle(fontSize: 17, color: Colors.white),
              ),
            ),
          ),

          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.shade300),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: Colors.amber, size: 18),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Après la création, notez l'identifiant et le mot de passe pour les donner à votre livreur. Il s'en servira pour se connecter.",
                    style: TextStyle(fontSize: 12, color: Colors.brown),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {TextInputType? type, String? hint}) {
    return TextField(
      controller: ctrl,
      keyboardType: type,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
        fillColor: Colors.white,
      ),
    );
  }
}
