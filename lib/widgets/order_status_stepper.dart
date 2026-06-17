import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class OrderStatusStepper extends StatelessWidget {
  final String status;
  const OrderStatusStepper({super.key, required this.status});

  static const _steps = [
    _StepDef('Confirmée',  Icons.check_circle_outline_rounded,   Icons.check_circle_rounded),
    _StepDef('Préparée',   Icons.inventory_2_outlined,           Icons.inventory_2_rounded),
    _StepDef('En route',   Icons.electric_bike_outlined,         Icons.electric_bike_rounded),
    _StepDef('Livrée',     Icons.flag_outlined,                  Icons.flag_rounded),
  ];

  // Mapping status → index actif (0-based, -1 = annulé)
  int get _activeIndex {
    switch (status) {
      case 'pending':
      case 'assigned':
        return 0;
      case 'accepted':
        return 1;
      case 'picked_up':
        return 2;
      case 'delivered':
        return 3;
      default:
        return -1; // annulé
    }
  }

  @override
  Widget build(BuildContext context) {
    if (status == 'cancelled') {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.red.shade200),
        ),
        child: const Row(children: [
          Icon(Icons.cancel_rounded, color: Colors.red, size: 20),
          SizedBox(width: 8),
          Text('Commande annulée',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
        ]),
      );
    }

    final active = _activeIndex;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6)],
      ),
      child: Row(
        children: List.generate(_steps.length * 2 - 1, (i) {
          if (i.isOdd) {
            final stepIdx = i ~/ 2;
            final done = stepIdx < active;
            return Expanded(
              child: Container(
                height: 3,
                decoration: BoxDecoration(
                  color: done ? const Color(0xFFFF7A1A) : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            );
          }

          final stepIdx = i ~/ 2;
          final done    = stepIdx < active;
          final current = stepIdx == active;
          final step    = _steps[stepIdx];

          return Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width:  done || current ? 38 : 32,
              height: done || current ? 38 : 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done
                    ? const Color(0xFFFF7A1A)
                    : current
                        ? const Color(0xFFFF7A1A)
                        : Colors.grey.shade100,
                border: current
                    ? Border.all(color: const Color(0xFFFF7A1A), width: 3)
                    : null,
                boxShadow: current
                    ? [BoxShadow(
                        color: const Color(0xFFFF7A1A).withValues(alpha: 0.35),
                        blurRadius: 8, spreadRadius: 1)]
                    : null,
              ),
              child: Icon(
                done ? step.iconFilled : (current ? step.iconFilled : step.icon),
                size: done || current ? 18 : 15,
                color: done || current ? Colors.white : Colors.grey.shade400,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              step.label,
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                color: current
                    ? const Color(0xFFFF7A1A)
                    : done
                        ? Colors.black54
                        : Colors.grey.shade400,
              ),
              textAlign: TextAlign.center,
            ),
          ]);
        }),
      ),
    );
  }
}

class _StepDef {
  final String label;
  final IconData icon;
  final IconData iconFilled;
  const _StepDef(this.label, this.icon, this.iconFilled);
}
