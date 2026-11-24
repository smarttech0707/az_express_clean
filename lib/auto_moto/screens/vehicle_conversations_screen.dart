import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../models/vehicle_conversation.dart';
import '../vehicle_conversation_repository.dart';
import 'vehicle_chat_screen.dart';

class VehicleConversationsScreen extends StatefulWidget {
  const VehicleConversationsScreen({
    super.key,
    required this.currentUserId,
    this.repository,
  });
  final String currentUserId;
  final VehicleConversationDataSource? repository;

  @override
  State<VehicleConversationsScreen> createState() =>
      _VehicleConversationsScreenState();
}

class _VehicleConversationsScreenState
    extends State<VehicleConversationsScreen> {
  late final VehicleConversationDataSource _repository;
  late Future<VehicleConversationsPage> _future;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? VehicleConversationRepository();
    _future = _repository.getConversations(uid: widget.currentUserId);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Messages Auto & Moto')),
        body: SafeArea(
          top: false,
          child: FutureBuilder<VehicleConversationsPage>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child: FilledButton.tonal(
                    onPressed: () => setState(() {
                      _future = _repository.getConversations(
                        uid: widget.currentUserId,
                      );
                    }),
                    child: const Text('Réessayer'),
                  ),
                );
              }
              final conversations = snapshot.data?.conversations ?? const [];
              if (conversations.isEmpty) {
                return const Center(child: Text('Aucune conversation.'));
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                itemCount: conversations.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, index) => _ConversationTile(
                  conversation: conversations[index],
                  uid: widget.currentUserId,
                  onTap: () async {
                    await Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => VehicleChatScreen(
                          conversation: conversations[index],
                          currentUserId: widget.currentUserId,
                          repository: _repository,
                        ),
                      ),
                    );
                    if (mounted) {
                      setState(() {
                        _future = _repository.getConversations(
                          uid: widget.currentUserId,
                        );
                      });
                    }
                  },
                ),
              );
            },
          ),
        ),
      );
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.uid,
    required this.onTap,
  });
  final VehicleConversation conversation;
  final String uid;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final unread = conversation.unreadFor(uid);
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onTap,
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox.square(
            dimension: 54,
            child: conversation.listingImageUrl?.isNotEmpty == true
                ? CachedNetworkImage(
                    imageUrl: conversation.listingImageUrl!,
                    fit: BoxFit.cover,
                  )
                : ColoredBox(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.directions_car_rounded),
                  ),
          ),
        ),
        title: Text(
          conversation.listingTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          conversation.lastMessagePreview.isEmpty
              ? conversation.sellerDisplayName
              : conversation.lastMessagePreview,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: unread > 0
            ? CircleAvatar(
                radius: 13,
                backgroundColor: AppColors.primary,
                child: Text(
                  unread > 99 ? '99+' : '$unread',
                  style: const TextStyle(fontSize: 11, color: Colors.white),
                ),
              )
            : const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}
