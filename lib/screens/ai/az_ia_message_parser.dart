// ═══════════════════════════════════════════════════════════════════════════
// Parseur de message AZ IA — met en forme le texte de Claude (titres/listes/
// gras déjà utilisés dans ses réponses, voir SYSTEM_PROMPT) en blocs
// affichables proprement. Le TYPE de carte à afficher et son icône/couleur
// ne sont PLUS devinés ici depuis 2026-07-14 (Master Prompt 117) — ils
// viennent désormais de `response.type`/`response.icon`/`response.color`,
// construits côté serveur à partir de l'outil réellement exécuté (voir
// functions/azia/responseBuilder.js et az_ia_response_widgets.dart). Ce
// fichier ne fait plus QUE de la mise en forme de texte, plus aucune
// supposition sur le contenu.
// ═══════════════════════════════════════════════════════════════════════════

enum AzIaBlockType { heading, subheading, bullet, divider, paragraph }

class AzIaBlock {
  final AzIaBlockType type;
  final String text;
  const AzIaBlock(this.type, this.text);
}

class AzIaMessageParser {
  /// Découpe un texte de réponse en blocs structurés :
  /// - lignes commençant par `#`/`##`/`###` -> titre/sous-titre
  /// - lignes en **gras** seules sur leur ligne -> sous-titre
  /// - lignes commençant par `-`/`•`/`*` -> puce
  /// - lignes de type `---`/`___` -> séparateur
  /// - le reste -> paragraphe
  static List<AzIaBlock> parseBlocks(String text) {
    final lines = text.split('\n');
    final blocks = <AzIaBlock>[];
    final paragraphBuffer = <String>[];

    void flushParagraph() {
      if (paragraphBuffer.isEmpty) return;
      final joined = paragraphBuffer.join(' ').trim();
      if (joined.isNotEmpty)
        blocks.add(AzIaBlock(AzIaBlockType.paragraph, joined));
      paragraphBuffer.clear();
    }

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        flushParagraph();
        continue;
      }
      if (RegExp(r'^(-{3,}|_{3,})$').hasMatch(line)) {
        flushParagraph();
        blocks.add(const AzIaBlock(AzIaBlockType.divider, ''));
        continue;
      }
      final headingMatch = RegExp(r'^#{1,2}\s+(.*)$').firstMatch(line);
      if (headingMatch != null) {
        flushParagraph();
        blocks.add(
            AzIaBlock(AzIaBlockType.heading, headingMatch.group(1)!.trim()));
        continue;
      }
      final subheadingMatch = RegExp(r'^#{3,6}\s+(.*)$').firstMatch(line);
      if (subheadingMatch != null) {
        flushParagraph();
        blocks.add(AzIaBlock(
            AzIaBlockType.subheading, subheadingMatch.group(1)!.trim()));
        continue;
      }
      // Une ligne entièrement en gras (ex. "**Récapitulatif**") sert de
      // sous-titre visuel plutôt que d'être affichée avec des étoiles.
      final boldOnlyMatch = RegExp(r'^\*\*(.+)\*\*:?$').firstMatch(line);
      if (boldOnlyMatch != null) {
        flushParagraph();
        blocks.add(AzIaBlock(
            AzIaBlockType.subheading, boldOnlyMatch.group(1)!.trim()));
        continue;
      }
      final bulletMatch = RegExp(r'^[-•*]\s+(.*)$').firstMatch(line);
      if (bulletMatch != null) {
        flushParagraph();
        blocks
            .add(AzIaBlock(AzIaBlockType.bullet, bulletMatch.group(1)!.trim()));
        continue;
      }
      paragraphBuffer.add(line);
    }
    flushParagraph();
    return blocks;
  }

  /// Nettoyage avant lecture vocale (Master Prompt 116, Partie 6) — retire
  /// tout marquage markdown que flutter_tts lirait littéralement à voix
  /// haute ("étoile étoile", "dièse"...).
  static String cleanForSpeech(String text) {
    var t = text;
    t = t.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
    t = t.replaceAll('***', '');
    t = t.replaceAll('**', '');
    t = t.replaceAll('`', '');
    t = t.replaceAll(RegExp(r'(?<!\*)\*(?!\*)'), ''); // italique restant
    t = t.replaceAll(RegExp(r'^[-•]\s+', multiLine: true), '');
    t = t.replaceAll(RegExp(r'[ \t]{2,}'), ' ');
    t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return t.trim();
  }
}
