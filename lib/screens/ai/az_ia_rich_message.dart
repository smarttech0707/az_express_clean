import 'package:flutter/material.dart';

import 'az_ia_message_parser.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Rendu riche d'un message AZ IA (Master Prompt 116, Partie 4) — remplace le
// gros pavé de texte brut par des titres/sous-titres/puces/séparateurs.
// Widget de présentation pur, aucune logique métier. L'habillage carte
// (icône/couleur) est désormais porté par az_ia_response_widgets.dart,
// piloté par `response.type` (Master Prompt 117) — plus par un thème deviné
// ici (l'ancienne `AzIaRichCard` de ce fichier a été retirée en conséquence).
// ═══════════════════════════════════════════════════════════════════════════

/// Convertit `**gras**` inline en spans réellement en gras plutôt que
/// d'afficher les étoiles littéralement.
List<InlineSpan> _inlineSpans(String text, TextStyle base) {
  final spans = <InlineSpan>[];
  final pattern = RegExp(r'\*\*(.+?)\*\*');
  var lastEnd = 0;
  for (final match in pattern.allMatches(text)) {
    if (match.start > lastEnd) {
      spans.add(TextSpan(text: text.substring(lastEnd, match.start), style: base));
    }
    spans.add(TextSpan(
      text: match.group(1),
      style: base.copyWith(fontWeight: FontWeight.w700),
    ));
    lastEnd = match.end;
  }
  if (lastEnd < text.length) {
    spans.add(TextSpan(text: text.substring(lastEnd), style: base));
  }
  return spans;
}

class AzIaRichBlocks extends StatelessWidget {
  final List<AzIaBlock> blocks;
  final Color textColor;
  const AzIaRichBlocks({super.key, required this.blocks, this.textColor = Colors.black87});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final block in blocks) _buildBlock(block),
      ],
    );
  }

  Widget _buildBlock(AzIaBlock block) {
    switch (block.type) {
      case AzIaBlockType.heading:
        return Padding(
          padding: const EdgeInsets.only(bottom: 6, top: 2),
          child: Text.rich(
            TextSpan(children: _inlineSpans(block.text, TextStyle(
              color: textColor, fontSize: 16, fontWeight: FontWeight.w800, height: 1.3,
            ))),
          ),
        );
      case AzIaBlockType.subheading:
        return Padding(
          padding: const EdgeInsets.only(bottom: 4, top: 4),
          child: Text.rich(
            TextSpan(children: _inlineSpans(block.text, TextStyle(
              color: textColor, fontSize: 14, fontWeight: FontWeight.w700, height: 1.3,
            ))),
          ),
        );
      case AzIaBlockType.divider:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Divider(height: 1, color: textColor.withValues(alpha: 0.15)),
        );
      case AzIaBlockType.bullet:
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: Container(
                  width: 5, height: 5,
                  decoration: BoxDecoration(color: textColor.withValues(alpha: 0.6), shape: BoxShape.circle),
                ),
              ),
              Expanded(
                child: Text.rich(
                  TextSpan(children: _inlineSpans(block.text, TextStyle(
                    color: textColor, fontSize: 13.5, height: 1.4,
                  ))),
                ),
              ),
            ],
          ),
        );
      case AzIaBlockType.paragraph:
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text.rich(
            TextSpan(children: _inlineSpans(block.text, TextStyle(
              color: textColor, fontSize: 14, height: 1.45,
            ))),
          ),
        );
    }
  }
}

