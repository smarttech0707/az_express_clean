import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../web_theme.dart';
import 'az_logo.dart';

class WebNavBar extends StatefulWidget {
  final String currentRoute;
  const WebNavBar({super.key, required this.currentRoute});

  @override
  State<WebNavBar> createState() => _WebNavBarState();
}

class _WebNavBarState extends State<WebNavBar> {
  bool _scrolled = false;
  bool _menuOpen = false;

  static const _links = [
    ('Services',        '/services'),
    ('Comment ça marche', '/comment-ca-marche'),
    ('Commerçants',     '/commercants'),
    ('Livreurs',        '/livreurs'),
    ('À propos',        '/a-propos'),
    ('Contact',         '/contact'),
  ];

  @override
  Widget build(BuildContext context) {
    final desk = isDesktop(context);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollUpdateNotification) {
          final s = n.metrics.pixels > 10;
          if (s != _scrolled) setState(() => _scrolled = s);
        }
        return false;
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        decoration: BoxDecoration(
          color: kWhite,
          boxShadow: _scrolled || _menuOpen
              ? [const BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 2))]
              : [],
        ),
        child: desk ? _desktopBar() : _mobileBar(),
      ),
    );
  }

  Widget _desktopBar() {
    return Container(
      height: 72,
      padding: EdgeInsets.symmetric(horizontal: hPad(context)),
      child: Row(children: [
        _logo(),
        const Spacer(),
        ..._links.map((l) => _navLink(l.$1, l.$2)),
        const SizedBox(width: 24),
        _ctaButton(),
      ]),
    );
  }

  Widget _mobileBar() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            _logo(),
            const Spacer(),
            GestureDetector(
              onTap: () => setState(() => _menuOpen = !_menuOpen),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  _menuOpen ? Icons.close_rounded : Icons.menu_rounded,
                  key: ValueKey(_menuOpen),
                  color: kText,
                  size: 26,
                ),
              ),
            ),
          ]),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          child: _menuOpen
              ? Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ..._links.map((l) => _mobileLink(l.$1, l.$2)),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: _ctaButton(full: true),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _logo() {
    return GestureDetector(
      onTap: () => context.go('/'),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AzLogo(size: 36),
          const SizedBox(width: 10),
          Text(
            'AZ Express',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: kText,
              letterSpacing: -0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _navLink(String label, String route) {
    final active = widget.currentRoute == route;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => context.go(route),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? kOrange : kText,
                ),
              ),
              if (active)
                Container(
                  margin: const EdgeInsets.only(top: 3),
                  width: 20, height: 2,
                  decoration: BoxDecoration(
                    color: kOrange,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mobileLink(String label, String route) {
    final active = widget.currentRoute == route;
    return GestureDetector(
      onTap: () {
        setState(() => _menuOpen = false);
        context.go(route);
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: kDivider, width: 0.5)),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? kOrange : kWhite,
          ),
        ),
      ),
    );
  }

  Widget _ctaButton({bool full = false}) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => context.go('/connexion'),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: full ? 0 : 20,
            vertical: 11,
          ),
          width: full ? double.infinity : null,
          alignment: full ? Alignment.center : null,
          decoration: orangeGlowDecoration,
          child: Text(
            'Commander',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: kWhite,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
