import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/az_ia_provider.dart';
import '../../services/az_ia_service.dart';
import '../../theme/az_ia_theme.dart';

class AzIaHistoryScreen extends StatefulWidget {
  const AzIaHistoryScreen({super.key});

  @override
  State<AzIaHistoryScreen> createState() => _AzIaHistoryScreenState();
}

class _AzIaHistoryScreenState extends State<AzIaHistoryScreen> {
  late Future<List<AzIaConversationSummary>> _conversations;

  @override
  void initState() {
    super.initState();
    _conversations = context.read<AzIaProvider>().loadConversationSummaries();
  }

  String _dateLabel(DateTime? value) {
    if (value == null) return 'Date inconnue';
    final local = value.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AzIaTheme.night,
      appBar: AppBar(
        title: const Text('Historique AZ IA'),
        backgroundColor: AzIaTheme.deepBlue,
        foregroundColor: AzIaTheme.textPrimary,
      ),
      body: FutureBuilder<List<AzIaConversationSummary>>(
        future: _conversations,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            debugPrint(
                '[AZ_IA_ERROR] loadConversationSummaries exception=${snapshot.error}');
            debugPrintStack(
                stackTrace: snapshot.stackTrace ?? StackTrace.current);
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Impossible de charger l’historique. Réessayez plus tard.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AzIaTheme.textSecondary),
                ),
              ),
            );
          }
          final conversations = snapshot.data ?? const [];
          if (conversations.isEmpty) {
            return const Center(
              child: Text(
                'Aucune conversation enregistrée.',
                style: TextStyle(color: AzIaTheme.textSecondary),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: conversations.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final conversation = conversations[index];
              return Material(
                color: AzIaTheme.surface,
                borderRadius: BorderRadius.circular(16),
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: AzIaTheme.electricBlue,
                    child: Icon(Icons.auto_awesome, color: Colors.white),
                  ),
                  title: Text(
                    conversation.preview.isEmpty
                        ? 'Conversation AZ IA'
                        : conversation.preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AzIaTheme.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '${_dateLabel(conversation.updatedAt)} · ${conversation.messageCount} messages',
                    style: const TextStyle(color: AzIaTheme.textSecondary),
                  ),
                  trailing: const Icon(Icons.chevron_right,
                      color: AzIaTheme.textSecondary),
                  onTap: () async {
                    await context
                        .read<AzIaProvider>()
                        .openConversation(conversation.id);
                    if (context.mounted) Navigator.pop(context, true);
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
