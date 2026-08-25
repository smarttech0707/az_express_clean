import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import '../ek_constants.dart';
import '../models/ek_order.dart';
import '../services/ek_service.dart';

class EkOrderTracking extends StatefulWidget {
  // Pass either the full order OR just an orderId (for fresh navigation)
  final EkOrder? order;
  final String? orderId;

  const EkOrderTracking({super.key, this.order, this.orderId})
      : assert(
            order != null || orderId != null, 'Must provide order or orderId');

  @override
  State<EkOrderTracking> createState() => _EkOrderTrackingState();
}

class _EkOrderTrackingState extends State<EkOrderTracking> {
  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _sending = false;
  bool _cancelling = false;
  bool _confirming = false;
  bool _uploadingDeposit = false;
  bool _verifyingDeposit = false;
  bool _showRating = false;
  double _rating = 5.0;

  late Stream<EkOrder?> _orderStream;
  late Stream<QuerySnapshot> _chatStream;
  late String _orderId;
  late String? _myUid;
  String? _myRole; // 'client' or 'agent'

  @override
  void initState() {
    super.initState();
    _myUid = FirebaseAuth.instance.currentUser?.uid;
    _orderId = widget.orderId ?? widget.order!.id;
    _orderStream = EkService.streamOrder(_orderId);
    _chatStream = EkService.streamChatMessages(_orderId);
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<EkOrder?>(
      stream: _orderStream,
      initialData: widget.order,
      builder: (context, snap) {
        final order = snap.data;
        if (order == null) {
          return Scaffold(
            appBar: AppBar(
                backgroundColor: kEkDark,
                foregroundColor: Colors.white,
                title: const Text('Commande')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }

        // Determine role
        _myRole ??= order.clientId == _myUid ? 'client' : 'agent';

        return Scaffold(
          backgroundColor: kEkBg,
          appBar: _buildAppBar(order),
          body: Column(children: [
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(child: _buildStatus(order)),
                  SliverToBoxAdapter(child: _buildOrderInfo(order)),
                  if (order.agentId != null)
                    SliverToBoxAdapter(child: _buildAgentCard(order)),
                  if (order.depositProofUrl != null ||
                      order.status == 'awaiting_deposit')
                    SliverToBoxAdapter(child: _buildDepositSection(order)),
                  if (order.proofUrl != null)
                    SliverToBoxAdapter(child: _buildProof(order)),
                  SliverToBoxAdapter(child: _buildActions(order)),
                  SliverToBoxAdapter(child: _buildChatSection(order)),
                ],
              ),
            ),
            _buildChatInput(order),
          ]),
        );
      },
    );
  }

  AppBar _buildAppBar(EkOrder order) {
    final statusColor = ekStatusColor(order.status);
    return AppBar(
      backgroundColor: kEkDark,
      foregroundColor: Colors.white,
      elevation: 0,
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(order.serviceLabel,
            style: GoogleFonts.urbanist(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
        Row(children: [
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(right: 5),
            decoration:
                BoxDecoration(color: statusColor, shape: BoxShape.circle),
          ),
          Expanded(
            child: Text(
              ekStatusLabels[order.status] ?? order.status,
              style: GoogleFonts.urbanist(fontSize: 11, color: Colors.white70),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      ]),
      actions: [
        IconButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: order.id));
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('ID copié')));
          },
          icon: const Icon(Icons.copy_rounded, size: 18),
          tooltip: 'Copier ID',
        ),
      ],
    );
  }

  Widget _buildStatus(EkOrder order) {
    // wallet has no deposit step; other payment methods require deposit proof
    final statuses = order.paymentMethod == 'wallet'
        ? ['pending', 'assigned', 'in_progress', 'proof_sent', 'completed']
        : [
            'pending',
            'awaiting_deposit',
            'in_progress',
            'proof_sent',
            'completed'
          ];
    final isCancelled = order.status == 'cancelled';
    final isDisputed = order.status == 'disputed';
    final currentIndex = statuses.indexOf(order.status);

    if (isCancelled || isDisputed) {
      return Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isCancelled
              ? Colors.red.withValues(alpha: 0.08)
              : Colors.deepOrange.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border:
              Border.all(color: isCancelled ? Colors.red : Colors.deepOrange),
        ),
        child: Row(children: [
          Icon(isCancelled ? Icons.cancel_rounded : Icons.warning_rounded,
              color: isCancelled ? Colors.red : Colors.deepOrange, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(isCancelled ? 'Commande annulée' : 'Litige ouvert',
                  style: GoogleFonts.urbanist(
                      fontWeight: FontWeight.w700,
                      color: isCancelled ? Colors.red : Colors.deepOrange)),
              if (order.cancellationReason != null)
                Text(order.cancellationReason!,
                    style: GoogleFonts.urbanist(fontSize: 12, color: kEkMuted)),
            ]),
          ),
        ]),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: Row(
        children: statuses.asMap().entries.map((e) {
          final i = e.key;
          final s = e.value;
          final done = i < currentIndex;
          final curr = i == currentIndex;
          final color =
              curr ? ekStatusColor(s) : (done ? kEkGreen : kEkDivider);

          return Expanded(
            child: Row(children: [
              Expanded(
                child: Column(children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 400),
                    width: curr ? 24 : 18,
                    height: curr ? 24 : 18,
                    decoration: BoxDecoration(
                      color: (done || curr) ? color : Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: color, width: 2),
                    ),
                    child: (done || curr)
                        ? Icon(done ? Icons.check : Icons.circle,
                            size: curr ? 12 : 10, color: Colors.white)
                        : null,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _shortStatus(s),
                    style: GoogleFonts.urbanist(
                      fontSize: 8,
                      fontWeight: curr ? FontWeight.w700 : FontWeight.normal,
                      color: curr ? color : kEkMuted,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ]),
              ),
              if (i < statuses.length - 1)
                Expanded(
                  child: Container(
                    height: 2,
                    color: done ? kEkGreen : kEkDivider,
                    margin: const EdgeInsets.only(bottom: 24),
                  ),
                ),
            ]),
          );
        }).toList(),
      ),
    );
  }

  String _shortStatus(String s) {
    switch (s) {
      case 'pending':
        return 'Attente';
      case 'assigned':
        return 'Agent';
      case 'awaiting_deposit':
        return 'Dépôt';
      case 'in_progress':
        return 'En cours';
      case 'proof_sent':
        return 'Preuve';
      case 'completed':
        return 'Terminé';
      default:
        return s;
    }
  }

  Widget _buildOrderInfo(EkOrder order) {
    final opColor = EkService.operatorColor(order.operator);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kEkDivider),
      ),
      child: Column(children: [
        Row(children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: opColor.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(order.operator[0].toUpperCase(),
                  style: GoogleFonts.urbanist(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: opColor)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(order.serviceLabel,
                  style: GoogleFonts.urbanist(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: kEkText)),
              Text('Pour : ${order.beneficiaryNumber}',
                  style: GoogleFonts.urbanist(fontSize: 12, color: kEkMuted)),
            ]),
          ),
          Text(_fmt(order.totalPaid),
              style: GoogleFonts.urbanist(
                  fontSize: 16, fontWeight: FontWeight.w800, color: kEkGreen)),
        ]),
        if (order.createdAt != null) ...[
          const SizedBox(height: 10),
          const Divider(height: 1),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Commandé le',
                style: GoogleFonts.urbanist(fontSize: 12, color: kEkMuted)),
            Text(
              _dateStr(order.createdAt!),
              style: GoogleFonts.urbanist(
                  fontSize: 12, color: kEkText, fontWeight: FontWeight.w600),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _buildAgentCard(EkOrder order) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kEkGreen.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kEkGreen.withValues(alpha: 0.2)),
      ),
      child: Row(children: [
        CircleAvatar(
          backgroundColor: kEkGreen,
          child: Text(
            (order.agentName ?? 'A')[0].toUpperCase(),
            style: GoogleFonts.urbanist(
                color: Colors.white, fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(order.agentName ?? 'Agent',
                style: GoogleFonts.urbanist(
                    fontSize: 14, fontWeight: FontWeight.w700, color: kEkText)),
            Text('Agent E-Kbine assigné',
                style: GoogleFonts.urbanist(fontSize: 11, color: kEkGreen)),
          ]),
        ),
        const Icon(Icons.verified_rounded, color: kEkGreen, size: 22),
      ]),
    );
  }

  Widget _buildDepositSection(EkOrder order) {
    final isClient = _myRole == 'client';
    final hasProof = order.depositProofUrl != null;
    final awaitingDeposit = order.status == 'awaiting_deposit' ||
        order.status == 'deposit_rejected';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: const Color(0xFFE65100).withValues(alpha: 0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.receipt_long_rounded,
              color: Color(0xFFE65100), size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hasProof
                  ? 'Preuve de paiement envoyée'
                  : 'Preuve de paiement requise',
              style: GoogleFonts.urbanist(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFFE65100)),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        if (!hasProof && isClient && awaitingDeposit) ...[
          _MomoNumberBox(
            operator: order.operator,
            momoNumber: order.agentDepositNumber ?? '',
            total: order.totalPaid,
            paymentMethod: order.paymentMethod,
          ),
          const SizedBox(height: 8),
          Text(
            'Importez ensuite la capture d\'écran de la confirmation.',
            style:
                GoogleFonts.urbanist(fontSize: 12, color: kEkText, height: 1.5),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: ElevatedButton.icon(
              onPressed:
                  _uploadingDeposit ? null : () => _uploadDepositProof(order),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE65100),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              icon: _uploadingDeposit
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.upload_rounded, size: 18),
              label: Text(_uploadingDeposit ? 'Envoi...' : 'Importer ma preuve',
                  style: GoogleFonts.urbanist(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
        if (!hasProof && !isClient && awaitingDeposit) ...[
          Text(
            'En attente de la preuve de paiement du client.',
            style: GoogleFonts.urbanist(fontSize: 12, color: kEkMuted),
          ),
        ],
        if (hasProof) ...[
          Text(
            isClient
                ? 'Votre preuve a été envoyée. L\'agent va vérifier le paiement.'
                : 'Le client a envoyé sa preuve. Vérifiez avant de commencer.',
            style:
                GoogleFonts.urbanist(fontSize: 12, color: kEkText, height: 1.5),
          ),
          const SizedBox(height: 10),
          Semantics(
            label: 'Voir la preuve de paiement en grand',
            button: true,
            excludeSemantics: true,
            child: GestureDetector(
              onTap: () => _viewProof(order.depositProofUrl!),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  order.depositProofUrl!,
                  height: 160,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  loadingBuilder: (_, child, progress) => progress == null
                      ? child
                      : Container(
                          height: 160,
                          color: kEkDivider,
                          child:
                              const Center(child: CircularProgressIndicator())),
                  errorBuilder: (_, __, ___) => Container(
                      height: 160,
                      color: kEkDivider,
                      child: const Icon(Icons.broken_image, color: kEkMuted)),
                ),
              ),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _buildProof(EkOrder order) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('Preuve envoyée par l\'agent',
              style: GoogleFonts.urbanist(
                  fontSize: 13, fontWeight: FontWeight.w700, color: kEkText)),
        ),
        Semantics(
          label: 'Voir la preuve de paiement en grand',
          button: true,
          excludeSemantics: true,
          child: GestureDetector(
            onTap: () => _viewProof(order.proofUrl!),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.network(
                order.proofUrl!,
                height: 200,
                width: double.infinity,
                fit: BoxFit.cover,
                loadingBuilder: (_, child, progress) => progress == null
                    ? child
                    : Container(
                        height: 200,
                        color: kEkDivider,
                        child:
                            const Center(child: CircularProgressIndicator())),
                errorBuilder: (_, __, ___) => Container(
                    height: 200,
                    color: kEkDivider,
                    child: const Icon(Icons.broken_image, color: kEkMuted)),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  void _viewProof(String url) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(children: [
          InteractiveViewer(
            child: Image.network(url, fit: BoxFit.contain),
          ),
          Positioned(
            top: 40,
            right: 16,
            child: IconButton(
              onPressed: () => Navigator.pop(context),
              tooltip: 'Fermer',
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildActions(EkOrder order) {
    final isClient = _myRole == 'client';
    final isAgent = _myRole == 'agent';

    // Agent: verify deposit button
    if (isAgent &&
        order.status == 'deposit_proof_sent' &&
        order.depositProofUrl != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton.icon(
            onPressed: _verifyingDeposit ? null : () => _verifyDeposit(order),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF9C27B0),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
            icon: _verifyingDeposit
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.verified_rounded),
            label: Text('Dépôt reçu — Commencer le service',
                style: GoogleFonts.urbanist(fontWeight: FontWeight.w700)),
          ),
        ),
      );
    }

    if (!isClient) return const SizedBox.shrink();

    final canCancel = order.status == 'pending' ||
        (order.status == 'awaiting_deposit' && order.depositProofUrl == null);
    final canConfirm = order.status == 'proof_sent';
    final canDispute = order.status == 'proof_sent';
    final isCompleted = order.status == 'completed';

    if (!canCancel && !canConfirm && !canDispute && !isCompleted) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(children: [
        if (canConfirm)
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              onPressed: _confirming ? null : () => _confirm(order),
              style: ElevatedButton.styleFrom(
                backgroundColor: kEkGreen,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              icon: _confirming
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.check_circle_rounded),
              label: Text('Confirmer la réception',
                  style: GoogleFonts.urbanist(fontWeight: FontWeight.w700)),
            ),
          ),
        if (canDispute) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: OutlinedButton.icon(
              onPressed: () => _dispute(order),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.deepOrange,
                side: const BorderSide(color: Colors.deepOrange),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              icon: const Icon(Icons.report_problem_rounded, size: 18),
              label: Text('Ouvrir un litige',
                  style: GoogleFonts.urbanist(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
        if (canCancel)
          SizedBox(
            width: double.infinity,
            height: 44,
            child: TextButton.icon(
              onPressed: _cancelling ? null : () => _cancelDialog(order),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              icon: const Icon(Icons.cancel_outlined, size: 18),
              label: Text('Annuler la commande',
                  style: GoogleFonts.urbanist(fontWeight: FontWeight.w600)),
            ),
          ),
        if (isCompleted && !_showRating && order.agentId != null) ...[
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => setState(() => _showRating = true),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8E1),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFFFCC02)),
              ),
              child: Row(children: [
                const Icon(Icons.star_rounded, color: Color(0xFFFFBB00)),
                const SizedBox(width: 10),
                Expanded(
                    child: Text('Notez votre agent',
                        style: GoogleFonts.urbanist(
                            fontWeight: FontWeight.w700, color: kEkText))),
                const Icon(Icons.arrow_forward_ios, size: 14, color: kEkMuted),
              ]),
            ),
          ),
        ],
        if (_showRating && order.agentId != null) _buildRating(order),
      ]),
    );
  }

  Widget _buildRating(EkOrder order) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kEkDivider),
      ),
      child: Column(children: [
        Text('Notez votre agent',
            style: GoogleFonts.urbanist(
                fontWeight: FontWeight.w700, fontSize: 15, color: kEkText)),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (int i = 1; i <= 5; i++)
            GestureDetector(
              onTap: () => setState(() => _rating = i.toDouble()),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(
                  i <= _rating
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  color: const Color(0xFFFFBB00),
                  size: 36,
                ),
              ),
            ),
        ]),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          height: 44,
          child: ScaleButton(
            onPressed: () async {
              await EkService.rateAgent(order.agentId!, _rating);
              if (mounted) setState(() => _showRating = false);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFFBB00),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
            child: Text('Envoyer la note',
                style: GoogleFonts.urbanist(fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }

  Widget _buildChatSection(EkOrder order) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Text('Chat',
            style: GoogleFonts.urbanist(
                fontSize: 15, fontWeight: FontWeight.w700, color: kEkText)),
      ),
      StreamBuilder<QuerySnapshot>(
        stream: _chatStream,
        builder: (_, snap) {
          if (!snap.hasData || snap.data!.docs.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('Aucun message. Écrivez à votre agent.',
                  style: GoogleFonts.urbanist(fontSize: 13, color: kEkMuted)),
            );
          }
          final docs = snap.data!.docs;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollCtrl.hasClients) {
              _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
            }
          });
          return ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: docs.length,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemBuilder: (_, i) {
              final data = docs[i].data() as Map<String, dynamic>;
              final isMe = data['senderId'] == _myUid;
              return _ChatBubble(data: data, isMe: isMe);
            },
          );
        },
      ),
      const SizedBox(height: 8),
    ]);
  }

  Widget _buildChatInput(EkOrder order) {
    final isDone = order.status == 'completed' ||
        order.status == 'cancelled' ||
        order.status == 'disputed';
    if (isDone) return const SizedBox.shrink();

    return Container(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        top: 10,
        bottom: MediaQuery.of(context).viewInsets.bottom + 12,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: kEkDivider)),
      ),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _msgCtrl,
            decoration: InputDecoration(
              hintText: 'Écrire un message...',
              hintStyle: GoogleFonts.urbanist(color: kEkMuted, fontSize: 14),
              filled: true,
              fillColor: kEkBg,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none),
            ),
            maxLines: null,
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: _sending ? null : () => _sendMessage(order),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _sending ? kEkMuted : kEkGreen,
              shape: BoxShape.circle,
            ),
            child: _sending
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.send_rounded, color: Colors.white, size: 20),
          ),
        ),
      ]),
    );
  }

  Future<void> _uploadDepositProof(EkOrder order) async {
    final picker = ImagePicker();
    final file =
        await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (file == null) return;

    setState(() => _uploadingDeposit = true);
    try {
      final url = await EkService.uploadDepositProof(file, order.id);
      await EkService.clientSendDepositProof(order.id, url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Erreur upload: $e'), backgroundColor: Colors.red));
      }
    }
    if (mounted) setState(() => _uploadingDeposit = false);
  }

  Future<void> _verifyDeposit(EkOrder order) async {
    setState(() => _verifyingDeposit = true);
    await EkService.agentVerifyDeposit(order.id);
    if (mounted) setState(() => _verifyingDeposit = false);
  }

  Future<void> _sendMessage(EkOrder order) async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    _msgCtrl.clear();

    await EkService.sendChatMessage(order.id, {
      'senderId': _myUid,
      'senderRole': _myRole,
      'text': text,
      'type': 'text',
    });
    setState(() => _sending = false);
  }

  Future<void> _confirm(EkOrder order) async {
    setState(() => _confirming = true);
    await EkService.clientConfirmOrder(order.id, order);
    if (mounted) {
      setState(() {
        _confirming = false;
        _showRating = true;
      });
    }
  }

  Future<void> _dispute(EkOrder order) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Ouvrir un litige'),
        content: const Text(
            'Êtes-vous sûr ? Notre équipe va examiner la commande sous 24h.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          ScaleButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepOrange,
                foregroundColor: Colors.white),
            child: const Text('Ouvrir le litige'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await EkService.disputeOrder(order.id);
    }
  }

  Future<void> _cancelDialog(EkOrder order) async {
    String reason = '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Annuler la commande'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Pourquoi annulez-vous ?'),
          const SizedBox(height: 12),
          TextField(
            onChanged: (v) => reason = v,
            decoration: const InputDecoration(
                hintText: 'Raison (optionnel)', border: OutlineInputBorder()),
            maxLines: 2,
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Garder')),
          ScaleButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Annuler la commande'),
          ),
        ],
      ),
    );
    if (ok == true) {
      setState(() => _cancelling = true);
      await EkService.cancelOrder(
          order.id, reason.isEmpty ? 'Annulé par le client' : reason);
      if (mounted) setState(() => _cancelling = false);
    }
  }

  String _dateStr(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _MomoNumberBox extends StatelessWidget {
  final String operator;
  final String momoNumber;
  final int total;
  final String paymentMethod;

  const _MomoNumberBox({
    required this.operator,
    required this.momoNumber,
    required this.total,
    required this.paymentMethod,
  });

  @override
  Widget build(BuildContext context) {
    final opLabel =
        _opLabel(paymentMethod.isNotEmpty ? paymentMethod : operator);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: const Color(0xFFE65100).withValues(alpha: 0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Envoyez $opLabel à :',
            style: GoogleFonts.urbanist(fontSize: 12, color: kEkMuted)),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: Text(
              momoNumber.isEmpty ? '(voir le chat)' : momoNumber,
              style: GoogleFonts.urbanist(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: const Color(0xFFE65100),
                  letterSpacing: 2),
            ),
          ),
          if (momoNumber.isNotEmpty)
            IconButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: momoNumber));
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Numéro copié')));
              },
              icon: const Icon(Icons.copy_rounded,
                  color: Color(0xFFE65100), size: 20),
              tooltip: 'Copier',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
        ]),
        const Divider(height: 14),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Montant total à envoyer :',
              style: GoogleFonts.urbanist(fontSize: 12, color: kEkMuted)),
          Text(_fmt(total),
              style: GoogleFonts.urbanist(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFFE65100))),
        ]),
      ]),
    );
  }

  String _opLabel(String method) {
    switch (method) {
      case 'orange_money':
        return 'Orange Money';
      case 'mtn_momo':
        return 'MTN MoMo';
      case 'wave':
        return 'Wave';
      case 'cash':
        return 'en espèces';
      case 'orange':
        return 'Orange Money';
      case 'mtn':
        return 'MTN MoMo';
      case 'moov':
        return 'Moov Money';
      default:
        return method;
    }
  }
}

class _ChatBubble extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool isMe;

  const _ChatBubble({required this.data, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final text = data['text'] as String? ?? '';
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        decoration: BoxDecoration(
          color: isMe ? kEkGreen : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
          boxShadow: const [
            BoxShadow(
                color: Color(0x10000000), blurRadius: 4, offset: Offset(0, 2))
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!isMe)
            Text(
              data['senderRole'] == 'agent' ? 'Agent' : 'Moi',
              style: GoogleFonts.urbanist(
                  fontSize: 10, fontWeight: FontWeight.w700, color: kEkGreen),
            ),
          Text(text,
              style: GoogleFonts.urbanist(
                  fontSize: 14,
                  color: isMe ? Colors.white : kEkText,
                  height: 1.4)),
        ]),
      ),
    );
  }
}

String _fmt(int price) {
  final s = price.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
    buf.write(s[i]);
  }
  return '${buf.toString()} F';
}
