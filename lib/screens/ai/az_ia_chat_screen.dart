import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/az_ia_provider.dart';
import '../../theme/app_theme.dart';

const _kVoiceRepliesPrefKey = 'az_ia_voice_replies_enabled';

class AzIaChatScreen extends StatefulWidget {
  const AzIaChatScreen({super.key});

  @override
  State<AzIaChatScreen> createState() => _AzIaChatScreenState();
}

class _AzIaChatScreenState extends State<AzIaChatScreen> {
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  // ── Reconnaissance vocale (M7) — même pattern que
  // lib/screens/client/courses_screen.dart, déjà éprouvé en production.
  final SpeechToText _speech = SpeechToText();
  bool _speechAvailable = false;
  bool _listening = false;

  // ── Synthèse vocale (M7) — lit la réponse d'AZ IA à voix haute si activé.
  final FlutterTts _tts = FlutterTts();
  bool _voiceRepliesEnabled = true;

  @override
  void initState() {
    super.initState();
    _initSpeech();
    _tts.setLanguage('fr-FR');
    _loadVoicePreference();
  }

  @override
  void dispose() {
    _speech.stop();
    _tts.stop();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadVoicePreference() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_kVoiceRepliesPrefKey) ?? true;
    if (mounted) setState(() => _voiceRepliesEnabled = enabled);
  }

  Future<void> _toggleVoiceReplies() async {
    final next = !_voiceRepliesEnabled;
    setState(() => _voiceRepliesEnabled = next);
    if (!next) await _tts.stop();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kVoiceRepliesPrefKey, next);
  }

  Future<void> _initSpeech() async {
    _speechAvailable = await _speech.initialize(
      onError: (e) => setState(() => _listening = false),
      onStatus: (s) {
        if (s == 'done' || s == 'notListening') {
          setState(() => _listening = false);
        }
      },
    );
    if (mounted) setState(() {});
  }

  Future<void> _toggleListening(AzIaProvider provider) async {
    if (!_speechAvailable) {
      _snack('Micro non disponible sur cet appareil');
      return;
    }
    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
      return;
    }
    // Pas de vrai « barge-in » dans cette première passe (décision produit à
    // trancher séparément, voir CLAUDE.md) — on se contente d'arrêter la
    // synthèse en cours avant d'écouter, pour éviter que le micro capte la
    // propre voix d'AZ IA.
    await _tts.stop();
    setState(() => _listening = true);
    await _speech.listen(
      onResult: _onSpeechResult,
      listenOptions: SpeechListenOptions(
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        localeId: 'fr_FR',
        partialResults: true,
      ),
    );
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    setState(() => _textCtrl.text = result.recognizedWords);
    if (result.finalResult && result.recognizedWords.trim().isNotEmpty) {
      final provider = context.read<AzIaProvider>();
      _send(provider);
    }
  }

  void _snack(String msg, [Color color = Colors.orange]) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  Future<void> _confirmClearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Effacer l\'historique ?'),
        content: const Text(
            'Toute la conversation avec AZ IA sera définitivement supprimée. Cette action est irréversible.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Effacer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await context.read<AzIaProvider>().clearHistory();
      if (!mounted) return;
      _snack('Historique effacé.', const Color(0xFF2E7D32));
    } catch (e) {
      if (!mounted) return;
      _snack('Erreur lors de la suppression : $e', Colors.red);
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 150), () {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send(AzIaProvider provider) async {
    final text = _textCtrl.text;
    if (text.trim().isEmpty) return;
    _textCtrl.clear();
    final reply = await provider.sendMessage(text);
    _scrollToBottom();
    if (_voiceRepliesEnabled && reply != null && reply.trim().isNotEmpty) {
      await _tts.speak(reply);
    }
  }

  @override
  Widget build(BuildContext context) {
    // AzIaProvider vit au niveau du MultiProvider de main.dart, pas ici —
    // la conversation survit à la fermeture/réouverture de cet écran.
    return Scaffold(
      backgroundColor: const Color(0xFFEDE7DC),
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: Colors.white24,
              child: Icon(Icons.auto_awesome, color: Colors.white, size: 18),
            ),
            SizedBox(width: 8),
            Text('AZ IA', style: TextStyle(fontSize: 16)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _voiceRepliesEnabled
                ? 'Désactiver les réponses vocales'
                : 'Activer les réponses vocales',
            icon: Icon(_voiceRepliesEnabled ? Icons.volume_up : Icons.volume_off),
            onPressed: _toggleVoiceReplies,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'clear_history',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, color: Colors.red, size: 20),
                    SizedBox(width: 10),
                    Text('Effacer l\'historique'),
                  ],
                ),
              ),
            ],
            onSelected: (value) {
              if (value == 'clear_history') _confirmClearHistory();
            },
          ),
        ],
      ),
      body: Consumer<AzIaProvider>(
        builder: (context, provider, _) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

          return Column(
            children: [
              Expanded(
                child: provider.messages.isEmpty
                    ? _EmptyState()
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                        itemCount:
                            provider.messages.length + (provider.isSending ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (i >= provider.messages.length) {
                            return const _TypingBubble();
                          }
                          final msg = provider.messages[i];
                          return _ChatBubble(
                            text: msg.text,
                            isUser: msg.sender == AzIaSender.user,
                          );
                        },
                      ),
              ),
              _InputBar(
                controller: _textCtrl,
                enabled: !provider.isSending,
                listening: _listening,
                speechAvailable: _speechAvailable,
                onSend: () => _send(provider),
                onMicTap: () => _toggleListening(provider),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_awesome, size: 56, color: AppColors.primary.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            const Text(
              'Parlez. AZ s\'occupe du reste.',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              'Posez une question à AZ IA pour commencer.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final String text;
  final bool isUser;
  const _ChatBubble({required this.text, required this.isUser});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: isUser ? AppColors.primary : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
          boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 3, offset: Offset(0, 1))],
        ),
        child: Text(
          text,
          style: TextStyle(color: isUser ? Colors.white : Colors.black87, fontSize: 14),
        ),
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 3, offset: Offset(0, 1))],
        ),
        child: const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final bool listening;
  final bool speechAvailable;
  final VoidCallback onSend;
  final VoidCallback onMicTap;

  const _InputBar({
    required this.controller,
    required this.enabled,
    required this.listening,
    required this.speechAvailable,
    required this.onSend,
    required this.onMicTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(8, 8, 8, 8 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))],
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: controller,
                enabled: enabled,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText: listening ? 'Je vous écoute...' : 'Écrivez à AZ IA...',
                  hintStyle: const TextStyle(color: Colors.grey),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (speechAvailable)
            GestureDetector(
              onTap: enabled ? onMicTap : null,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: listening ? Colors.red : Colors.grey.shade300,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  listening ? Icons.mic : Icons.mic_none,
                  color: listening ? Colors.white : Colors.black54,
                  size: 22,
                ),
              ),
            ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: enabled ? onSend : null,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: enabled ? AppColors.primary : Colors.grey.shade300,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.send, color: Colors.white, size: 22),
            ),
          ),
        ],
      ),
    );
  }
}
