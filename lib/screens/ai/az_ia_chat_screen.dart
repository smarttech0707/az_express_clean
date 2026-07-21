import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';

import '../../providers/az_ia_provider.dart';
import '../../services/az_ia_service.dart'
    show AzIaPendingAction, AzIaResponseAction, AzIaStructuredResponse;
import '../../services/voice/voice_manager.dart';
import '../../services/voice/voice_text_processor.dart';
import '../../theme/app_theme.dart';
import 'az_ia_message_parser.dart';
import 'az_ia_response_widgets.dart';
import 'az_ia_rich_message.dart';

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
  double _soundLevel = 0.0;

  // Master Prompt 112 — audit error_no_match : locale figée en dur ('fr_FR')
  // sans jamais vérifier qu'elle existe réellement sur l'appareil. Résolue
  // dynamiquement une fois à l'initialisation (voir _pickBestFrenchLocale).
  List<LocaleName> _availableLocales = [];
  LocaleName? _systemLocale;
  String? _selectedLocaleId;

  // error_no_match répété malgré une activité micro réelle (sound level non
  // nul) est le symptôme caractéristique d'un moteur de reconnaissance
  // système incompatible/mal configuré (ex. Samsung Voice input au lieu de
  // Google) plutôt qu'un problème de code — voir _onSpeechError.
  int _consecutiveNoMatchWithSound = 0;

  // ── Pipeline de compréhension vocale (Master Prompt 127) — purement
  // client, aucun changement du contrat serveur `azIaChat`. Le texte
  // reconnu est nettoyé (répétitions/mots de remplissage) puis corrigé via
  // le dictionnaire métier AZ Express (`VoiceTextProcessor`) avant envoi.
  bool _analyzing = false;
  // Non-null uniquement quand une correction floue (jamais silencieuse,
  // voir Partie 9) ou une confiance de reconnaissance faible impose de
  // laisser l'utilisateur valider avant d'envoyer — au lieu d'exécuter une
  // action sur la base d'une transcription douteuse.
  String? _voiceConfirmHint;
  // Fait afficher "Compréhension..." (plutôt que directement "AZ IA
  // réfléchit") sur le premier message qui suit une entrée vocale — un
  // simple habillage textuel, la logique réseau/timeout n'est pas touchée.
  bool _lastMessageWasVoice = false;
  // Vrai pendant la lecture à voix haute de la réponse (Partie 11, phase
  // "Réponse...").
  bool _speaking = false;

  // ── Synthèse vocale (M7, voix premium Master Prompt 119) — lit la réponse
  // d'AZ IA à voix haute si activé. VoiceManager encapsule le choix du
  // fournisseur (flutter_tts avec sélection auto de moteur/voix pour
  // l'instant, IA plus tard sans changement ici) + le nettoyage/débit naturel.
  final VoiceManager _voice = VoiceManager();
  bool _voiceRepliesEnabled = true;

  // Défilement intelligent (Master Prompt 116, Partie 1) — ne force le
  // défilement automatique que si l'utilisateur est déjà proche du bas ;
  // s'il a remonté pour relire un ancien message, une nouvelle réponse ne
  // lui arrache plus la lecture en cours (sauf envoi explicite de sa part,
  // voir `force:true` dans `_send`/`_sendQuickReply`).
  bool _userScrolledUp = false;

  @override
  void initState() {
    super.initState();
    _initSpeech();
    _voice.initialize();
    _loadVoicePreference();
    _scrollCtrl.addListener(() {
      if (!_scrollCtrl.hasClients) return;
      final distanceFromBottom = _scrollCtrl.position.maxScrollExtent - _scrollCtrl.position.pixels;
      _userScrolledUp = distanceFromBottom > 80;
    });
  }

  @override
  void dispose() {
    _speech.stop();
    _voice.stop();
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
    if (!next) await _voice.stop();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kVoiceRepliesPrefKey, next);
  }

  Future<void> _initSpeech() async {
    final available = await _speech.initialize(
      onError: _onSpeechError,
      onStatus: (s) {
        debugPrint('[AZ IA micro] onStatus: $s');
        if (!mounted) return;
        if (s == 'done' || s == 'notListening') {
          setState(() => _listening = false);
        }
      },
      debugLogging: true,
    );
    debugPrint('[AZ IA micro] initialize() => $available');

    // ── Audit locale (Master Prompt 112) ──────────────────────────────────
    // La locale était figée en dur sur 'fr_FR' dans listen() sans jamais
    // vérifier qu'elle existe réellement sur l'appareil — sur un moteur de
    // reconnaissance qui ne l'a pas (ou qui expose un identifiant différent,
    // ex. 'fr-FR' avec un tiret, ou seulement 'fr_CI'/'fr_CA'), le moteur
    // écoute avec un modèle de langue qui ne correspond à rien de ce qui est
    // dit → error_no_match systématique, quelle que soit la qualité de
    // l'audio capté.
    if (available) {
      try {
        _systemLocale = await _speech.systemLocale();
        _availableLocales = await _speech.locales();
      } catch (e) {
        debugPrint('[AZ IA micro] échec systemLocale()/locales(): $e');
      }
      _selectedLocaleId = _pickBestFrenchLocale(_availableLocales, _systemLocale);

      debugPrint('[AZ IA micro] locale système : ${_systemLocale?.localeId} (${_systemLocale?.name})');
      debugPrint('[AZ IA micro] ${_availableLocales.length} locales disponibles sur cet appareil :');
      for (final l in _availableLocales) {
        debugPrint('[AZ IA micro]   - ${l.localeId} (${l.name})');
      }
      final fr = _availableLocales.where((l) => l.localeId.toLowerCase().startsWith('fr'));
      debugPrint('[AZ IA micro] fr_FR présent : ${_availableLocales.any((l) => l.localeId == 'fr_FR')}');
      debugPrint('[AZ IA micro] variantes françaises présentes : ${fr.map((l) => l.localeId).join(', ')}');
      debugPrint('[AZ IA micro] locale réellement sélectionnée pour listen() : $_selectedLocaleId');
    }

    if (!mounted) return;
    setState(() => _speechAvailable = available);
  }

  // Sélectionne, dans cet ordre : fr_FR exact -> toute variante française
  // disponible (fr_CI, fr_CA, fr_BE, fr_CH...) -> locale système si elle est
  // elle-même française -> locale système telle quelle en dernier recours
  // (mieux qu'un identifiant 'fr_FR' qui n'existe pas sur l'appareil) ->
  // null (comportement par défaut du moteur) si aucune information dispo.
  String? _pickBestFrenchLocale(List<LocaleName> locales, LocaleName? system) {
    for (final l in locales) {
      if (l.localeId == 'fr_FR' || l.localeId == 'fr-FR') return l.localeId;
    }
    for (final l in locales) {
      if (l.localeId.toLowerCase().startsWith('fr')) return l.localeId;
    }
    if (system != null && system.localeId.toLowerCase().startsWith('fr')) {
      return system.localeId;
    }
    return system?.localeId;
  }

  void _onSpeechError(SpeechRecognitionError e) {
    debugPrint('[AZ IA micro] onError: errorMsg=${e.errorMsg} permanent=${e.permanent}');
    if (!mounted) return;
    setState(() => _listening = false);

    if (e.errorMsg == 'error_no_match') {
      // Le micro a réellement capté du son (voir _soundLevel au moment de
      // l'erreur, journalisé par onSoundLevelChange) mais le moteur ne
      // parvient à reconnaître aucun mot dans la locale utilisée — répété
      // plusieurs fois de suite malgré une activité micro réelle, c'est le
      // symptôme d'un moteur de reconnaissance système incompatible/mal
      // configuré (ex. Samsung Voice input actif à la place de Google), pas
      // un bug de ce code : detectable ici, mais pas réparable depuis
      // l'application (c'est un réglage au niveau du téléphone).
      _consecutiveNoMatchWithSound++;
      debugPrint('[AZ IA micro] error_no_match consécutifs : $_consecutiveNoMatchWithSound (dernier niveau sonore capté : $_soundLevel)');
      if (_consecutiveNoMatchWithSound >= 2) {
        _snack(
          "AZ IA ne comprend aucun mot malgré le micro actif — le moteur de "
          "reconnaissance vocale de votre téléphone semble incompatible. "
          "Allez dans Paramètres > Applications > Application de saisie "
          "vocale par défaut et sélectionnez « Google » plutôt que la "
          "reconnaissance vocale du fabricant.",
          Colors.red,
        );
        _consecutiveNoMatchWithSound = 0;
      } else {
        _snack("Aucun mot reconnu, réessayez en parlant distinctement.");
      }
    } else {
      _consecutiveNoMatchWithSound = 0;
      _snack('Micro : ${e.errorMsg}');
    }
  }

  Future<void> _toggleListening(AzIaProvider provider) async {
    if (!_speechAvailable) {
      _snack('Micro non disponible sur cet appareil');
      return;
    }
    // Le bouton reste visuellement identique que l'envoi soit en cours ou
    // non (voir _InputBar) — sans ce garde explicite, un tap pendant que
    // provider.isSending est vrai (~3-9s le temps qu'AZ IA réponde) ne
    // faisait strictement rien, sans le moindre indice pour l'utilisateur.
    if (provider.isSending) {
      _snack('Patientez la fin de la réponse en cours.');
      return;
    }
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    // Pas de vrai « barge-in » dans cette première passe (décision produit à
    // trancher séparément, voir CLAUDE.md) — on se contente d'arrêter la
    // synthèse en cours avant d'écouter, pour éviter que le micro capte la
    // propre voix d'AZ IA.
    await _voice.stop();
    setState(() => _listening = true);
    debugPrint('[AZ IA micro] listen() démarré avec localeId=$_selectedLocaleId');
    try {
      final started = await _speech.listen(
        onResult: _onSpeechResult,
        onSoundLevelChange: (level) {
          _soundLevel = level;
          debugPrint('[AZ IA micro] niveau sonore : $level');
        },
        listenOptions: SpeechListenOptions(
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 3),
          // Résolue dynamiquement à l'initialisation (voir _pickBestFrenchLocale)
          // plutôt que 'fr_FR' figé en dur — voir _initSpeech pour le détail
          // de l'audit (Master Prompt 112).
          localeId: _selectedLocaleId,
          partialResults: true,
          cancelOnError: false,
          onDevice: false,
          autoPunctuation: false,
          // Master Prompt 127 (Partie 2) — "dictation" est pensé pour des
          // phrases/paragraphes complets (vs "confirmation" par défaut,
          // plus adapté à une courte commande/oui-non), cohérent avec
          // l'objectif "parler naturellement". Vérifié dans le code source
          // du plugin (speech_to_text_platform_interface) : ce réglage
          // n'a d'effet réel qu'sur iOS, jamais sur Android — sur cette
          // plateforme (la seule réellement testée/déployée à ce jour,
          // voir CLAUDE.md) ce champ est donc actuellement sans effet
          // mesurable ; conservé pour ne pas dégrader iOS le jour où un
          // build iOS existera, jamais présenté comme un correctif Android.
          listenMode: ListenMode.dictation,
        ),
      );
      // listen() ne lève pas toujours une exception en cas d'échec silencieux
      // (ex. permission refusée entre-temps) — certaines versions renvoient
      // simplement false/null sans jamais appeler onError. Sans ce contrôle,
      // le bouton restait rouge indéfiniment ("écoute" apparente) sans que
      // la reconnaissance n'ait réellement démarré.
      if (started == false && mounted) {
        setState(() => _listening = false);
        _snack('Impossible de démarrer la reconnaissance vocale.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _listening = false);
      debugPrint('[AZ IA micro] Erreur : $e');
      _snack('Le micro n\'a pas pu démarrer. Réessayez.');
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    debugPrint('[AZ IA micro] ${result.finalResult ? "résultat final" : "résultat partiel"} : '
        '"${result.recognizedWords}" (confiance: ${result.confidence})');
    // Un résultat (même partiel) prouve que le moteur reconnaît bien la
    // locale utilisée — on ne compte plus les error_no_match précédents.
    _consecutiveNoMatchWithSound = 0;
    setState(() => _textCtrl.text = result.recognizedWords);
    if (result.finalResult && result.recognizedWords.trim().isNotEmpty) {
      _handleFinalVoiceResult(result);
    }
  }

  /// Master Prompt 127 — pipeline de compréhension vocale appliqué au
  /// résultat final d'une écoute micro, avant tout envoi à AZ IA :
  /// nettoyage générique (Partie 3) puis correction du vocabulaire métier
  /// AZ Express (Parties 4/5). Si une correction reste incertaine
  /// (correspondance floue) ou si la confiance de reconnaissance est
  /// faible, le message n'est PAS envoyé automatiquement (Partie 9) — le
  /// texte corrigé reste dans le champ, avec un bandeau de confirmation.
  Future<void> _handleFinalVoiceResult(SpeechRecognitionResult result) async {
    setState(() => _analyzing = true);
    final correction = VoiceTextProcessor.process(result.recognizedWords);
    // Délai plancher pour que la phase "Analyse..." (Partie 11) soit
    // réellement perceptible — le traitement lui-même est synchrone et
    // prend largement moins d'une milliseconde.
    await Future.delayed(const Duration(milliseconds: 320));
    if (!mounted) return;

    final lowConfidence = result.confidence >= 0 && result.confidence < 0.35;
    setState(() {
      _analyzing = false;
      _textCtrl.text = correction.text;
      if (correction.hasFuzzyMatch) {
        _voiceConfirmHint = 'Vouliez-vous dire « ${correction.fuzzyMatches.first.suggestion} » ?';
      } else if (lowConfidence) {
        _voiceConfirmHint = 'Vérifiez le texte avant d\'envoyer — reconnaissance incertaine.';
      } else {
        _voiceConfirmHint = null;
      }
    });

    if (_voiceConfirmHint != null) return; // attend une action explicite de l'utilisateur

    _lastMessageWasVoice = true;
    final provider = context.read<AzIaProvider>();
    _send(provider);
  }

  void _dismissVoiceConfirmHint() => setState(() => _voiceConfirmHint = null);

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
      debugPrint('[AZ IA] Erreur clearHistory : $e');
      _snack('Impossible d\'effacer l\'historique. Réessayez.', Colors.red);
    }
  }

  void _scrollToBottom({bool force = false}) {
    if (!force && _userScrolledUp) return;
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _send(AzIaProvider provider, {XFile? image}) async {
    final text = _textCtrl.text;
    if (text.trim().isEmpty && image == null) return;
    _textCtrl.clear();
    _voiceConfirmHint = null;
    _scrollToBottom(force: true);
    final reply = await provider.sendMessage(text, image: image);
    _scrollToBottom(force: true);
    if (_voiceRepliesEnabled && reply != null && reply.trim().isNotEmpty) {
      // Master Prompt 119 — VoiceManager nettoie (markdown/emoji/underscores)
      // et segmente en phrases avec de courtes pauses ; ne plus nettoyer ici
      // pour éviter un double traitement.
      if (mounted) setState(() => _speaking = true);
      await _voice.speak(reply);
      if (mounted) setState(() => _speaking = false);
    }
  }

  /// Envoie un message "canné" déclenché par une puce de suggestion rapide
  /// (Master Prompt 116, Partie 5) — même chemin que `_send`, juste sans
  /// dépendre du contenu du champ de texte.
  Future<void> _sendQuickReply(AzIaProvider provider, String text) async {
    if (provider.isSending) return;
    _lastMessageWasVoice = false;
    _scrollToBottom(force: true);
    final reply = await provider.sendMessage(text);
    _scrollToBottom(force: true);
    if (_voiceRepliesEnabled && reply != null && reply.trim().isNotEmpty) {
      if (mounted) setState(() => _speaking = true);
      await _voice.speak(reply);
      if (mounted) setState(() => _speaking = false);
    }
  }

  // Master Prompt 113, section 13 — image jointe (ordonnance, colis, produit,
  // reçu...) analysée directement par AZ IA. Choix caméra/galerie via une
  // feuille minimale, même esprit que les pickers déjà utilisés ailleurs
  // dans l'app (driver_dashboard.dart, support_screen.dart).
  Future<void> _attachImage(AzIaProvider provider) async {
    if (provider.isSending) {
      _snack('Patientez la fin de la réponse en cours.');
      return;
    }
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choisir depuis la galerie'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        imageQuality: 75,
        maxWidth: 1600,
      );
      if (picked == null || !mounted) return;
      await _send(provider, image: picked);
    } catch (e) {
      debugPrint('[AZ IA] Erreur sélection image : $e');
      if (mounted) _snack('Impossible de charger cette image. Réessayez.', Colors.red);
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
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32, height: 32,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFFFFB74D), Color(0xFFEF6C00)],
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.auto_awesome, color: Colors.white, size: 17),
            ),
            const SizedBox(width: 10),
            const Text('AZ IA', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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

          // Suggestions rapides (Master Prompt 117) : déclarées par le
          // serveur dans `response.actions` (responseBuilder.js), plus
          // aucune devinée côté client — uniquement sous la toute dernière
          // réponse d'AZ IA, jamais pendant l'envoi ni s'il y a déjà une
          // carte de confirmation à traiter (évite d'empiler deux blocs
          // d'action en même temps), et seulement si le serveur en a
          // déclaré au moins une pour ce type de réponse.
          final lastMsg = provider.messages.isNotEmpty ? provider.messages.last : null;
          final lastActions = lastMsg?.response?.actions ?? const [];
          final showQuickReplies = !provider.isSending &&
              provider.pendingAction == null &&
              lastMsg != null &&
              lastMsg.sender == AzIaSender.assistant &&
              lastActions.isNotEmpty;

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
                            return _ThinkingIndicator(
                              key: const ValueKey('thinking'),
                              voiceOrigin: _lastMessageWasVoice,
                            );
                          }
                          final msg = provider.messages[i];
                          return _AnimatedEntrance(
                            key: ValueKey(msg.id),
                            child: _MessageBubble(message: msg),
                          );
                        },
                      ),
              ),
              if (showQuickReplies)
                _QuickReplyChips(
                  response: lastMsg.response!,
                  actions: lastActions,
                  onTap: (text) => _sendQuickReply(provider, text),
                ),
              if (provider.pendingAction != null)
                _PendingActionCard(
                  action: provider.pendingAction!,
                  confirming: provider.confirming,
                  onConfirm: provider.confirmPendingAction,
                  onCancel: provider.cancelPendingAction,
                ),
              // Master Prompt 127 (Partie 11) — phases "Analyse..."/
              // "Réponse..." de la compréhension vocale ; "Écoute..." est
              // déjà porté par le hint du champ de texte (_InputBar).
              if (_analyzing) const _VoicePhaseBanner(label: 'Analyse...', icon: Icons.psychology_outlined),
              if (!_analyzing && _voiceConfirmHint != null)
                _VoiceConfirmBanner(
                  hint: _voiceConfirmHint!,
                  onSend: () => _send(context.read<AzIaProvider>()),
                  onDismiss: _dismissVoiceConfirmHint,
                ),
              if (_speaking) const _VoicePhaseBanner(label: 'Réponse...', icon: Icons.volume_up_rounded),
              _InputBar(
                controller: _textCtrl,
                enabled: !provider.isSending,
                listening: _listening,
                speechAvailable: _speechAvailable,
                onSend: () {
                  // Un envoi déclenché manuellement (bouton/clavier) n'est
                  // jamais "d'origine vocale", même si le champ contient
                  // encore le texte d'une dictée précédente non envoyée.
                  _lastMessageWasVoice = false;
                  _voiceConfirmHint = null;
                  _send(provider);
                },
                onMicTap: () => _toggleListening(provider),
                onAttachTap: () => _attachImage(provider),
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

// ── Avatar (Partie 1) — petit cercle dégradé pour AZ IA, cercle plein coloré
// pour l'utilisateur. Purement décoratif, pas de photo de profil réelle.
class _Avatar extends StatelessWidget {
  final bool isUser;
  const _Avatar({required this.isUser});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28, height: 28,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isUser
              ? [AppColors.primary, AppColors.primary.withValues(alpha: 0.75)]
              : const [Color(0xFFFFB74D), Color(0xFFEF6C00)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        shape: BoxShape.circle,
      ),
      child: Icon(
        isUser ? Icons.person : Icons.auto_awesome,
        color: Colors.white,
        size: 14,
      ),
    );
  }
}

// ── Bulle/carte d'un message (Master Prompt 117) — dispatch UNIQUEMENT sur
// `message.response.type` (buildResponseCard, az_ia_response_widgets.dart) :
// plus aucune heuristique de mot-clé ni de longueur de texte. Les messages
// utilisateur restent toujours une simple bulle (jamais de carte pour ce
// qu'on a soi-même tapé, qui n'a de toute façon pas de `response`).
class _MessageBubble extends StatelessWidget {
  final AzIaMessage message;
  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.sender == AzIaSender.user;

    // Filet de sécurité — un message assistant sans texte ET sans donnée de
    // payload exploitable ne doit jamais produire une carte fantôme (cadre
    // blanc vide + icône seule à gauche). Gate sur le texte COMPLET du
    // message (pas `revealedText`, encore partiel pendant la machine à
    // écrire) pour ne jamais masquer un message en cours de révélation.
    if (!isUser &&
        message.text.trim().isEmpty &&
        (message.response == null || !message.response!.hasVisibleContent)) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[const _Avatar(isUser: false), const SizedBox(width: 8)],
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
              child: _TypewriterReveal(
                message: message,
                builder: (context, revealedText) {
                  if (isUser) return _buildUserBubble(revealedText);
                  // Compatibilité descendante (Prompt 117) : un message
                  // assistant sans `response` (historique très ancien,
                  // avant ce déploiement) retombe sur un texte brut simple
                  // plutôt que de planter.
                  final response = message.response;
                  if (response == null) return _buildLegacyBubble(revealedText);
                  return buildResponseCard(response.withMessage(revealedText));
                },
              ),
            ),
          ),
          if (isUser) ...[const SizedBox(width: 8), const _Avatar(isUser: true)],
        ],
      ),
    );
  }

  Widget _buildUserBubble(String text) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primary, AppColors.primary.withValues(alpha: 0.85)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(6),
        ),
        boxShadow: [BoxShadow(color: AppColors.primary.withValues(alpha: 0.25), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.4)),
    );
  }

  Widget _buildLegacyBubble(String text) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
          bottomLeft: Radius.circular(6),
          bottomRight: Radius.circular(20),
        ),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, 3))],
      ),
      child: AzIaRichBlocks(blocks: AzIaMessageParser.parseBlocks(text)),
    );
  }
}

// ── Effet machine à écrire (Partie 2) — révèle `message.text`
// progressivement puis fige `message.animated = true` pour ne jamais
// rejouer l'animation lors d'une reconstruction ultérieure du widget (même
// message, nouvelle instance d'État après un scroll par exemple).
class _TypewriterReveal extends StatefulWidget {
  final AzIaMessage message;
  final Widget Function(BuildContext, String) builder;
  const _TypewriterReveal({required this.message, required this.builder});

  @override
  State<_TypewriterReveal> createState() => _TypewriterRevealState();
}

class _TypewriterRevealState extends State<_TypewriterReveal> {
  Timer? _timer;
  int _revealedLength = 0;

  @override
  void initState() {
    super.initState();
    if (widget.message.animated || widget.message.text.isEmpty) {
      _revealedLength = widget.message.text.length;
      return;
    }
    _revealedLength = 0;
    // Vitesse adaptative : un message court se révèle vite, un long ne
    // dépasse pas ~900ms au total plutôt que de traîner en longueur.
    final totalChars = widget.message.text.length;
    final stepChars = (totalChars / 45).ceil().clamp(1, 8);
    const tick = Duration(milliseconds: 16);
    _timer = Timer.periodic(tick, (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _revealedLength = (_revealedLength + stepChars).clamp(0, totalChars);
      });
      if (_revealedLength >= totalChars) {
        t.cancel();
        widget.message.animated = true;
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final revealed = widget.message.text.substring(0, _revealedLength);
    return widget.builder(context, revealed);
  }
}

// ── Apparition progressive (Partie 1) — fondu + léger glissement vertical,
// une seule fois par instance de widget grâce aux clés stables posées dans
// le ListView.builder (nouveaux messages seulement, jamais l'historique).
class _AnimatedEntrance extends StatefulWidget {
  final Widget child;
  const _AnimatedEntrance({super.key, required this.child});

  @override
  State<_AnimatedEntrance> createState() => _AnimatedEntranceState();
}

class _AnimatedEntranceState extends State<_AnimatedEntrance> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 260),
  )..forward();
  late final Animation<double> _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
  late final Animation<Offset> _slide = Tween(begin: const Offset(0, 0.06), end: Offset.zero)
      .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

// ── "AZ IA réfléchit..." (Partie 2) — trois points qui pulsent en séquence,
// remplace l'ancien simple spinner circulaire.
class _ThinkingIndicator extends StatefulWidget {
  // Master Prompt 127 (Partie 11) — quand le message qui a déclenché cette
  // attente vient d'une dictée vocale, la première phase affichée est
  // "Compréhension..." plutôt que directement "AZ IA réfléchit" : un
  // habillage textuel qui reflète mieux la chaîne réelle
  // (écoute→analyse→compréhension→réponse), sans changer le comportement
  // réseau/timeout déjà en place (Master Prompt 121, `_slow`).
  final bool voiceOrigin;
  const _ThinkingIndicator({super.key, this.voiceOrigin = false});

  @override
  State<_ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<_ThinkingIndicator> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 1100),
  )..repeat();

  // Master Prompt 121 — sans ce délai, une attente jusqu'à 90s (timeout
  // réseau côté client) restait silencieuse à part le point qui pulse ;
  // un message progressif rassure sans changer le comportement réseau.
  bool _slow = false;
  Timer? _slowTimer;
  // Master Prompt 127 — bascule "Compréhension..." → "AZ IA réfléchit"
  // après 2.5s, purement cosmétique (une attente réelle dépasse rarement
  // ce délai, donc l'utilisateur voit les deux phases en pratique).
  bool _pastUnderstandingPhase = false;
  Timer? _understandingTimer;

  @override
  void initState() {
    super.initState();
    _slowTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _slow = true);
    });
    if (widget.voiceOrigin) {
      _understandingTimer = Timer(const Duration(milliseconds: 2500), () {
        if (mounted) setState(() => _pastUnderstandingPhase = true);
      });
    }
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    _understandingTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  String get _label {
    if (_slow) return 'Cela prend plus de temps que prévu…';
    if (widget.voiceOrigin && !_pastUnderstandingPhase) return 'Compréhension...';
    return 'AZ IA réfléchit';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const _Avatar(isUser: false),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(20), topRight: Radius.circular(20),
                bottomLeft: Radius.circular(6), bottomRight: Radius.circular(20),
              ),
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, 3))],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _label,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                ),
                const SizedBox(width: 6),
                ...List.generate(3, (i) {
                  return AnimatedBuilder(
                    animation: _ctrl,
                    builder: (context, _) {
                      final phase = (_ctrl.value * 3 - i) % 3;
                      final opacity = phase < 1 ? (0.3 + 0.7 * (1 - (phase - 0.5).abs() * 2)).clamp(0.3, 1.0) : 0.3;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1.5),
                        child: Opacity(
                          opacity: opacity,
                          child: Container(
                            width: 5, height: 5,
                            decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                          ),
                        ),
                      );
                    },
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Suggestions rapides (Master Prompt 117) — puces déclarées par le
// serveur dans `response.actions` (responseBuilder.js), plus aucun mot-clé
// deviné côté client (contrairement au Prompt 116). Chaque puce envoie un
// texte pré-rempli via le même chemin que la saisie manuelle.
class _QuickReplyChips extends StatelessWidget {
  final AzIaStructuredResponse response;
  final List<AzIaResponseAction> actions;
  final ValueChanged<String> onTap;
  const _QuickReplyChips({required this.response, required this.actions, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = colorForHex(response.color);
    final icon = iconForName(response.icon);

    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
        itemCount: actions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final action = actions[i];
          return ActionChip(
            // Master Prompt "Corrections finales avant publication" — Bug
            // Mineur #4 : `backgroundColor` ci-dessous reste blanc quel que
            // soit le thème (jamais theme-aware) — sans couleur de texte
            // explicite, le style hérité du ChipThemeData global (lui-même
            // sans couleur fixe, donc dépendant du thème clair/sombre actif)
            // pouvait produire du texte clair sur fond blanc en mode sombre,
            // invisible. AppColors.text est une constante toujours foncée,
            // garantissant le contraste quel que soit le thème.
            label: Text(action.label,
                style: const TextStyle(fontSize: 12.5, color: AppColors.text)),
            avatar: Icon(icon, size: 14, color: color),
            backgroundColor: Colors.white,
            side: BorderSide(color: color.withValues(alpha: 0.25)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            onPressed: () => onTap(action.message),
          );
        },
      ),
    );
  }
}

// Master Prompt 115 — carte de confirmation pour toute action AZ IA
// financière/destructrice (`ai_pending_actions`). C'était la pièce manquante :
// AZ IA créait déjà l'action en attente côté serveur, mais rien côté client
// ne l'affichait jamais ni n'appelait `aiConfirmAction` — l'utilisateur
// restait bloqué face à une réponse texte décrivant une confirmation "via
// l'interface" qui n'existait pas.
class _PendingActionCard extends StatelessWidget {
  final AzIaPendingAction action;
  final bool confirming;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const _PendingActionCard({
    required this.action,
    required this.confirming,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.orange.shade200),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, color: Colors.orange.shade800, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Confirmation requise',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(action.summaryFr, style: const TextStyle(fontSize: 13.5, height: 1.35)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: confirming ? null : onCancel,
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('Annuler'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: confirming ? null : onConfirm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                  ),
                  child: confirming
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Confirmer'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Master Prompt 127 (Partie 11) — bandeau discret pour les phases
// "Analyse..."/"Réponse..." de la compréhension vocale. Volontairement
// minimal (icône + texte + spinner), pour ne jamais concurrencer visuellement
// la bulle "AZ IA réfléchit" déjà en place dans le fil de conversation.
class _VoicePhaseBanner extends StatelessWidget {
  final String label;
  final IconData icon;
  const _VoicePhaseBanner({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14, height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
          ),
          const SizedBox(width: 10),
          Icon(icon, size: 16, color: AppColors.primary),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 13, color: AppColors.primary, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// Master Prompt 127 (Partie 9) — bandeau de confirmation affiché quand la
// reconnaissance vocale est incertaine (correction floue ou confiance
// faible) : le texte corrigé reste dans le champ, mais rien n'est envoyé
// tant que l'utilisateur n'a pas explicitement confirmé ou corrigé.
class _VoiceConfirmBanner extends StatelessWidget {
  final String hint;
  final VoidCallback onSend;
  final VoidCallback onDismiss;

  const _VoiceConfirmBanner({
    required this.hint,
    required this.onSend,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.mic_outlined, color: Colors.orange.shade800, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(hint, style: const TextStyle(fontSize: 13, height: 1.3)),
          ),
          TextButton(onPressed: onDismiss, child: const Text('Corriger')),
          ElevatedButton(
            onPressed: onSend,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            child: const Text('Envoyer'),
          ),
        ],
      ),
    );
  }
}

// Master Prompt 127 (Partie 11) — anneau qui pulse pendant l'écoute, pour
// que la phase "Écoute..." soit visuellement évidente (avant, le bouton
// rouge restait statique, seul le hint texte du champ changeait).
class _MicButton extends StatefulWidget {
  final bool listening;
  final bool enabled;
  final VoidCallback onTap;
  const _MicButton({required this.listening, required this.enabled, required this.onTap});

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.enabled ? widget.onTap : null,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, child) {
          final scale = widget.listening ? 1.0 + (_ctrl.value * 0.14) : 1.0;
          return Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (widget.listening)
                  Transform.scale(
                    scale: scale,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.red.withValues(alpha: 0.25 * (1 - _ctrl.value)),
                      ),
                    ),
                  ),
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: widget.listening
                        ? Colors.red
                        : (widget.enabled ? Colors.grey.shade300 : Colors.grey.shade100),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    widget.listening ? Icons.mic : Icons.mic_none,
                    color: widget.listening
                        ? Colors.white
                        : (widget.enabled ? Colors.black54 : Colors.grey.shade400),
                    size: 22,
                  ),
                ),
              ],
            ),
          );
        },
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
  final VoidCallback onAttachTap;

  const _InputBar({
    required this.controller,
    required this.enabled,
    required this.listening,
    required this.speechAvailable,
    required this.onSend,
    required this.onMicTap,
    required this.onAttachTap,
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
          GestureDetector(
            onTap: enabled ? onAttachTap : null,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: enabled ? Colors.grey.shade100 : Colors.grey.shade50,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.add_photo_alternate_outlined,
                color: enabled ? Colors.black54 : Colors.grey.shade400,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 6),
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
            _MicButton(listening: listening, enabled: enabled, onTap: onMicTap),
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
