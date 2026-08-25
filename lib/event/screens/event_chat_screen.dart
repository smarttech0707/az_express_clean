import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/stream_error_state.dart';
import '../services/event_service.dart';

class EventChatScreen extends StatefulWidget {
  const EventChatScreen({
    super.key,
    required this.chatId,
    required this.title,
    required this.service,
  });

  final String chatId;
  final String title;
  final EventService service;

  @override
  State<EventChatScreen> createState() => _EventChatScreenState();
}

class _EventChatScreenState extends State<EventChatScreen> {
  final controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Column(
          children: [
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: widget.service.watchMessages(widget.chatId),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const StreamErrorState();
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final messages = snapshot.data!.docs;
                  if (messages.isEmpty) {
                    return const Center(
                        child: Text('Démarrez la conversation.'));
                  }
                  return ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (_, index) {
                      final data = messages[messages.length - 1 - index].data();
                      final mine = data['senderId'] ==
                          widget.service.auth.currentUser?.uid;
                      return Align(
                        alignment:
                            mine ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 480),
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: mine
                                ? AppColors.primary
                                : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                            borderRadius: AppRadius.lgR,
                          ),
                          child: Text(
                            data['text'] as String? ?? '',
                            style: TextStyle(color: mine ? Colors.white : null),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(12, 8, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      maxLength: 2000,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Votre message…',
                        counterText: '',
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  IconButton.filled(
                    onPressed: _send,
                    icon: const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Future<void> _send() async {
    final text = controller.text;
    controller.clear();
    await widget.service.sendMessage(widget.chatId, text);
  }
}

class EventConversationListScreen extends StatelessWidget {
  const EventConversationListScreen({super.key, required this.service});
  final EventService service;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Messages')),
        body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: service.watchMyChats(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const StreamErrorState();
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final chats = snapshot.data!.docs;
            if (chats.isEmpty) {
              return const Center(child: Text('Aucune conversation.'));
            }
            return ListView.builder(
              itemCount: chats.length,
              itemBuilder: (_, index) {
                final chat = chats[index];
                final data = chat.data();
                return ListTile(
                  leading: const CircleAvatar(
                      child: Icon(Icons.celebration_rounded)),
                  title:
                      Text(data['providerName'] as String? ?? 'Événementiel'),
                  subtitle: Text(data['lastMessage'] as String? ?? ''),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => EventChatScreen(
                        chatId: chat.id,
                        title:
                            data['providerName'] as String? ?? 'Événementiel',
                        service: service,
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      );
}
