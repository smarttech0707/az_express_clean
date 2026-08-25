import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/az_ia_provider.dart';
import '../../screens/ai/az_ia_chat_screen.dart';
import '../../screens/ai/az_ia_history_screen.dart';
import '../../services/notification_service.dart';
import '../../theme/az_ia_theme.dart';
import 'az_ia_logo.dart';

/// Hôte global d'AZ IA placé au-dessus du Navigator principal.
/// Seul cet arbre léger est reconstruit pendant un déplacement.
class AzIaFloatingAssistant extends StatefulWidget {
  final Widget child;

  const AzIaFloatingAssistant({super.key, required this.child});

  @override
  State<AzIaFloatingAssistant> createState() => _AzIaFloatingAssistantState();
}

enum _AssistantMenuAction { newConversation, history }

class _AzIaFloatingAssistantState extends State<AzIaFloatingAssistant>
    with SingleTickerProviderStateMixin {
  static const _xKey = 'az_ia_floating_x';
  static const _yKey = 'az_ia_floating_y';
  static const _size = 64.0;

  // Position par défaut déjà un coin (bas-droit, convention FAB standard) —
  // avant ce correctif, .68 n'était pas un coin et pouvait recouvrir un
  // contenu d'écran dès la première installation, sans qu'aucun glissement
  // n'ait encore eu lieu.
  Offset _position = const Offset(1, 1);
  bool _dragging = false;
  bool _hiddenForSession = false;
  bool _minimized = false;
  bool _openingChat = false;
  _AssistantMenuAction? _menuAction;
  late final AnimationController _haloController;

  @override
  void initState() {
    super.initState();
    _haloController = AnimationController(
      vsync: this,
      duration: AzIaTheme.ambient,
    )..repeat(reverse: true);
    _restorePosition();
  }

  Future<void> _restorePosition() async {
    final prefs = await SharedPreferences.getInstance();
    final x = prefs.getDouble(_xKey);
    final y = prefs.getDouble(_yKey);
    if (!mounted || x == null || y == null) return;
    // Auto-correction (Master Prompt "correction du chevauchement AZ IA") :
    // une position verticale déjà enregistrée avant ce correctif peut être
    // n'importe où entre 0 et 1 — y compris au milieu de l'écran, là où
    // certains écrans (ex. le récapitulatif Livraison, dont la feuille du bas
    // occupe presque tout l'écran dès la phase 6) placent des boutons
    // "Modifier" réels. On la ramène au coin le plus proche (haut ou bas),
    // exactement comme _snapToNearestCorner() le fait désormais à chaque
    // relâchement de glissement — sans coin milieu-écran, aucun écran de
    // l'app ne peut plus se faire recouvrir par la bulle par défaut.
    final snapped = _snapToNearestCorner(Offset(
      x.clamp(0, 1).toDouble(),
      y.clamp(0, 1).toDouble(),
    ));
    setState(() => _position = snapped);
    if (snapped.dx != x || snapped.dy != y) await _savePosition();
  }

  /// Colle [position] au coin (haut ou bas ; gauche ou droite) le plus
  /// proche — jamais un point milieu-écran, structurellement le plus
  /// susceptible de recouvrir un contenu important (ligne "Modifier", champ,
  /// suggestion...) sur n'importe quel écran de l'app.
  Offset _snapToNearestCorner(Offset position) => Offset(
        position.dx >= .5 ? 1 : 0,
        position.dy >= .5 ? 1 : 0,
      );

  Future<void> _savePosition() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_xKey, _position.dx);
    await prefs.setDouble(_yKey, _position.dy);
  }

  @override
  void dispose() {
    _haloController.dispose();
    super.dispose();
  }

  /// La bulle est construite dans `MaterialApp.builder`, comme sœur du
  /// Navigator. Son BuildContext ne sert donc jamais à retrouver un Navigator
  /// ou un Overlay : seule la clé du Navigator principal est utilisée.
  NavigatorState? _rootNavigator() {
    final navigator = NotificationService.navigatorKey.currentState;
    if (navigator == null || !navigator.mounted) {
      debugPrint('AZ IA : Navigator principal introuvable');
      return null;
    }
    return navigator;
  }

  Future<void> _openChat() async {
    if (_openingChat) return;
    final navigator = _rootNavigator();
    if (navigator == null) return;
    final pending = context.read<AzIaProvider>().pendingAction;
    debugPrint(
        '[AZ_IA_OPEN_CHAT] ouverture du chat, actionId en attente=${pending?.id}');
    setState(() => _openingChat = true);
    try {
      await navigator.push(
        PageRouteBuilder<void>(
          pageBuilder: (_, animation, __) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: .96, end: 1).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
              ),
              child: const AzIaChatScreen(),
            ),
          ),
          transitionDuration: const Duration(milliseconds: 250),
          reverseTransitionDuration: const Duration(milliseconds: 200),
        ),
      );
    } finally {
      if (mounted) setState(() => _openingChat = false);
    }
  }

  Future<void> _showMenu() async {
    final navigator = _rootNavigator();
    if (navigator == null) return;
    setState(() => _openingChat = true);
    await showModalBottomSheet<void>(
      context: navigator.context,
      useRootNavigator: true,
      backgroundColor: AzIaTheme.surface,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _menuTile(Icons.add_comment_outlined, 'Nouvelle conversation', () {
              Navigator.pop(sheetContext);
              _menuAction = _AssistantMenuAction.newConversation;
            }),
            _menuTile(Icons.history, 'Historique', () {
              Navigator.pop(sheetContext);
              _menuAction = _AssistantMenuAction.history;
            }),
            _menuTile(Icons.remove_circle_outline, 'Réduire', () {
              Navigator.pop(sheetContext);
              setState(() => _minimized = true);
            }),
            _menuTile(
                Icons.visibility_off_outlined, 'Masquer pendant cette session',
                () {
              Navigator.pop(sheetContext);
              setState(() => _hiddenForSession = true);
            }),
            _menuTile(
                Icons.close, 'Fermer AZ IA', () => Navigator.pop(sheetContext)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    final action = _menuAction;
    _menuAction = null;
    if (action == _AssistantMenuAction.newConversation) {
      setState(() => _openingChat = false);
      await context.read<AzIaProvider>().startNewConversation();
      if (mounted) _openChat();
    } else if (action == _AssistantMenuAction.history) {
      debugPrint('[AZ_IA_OPEN_HISTORY] ouverture de l\'écran historique');
      final rootNavigator = _rootNavigator();
      if (rootNavigator == null) {
        if (mounted) setState(() => _openingChat = false);
        return;
      }
      final opened = await rootNavigator.push<bool>(
        MaterialPageRoute(builder: (_) => const AzIaHistoryScreen()),
      );
      if (!mounted) return;
      setState(() => _openingChat = false);
      if (opened == true) _openChat();
    } else if (!_hiddenForSession) {
      setState(() => _openingChat = false);
    }
  }

  Widget _menuTile(IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: AzIaTheme.textPrimary),
      title: Text(label, style: const TextStyle(color: AzIaTheme.textPrimary)),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboardOpen = media.viewInsets.bottom > 0;
    final bubbleSize = _minimized ? 44.0 : _size;
    final horizontalPadding = 12.0;
    final top = media.padding.top + 12;
    final reservedBottom =
        math.max(media.padding.bottom + 92, media.viewInsets.bottom + 16);
    final maxX = math.max(
        horizontalPadding, media.size.width - bubbleSize - horizontalPadding);
    final maxY = math.max(top, media.size.height - bubbleSize - reservedBottom);
    final left = horizontalPadding + (maxX - horizontalPadding) * _position.dx;
    final topPosition = top + (maxY - top) * _position.dy;
    final showBubble = !_hiddenForSession && !_openingChat;

    return Stack(
      children: [
        widget.child,
        if (showBubble)
          Selector<AzIaProvider, bool>(
            selector: (_, provider) {
              final messages = provider.messages;
              return provider.pendingAction != null ||
                  (messages.isNotEmpty &&
                      (messages.last.response?.actions.isNotEmpty ?? false));
            },
            builder: (_, hasSuggestion, __) => AnimatedPositioned(
              duration:
                  _dragging ? Duration.zero : const Duration(milliseconds: 250),
              curve: Curves.easeOutBack,
              left: left,
              top: keyboardOpen ? math.min(topPosition, maxY) : topPosition,
              // Largeur/hauteur explicites (Phase 3 — durcissement défensif) :
              // sans elles, un `Positioned` avec seulement left/top laisse
              // l'enfant se dimensionner lui-même — si jamais son contenu
              // devait un jour échouer à se construire, Flutter substituerait
              // un ErrorWidget qui, non contraint, s'étend pour occuper tout
              // l'espace restant du Stack (jusqu'au bord de l'écran) au lieu
              // de rester à la taille réelle de la bulle. Contraindre à
              // `bubbleSize` ne masque aucune erreur (toujours remontée à
              // FlutterError.onError/Crashlytics) — ça borne juste son rayon
              // d'impact visuel à la taille réellement prévue pour la bulle.
              width: bubbleSize,
              height: bubbleSize,
              child: _bubble(
                size: bubbleSize,
                maxX: maxX,
                top: top,
                maxY: maxY,
                hasSuggestion: hasSuggestion,
              ),
            ),
          ),
      ],
    );
  }

  Widget _bubble({
    required double size,
    required double maxX,
    required double top,
    required double maxY,
    required bool hasSuggestion,
  }) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return RepaintBoundary(
      child: Semantics(
        button: true,
        label: 'Ouvrir l’assistant AZ IA',
        hint: 'Appui long pour plus d’options',
        // Master Prompt "AZ IA 10/10" — `Tooltip` a été retiré ici : il
        // s'appuie en interne sur `Overlay.of(context)`, or ce widget est
        // monté via `MaterialApp.builder` (voir main.dart), donc en dehors
        // du LookupBoundary où vit l'Overlay créé par le Navigator. Confirmé
        // en conditions réelles sur appareil : ça faisait planter la
        // construction de la bulle avec « No Overlay widget found »,
        // remplacée par un ErrorWidget qui, faute de contrainte de taille,
        // s'étendait pour occuper tout l'écran (bande rouge/jaune visible
        // sur chaque page de l'app). Le `Semantics` ci-dessus porte déjà le
        // même libellé pour les lecteurs d'écran — Tooltip n'apportait rien
        // d'irremplaçable sur une interface tactile.
        child: GestureDetector(
          onTap:
              _minimized ? () => setState(() => _minimized = false) : _openChat,
          onLongPress: _showMenu,
          onPanStart: (_) => setState(() => _dragging = true),
          onPanUpdate: (details) {
            final xRange = math.max(1, maxX - 12);
            final yRange = math.max(1, maxY - top);
            final nextX = (_position.dx * xRange + details.delta.dx) / xRange;
            final nextY = (_position.dy * yRange + details.delta.dy) / yRange;
            setState(() => _position = Offset(
                  nextX.clamp(0, 1).toDouble(),
                  nextY.clamp(0, 1).toDouble(),
                ));
          },
          onPanEnd: (_) {
            // Colle aux DEUX axes (avant : seul dx se collait au bord ; dy
            // restait libre, ce qui permettait à la bulle de se stabiliser
            // n'importe où en hauteur — y compris pile sur un bouton
            // "Modifier" de contenu, comme confirmé sur appareil dans le
            // récapitulatif Livraison). Un coin (haut/bas × gauche/droite)
            // est la seule zone structurellement libre sur tous les écrans
            // de l'app déjà audités.
            setState(() {
              _dragging = false;
              _position = _snapToNearestCorner(_position);
            });
            _savePosition();
          },
          child: AnimatedBuilder(
            animation: _haloController,
            builder: (_, child) {
              final opacity =
                  reduceMotion ? .28 : .16 + _haloController.value * .14;
              return DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AzIaTheme.electricBlue.withValues(alpha: opacity),
                      blurRadius: 18,
                      spreadRadius: 2,
                    ),
                    const BoxShadow(
                        color: Colors.black38,
                        blurRadius: 10,
                        offset: Offset(0, 5)),
                  ],
                ),
                child: child,
              );
            },
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AzIaTheme.surface,
                border: Border.all(
                    color: AzIaTheme.electricBlue.withValues(alpha: .75)),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Center(
                      child: AzIaLogo(
                          size: size * .78, variant: AzIaLogoVariant.avatar)),
                  if (hasSuggestion && !_minimized)
                    const Positioned(
                      top: 4,
                      right: 4,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AzIaTheme.azOrange,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(color: Colors.black38, blurRadius: 3)
                          ],
                        ),
                        child: SizedBox(width: 10, height: 10),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
