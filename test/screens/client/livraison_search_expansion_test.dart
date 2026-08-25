import 'package:az_express/screens/client/livraison_screen.dart';
import 'package:az_express/services/places_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('porte d’élargissement explicite', () {
    test('est visible seulement après awaitingExpansion sans résultat', () {
      expect(
        shouldShowLivraisonSearchExpansion(
          query: 'Gabriel',
          searched: true,
          searching: false,
          hasResults: false,
          searchState: PlacesSearchState.awaitingExpansion,
        ),
        isTrue,
      );
    });

    test('reste masquée avant cinq caractères', () {
      expect(
        shouldShowLivraisonSearchExpansion(
          query: 'CHU',
          searched: true,
          searching: false,
          hasResults: false,
          searchState: PlacesSearchState.awaitingExpansion,
        ),
        isFalse,
      );
    });

    test('reste masquée si la porte du service n’est pas ouverte', () {
      for (final state in PlacesSearchState.values
          .where((state) => state != PlacesSearchState.awaitingExpansion)) {
        expect(
          shouldShowLivraisonSearchExpansion(
            query: 'Gabriel',
            searched: true,
            searching: false,
            hasResults: false,
            searchState: state,
          ),
          isFalse,
          reason: state.name,
        );
      }
    });

    test('reste masquée pendant une recherche ou avec des résultats', () {
      expect(
        shouldShowLivraisonSearchExpansion(
          query: 'Gabriel',
          searched: true,
          searching: true,
          hasResults: false,
          searchState: PlacesSearchState.awaitingExpansion,
        ),
        isFalse,
      );
      expect(
        shouldShowLivraisonSearchExpansion(
          query: 'Gabriel',
          searched: true,
          searching: false,
          hasResults: true,
          searchState: PlacesSearchState.awaitingExpansion,
        ),
        isFalse,
      );
    });
  });
}
