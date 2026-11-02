import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Barre d'onglets pour AppBar colorée (administration) : libellé actif blanc
/// gras, inactifs blancs, jamais coupés.
///
/// Deux défauts de la `TabBar` par défaut sur une AppBar orange : (1) le libellé et l'indicateur
/// actifs prennent `colorScheme.primary`, un orange quasi identique au fond de
/// l'AppBar, donc l'onglet sélectionné se fond dans la barre ; (2) en mode
/// défilant, `TabAlignment.startOffset` ajoute 52 px à gauche et les quatre
/// libellés dépassent de l'écran à droite sans rien indiquer. Ici : blanc
/// explicite, alignement à gauche, onglets répartis quand ils tiennent, et
/// sinon défilement horizontal avec un dégradé discret + chevron du côté où
/// d'autres onglets existent.
///
/// `backgroundColor` : couleur de fond de l'AppBar qui l'accueille (sert au
/// dégradé des bords) ; à défaut, celle du thème. `controller` : à fournir si
/// la page crée son propre `TabController`, sinon `DefaultTabController`.
/// `tabHeight` : hauteur d'onglet adaptée au texte agrandi.
class AzTabBar extends StatefulWidget implements PreferredSizeWidget {
  const AzTabBar({
    super.key,
    required this.labels,
    this.controller,
    this.backgroundColor,
    this.tabHeight,
  });

  final List<String> labels;
  final TabController? controller;
  final Color? backgroundColor;
  final double? tabHeight;

  /// Zone tactile minimale (Material / Apple HIG : 48 pt).
  static const _minTouch = 48.0;

  @override
  Size get preferredSize =>
      Size.fromHeight(tabHeight ?? _minTouch);

  @override
  State<AzTabBar> createState() => _AzTabBarState();
}

class _AzTabBarState extends State<AzTabBar> {
  // Marges : réduites quand les onglets se partagent la largeur, pour que le
  // plus long libellé tienne dans une part égale ; plus larges au défilement.
  static const _fillPadding = 8.0;
  static const _scrollPadding = 14.0;
  static const _fade = 36.0;

  bool _more = false; // défilement possible à droite
  bool _less = false; // défilement possible à gauche

  bool _onScroll(ScrollMetrics m) {
    final less = m.pixels > 1;
    final more = m.pixels < m.maxScrollExtent - 1;
    if (less != _less || more != _more) {
      setState(() {
        _less = less;
        _more = more;
      });
    }
    return false;
  }

  /// Largeur de texte de chaque libellé (police active, échelle de texte).
  List<double> _textWidths(TextStyle style, TextScaler scaler) => [
        for (final label in widget.labels)
          (TextPainter(
            text: TextSpan(text: label, style: style),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            maxLines: 1,
          )..layout())
              .width,
      ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Typographie du design system (13 px, réduite sur petit écran).
    final labelStyle =
        AppTypography.labelLargeStyle(context, weight: FontWeight.w700);
    final scaler = MediaQuery.textScalerOf(context);
    final bg = widget.backgroundColor ??
        theme.appBarTheme.backgroundColor ??
        theme.colorScheme.primary;

    return LayoutBuilder(builder: (context, box) {
      // Répartis seulement si la plus longue étiquette tient dans une part
      // égale (TabAlignment.fill) ; sinon défilement, jamais de titre coupé.
      final widths = _textWidths(labelStyle, scaler);
      final longest = widths.fold<double>(0, (m, w) => w > m ? w : m);
      final scrolls =
          (longest + _fillPadding * 2) * widths.length > box.maxWidth;
      final bar = TabBar(
        controller: widget.controller,
        isScrollable: scrolls,
        tabAlignment: scrolls ? TabAlignment.start : TabAlignment.fill,
        padding: EdgeInsets.zero,
        labelPadding: EdgeInsets.symmetric(
            horizontal: scrolls ? _scrollPadding : _fillPadding),
        labelStyle: labelStyle,
        unselectedLabelStyle:
            labelStyle.copyWith(fontWeight: FontWeight.w600),
        labelColor: Colors.white,
        // Blanc à 98 % sur l'orange de l'AppBar : ≥ 4,5:1 (testé).
        unselectedLabelColor: const Color(0xFAFFFFFF),
        indicatorColor: Colors.white,
        indicatorWeight: 3,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        overlayColor: WidgetStatePropertyAll(
            Colors.white.withValues(alpha: 0.12)),
        // Une seule ligne : si ça ne tient pas, la barre défile (jamais de titre
        // coupé ni replié sur deux lignes).
        tabs: [
          for (final label in widget.labels)
            Tab(
              height: widget.tabHeight ?? AzTabBar._minTouch,
              child: Text(label, maxLines: 1, softWrap: false),
            ),
        ],
      );
      if (!scrolls) return bar;

      Widget edge(bool visible, bool left) => Positioned(
            left: left ? 0 : null,
            right: left ? null : 0,
            top: 0,
            bottom: 0,
            width: _fade,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: left ? Alignment.centerLeft : Alignment.centerRight,
                      end: left ? Alignment.centerRight : Alignment.centerLeft,
                      colors: [bg, bg.withValues(alpha: 0)],
                    ),
                  ),
                  child: Align(
                    alignment:
                        left ? Alignment.centerLeft : Alignment.centerRight,
                    child: Icon(
                      left
                          ? Icons.chevron_left_rounded
                          : Icons.chevron_right_rounded,
                      size: 20,
                      color: Colors.white,
                      semanticLabel: left
                          ? 'Onglets précédents'
                          : 'Autres onglets',
                    ),
                  ),
                ),
              ),
            ),
          );

      return Stack(
        children: [
          // Défilement sans rebond : sur iOS le rebond décalait la barre au
          // bord et donnait l'impression d'un onglet qui sort de l'écran.
          ScrollConfiguration(
            behavior: ScrollConfiguration.of(context)
                .copyWith(physics: const ClampingScrollPhysics()),
            child: NotificationListener<ScrollMetricsNotification>(
              onNotification: (n) => _onScroll(n.metrics),
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) => n.depth == 0 && _onScroll(n.metrics),
                child: bar,
              ),
            ),
          ),
          edge(_less, true),
          edge(_more, false),
        ],
      );
    });
  }
}
