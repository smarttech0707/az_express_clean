import 'package:firebase_storage/firebase_storage.dart';

/// Supprime en Storage tous les fichiers correspondant aux URLs fournies,
/// à appeler avant (ou après) la suppression du document Firestore associé
/// pour éviter les fichiers orphelins. Chaque suppression est tentée
/// indépendamment (`object-not-found` ignoré — le fichier peut déjà avoir
/// été retiré) ; une erreur sur une URL n'empêche pas les autres d'être
/// tentées. Ne lève jamais d'exception — un échec de nettoyage Storage ne
/// doit jamais bloquer la suppression du document Firestore lui-même.
Future<void> deleteStorageUrls(Iterable<String?> urls) async {
  for (final url in urls) {
    if (url == null || url.isEmpty) continue;
    try {
      await FirebaseStorage.instance.refFromURL(url).delete();
    } on FirebaseException catch (e) {
      if (e.code != 'object-not-found') {
        // Journalisation silencieuse — pas d'utilisateur à prévenir ici,
        // ce nettoyage se fait toujours après confirmation d'une suppression
        // déjà décidée, jamais dans le chemin critique d'une action visible.
      }
    } catch (_) {
      // Idem : ne jamais faire échouer l'appelant pour un souci de nettoyage.
    }
  }
}
