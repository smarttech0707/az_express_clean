@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:az_express/web/configure_url_strategy_web.dart';

class Location implements PlatformLocation {
  @override String pathname = '/';
  @override String search = '';
  @override String hash = '';
  @override Object? get state => null;
  @override String getBaseHref() => '/';
  @override void addPopStateListener(EventListener fn) {}
  @override void removePopStateListener(EventListener fn) {}
  @override void pushState(Object? state, String title, String url) {}
  @override void replaceState(Object? state, String title, String url) {}
  @override void go(int count) {}
}

void main() {
  test('direct partner URL reaches its path, not the home route', () {
    final location = Location()..pathname = '/partenaire/token';
    expect(CompatiblePathUrlStrategy(location).getPath(), '/partenaire/token');
  });
  test('previously shared hash routes remain readable', () {
    final location = Location()..hash = '#/app/commandes';
    expect(CompatiblePathUrlStrategy(location).getPath(), '/app/commandes');
  });
  test('query and proof routes survive without interpreting credential fragments', () {
    final location = Location()..pathname = '/reception/grant'..search = '?source=qr'..hash = '#secret';
    expect(CompatiblePathUrlStrategy(location).getPath(), '/reception/grant?source=qr');
  });
  test('outgoing partner navigation uses a path without a hash', () {
    expect(CompatiblePathUrlStrategy(Location()).prepareExternalUrl('/partenaire/token'), '/partenaire/token');
  });
}
