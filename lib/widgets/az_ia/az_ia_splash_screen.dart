import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/az_ia_theme.dart';
import 'az_ia_logo.dart';

class AzIaSplashScreen extends StatefulWidget {
  final VoidCallback onFinished;

  const AzIaSplashScreen({super.key, required this.onFinished});

  @override
  State<AzIaSplashScreen> createState() => _AzIaSplashScreenState();
}

class _AzIaSplashScreenState extends State<AzIaSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _timer;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AzIaTheme.normal,
    )..forward();
    _timer = Timer(const Duration(milliseconds: 1450), _finish);
  }

  void _finish() {
    if (_finished || !mounted) return;
    _finished = true;
    widget.onFinished();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final animation = reduceMotion
        ? const AlwaysStoppedAnimation<double>(1)
        : CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    return Scaffold(
      backgroundColor: AzIaTheme.night,
      body: Semantics(
        button: true,
        label: 'Passer l’introduction AZ IA',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _finish,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.1),
                radius: 0.85,
                colors: [Color(0xFF142A4A), AzIaTheme.night],
              ),
            ),
            child: Center(
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1).animate(animation),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AzIaLogo(size: 156, variant: AzIaLogoVariant.splash),
                      SizedBox(height: 24),
                      Text(
                        'L’intelligence au service de tous',
                        style: TextStyle(
                            color: AzIaTheme.textPrimary, fontSize: 15),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'par AZ Express',
                        style: TextStyle(
                            color: AzIaTheme.azOrangeLight,
                            fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
