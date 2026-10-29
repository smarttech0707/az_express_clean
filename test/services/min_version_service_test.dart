import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/services/min_version_service.dart';

void main() {
  test('aucun document : jamais de blocage', () {
    expect(MinVersionService.evaluate(null, 5), MinVersionStatus.ok);
  });
  test('build inconnu (0) : jamais de blocage, même si enforce', () {
    expect(MinVersionService.evaluate({'minBuild': 99, 'enforce': true}, 0),
        MinVersionStatus.ok);
  });
  test('version suffisante : ok', () {
    expect(MinVersionService.evaluate({'minBuild': 14, 'enforce': true}, 14),
        MinVersionStatus.ok);
  });
  test('version ancienne sans enforce : simple recommandation', () {
    expect(MinVersionService.evaluate({'minBuild': 14}, 13),
        MinVersionStatus.updateRecommended);
    expect(MinVersionService.evaluate({'minBuild': 14, 'enforce': 'true'}, 13),
        MinVersionStatus.updateRecommended);
  });
  test('version ancienne avec enforce:true : mise à jour requise', () {
    expect(MinVersionService.evaluate({'minBuild': 14, 'enforce': true}, 13),
        MinVersionStatus.updateRequired);
  });
  test('configuration invalide ignorée', () {
    expect(MinVersionService.evaluate({'minBuild': 'x', 'enforce': true}, 1),
        MinVersionStatus.ok);
  });
}
