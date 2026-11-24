import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../theme/app_theme.dart';
import '../models/vehicle_conversation.dart';
import '../models/vehicle_listing.dart';
import '../models/vehicle_seller_profile.dart';
import '../vehicle_conversation_repository.dart';
import '../vehicle_formatters.dart';
import '../vehicle_trust_repository.dart';

class VehicleChatScreen extends StatefulWidget {
  const VehicleChatScreen({
    super.key,
    required this.conversation,
    required this.currentUserId,
    this.repository,
    this.blockedLoader,
  });

  final VehicleConversation conversation;
  final String currentUserId;
  final VehicleConversationDataSource? repository;
  final Future<bool> Function()? blockedLoader;

  @override
  State<VehicleChatScreen> createState() => _VehicleChatScreenState();
}

class _VehicleChatScreenState extends State<VehicleChatScreen> {
  final _controller = TextEditingController();
  late final VehicleConversationDataSource _repository;
  bool _sending = false;
  bool _blocked = false;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? VehicleConversationRepository();
    _repository.markRead(widget.conversation, widget.currentUserId);
    _loadBlocked();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conversation = widget.conversation;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            _ListingThumbnail(url: conversation.listingImageUrl, size: 42),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    conversation.listingTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  Text(
                    formatVehiclePrice(
                      conversation.listingPrice,
                      currency: conversation.currency,
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _SellerStrip(conversation: conversation),
            Expanded(
              child: StreamBuilder<List<VehicleChatMessage>>(
                stream: _repository.watchMessages(conversation.id),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(
                      child: Text('Impossible de charger les messages.'),
                    );
                  }
                  final messages = snapshot.data ?? const [];
                  if (messages.isEmpty) {
                    return const _EmptyConversation();
                  }
                  return ListView.builder(
                    reverse: true,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                    itemCount: messages.length,
                    itemBuilder: (_, index) => _MessageBubble(
                      message: messages[index],
                      isMine: messages[index].senderId == widget.currentUserId,
                    ),
                  );
                },
              ),
            ),
            if (_blocked)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Conversation bloquée. L’historique reste disponible, mais aucun nouveau message ne peut être envoyé.',
                  textAlign: TextAlign.center,
                ),
              )
            else
              _composer(),
          ],
        ),
      ),
    );
  }

  Widget _composer() => Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                key: const Key('vehicle_chat_input'),
                controller: _controller,
                minLines: 1,
                maxLines: 4,
                maxLength: VehicleChatValidator.maxMessageLength,
                decoration: const InputDecoration(
                  hintText: 'Écrire un message…',
                  counterText: '',
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              key: const Key('vehicle_chat_send'),
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded),
            ),
          ],
        ),
      );

  Future<void> _send() async {
    if (_sending || _blocked) return;
    final validation = VehicleChatValidator.validateMessage(_controller.text);
    if (validation != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(validation)));
      return;
    }
    setState(() => _sending = true);
    try {
      await _repository.sendMessage(
        conversation: widget.conversation,
        senderId: widget.currentUserId,
        text: _controller.text,
      );
      _controller.clear();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message non envoyé. Réessayez.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _loadBlocked() async {
    final otherUid = widget.conversation.participantIds.firstWhere(
      (uid) => uid != widget.currentUserId,
    );
    try {
      final blocked = await (widget.blockedLoader?.call() ??
          VehicleTrustRepository().isBlocked(widget.currentUserId, otherUid));
      if (mounted) setState(() => _blocked = blocked);
    } catch (_) {
      // Les règles serveur restent l'autorité même si cet indicateur échoue.
    }
  }
}

class _SellerStrip extends StatelessWidget {
  const _SellerStrip({required this.conversation});
  final VehicleConversation conversation;

  @override
  Widget build(BuildContext context) {
    final professional =
        conversation.sellerType == VehicleSellerType.professional;
    final verified = professional &&
        conversation.sellerVerificationStatus ==
            VehicleSellerVerificationStatus.verified;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          Expanded(
            child: Text(
              conversation.sellerDisplayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          if (professional) const _CompactBadge(label: 'Professionnel'),
          if (verified) ...[
            const SizedBox(width: 5),
            const _CompactBadge(label: 'Vérifié', verified: true),
          ],
        ]),
      ),
    );
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation();

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            const Icon(Icons.chat_bubble_outline_rounded, size: 48),
            const SizedBox(height: 10),
            Text('Démarrez la conversation',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 14),
            Text(
              'AZ Express met l’acheteur et le vendeur en relation mais n’est pas partie à la transaction. Vérifiez le véhicule, son propriétaire et les documents avant tout paiement. Ne versez jamais d’argent sans vérification suffisante.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ]),
        ),
      );
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.isMine});
  final VehicleChatMessage message;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 310),
        margin: const EdgeInsets.only(bottom: 7),
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 6),
        decoration: BoxDecoration(
          color: isMine ? AppColors.primary : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(15),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(message.text,
                style: TextStyle(
                    color: isMine ? colors.onPrimary : colors.onSurface)),
            if (message.createdAt != null) ...[
              const SizedBox(height: 3),
              Text(
                DateFormat('HH:mm').format(message.createdAt!),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: isMine
                          ? colors.onPrimary.withValues(alpha: .75)
                          : colors.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CompactBadge extends StatelessWidget {
  const _CompactBadge({required this.label, this.verified = false});
  final String label;
  final bool verified;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: verified
              ? AppColors.primary.withValues(alpha: .16)
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label, style: Theme.of(context).textTheme.labelSmall),
      );
}

class _ListingThumbnail extends StatelessWidget {
  const _ListingThumbnail({required this.url, required this.size});
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: SizedBox.square(
          dimension: size,
          child: url?.isNotEmpty == true
              ? CachedNetworkImage(imageUrl: url!, fit: BoxFit.cover)
              : ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.directions_car_rounded),
                ),
        ),
      );
}
