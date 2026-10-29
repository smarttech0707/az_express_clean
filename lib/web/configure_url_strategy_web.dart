import 'package:flutter_web_plugins/url_strategy.dart';

String _hashOrEmpty(String? hash) => hash ?? '';

/// Accept previously shared /#/... links at startup, while new links use paths.
class CompatiblePathUrlStrategy extends PathUrlStrategy {
  final PlatformLocation location;
  CompatiblePathUrlStrategy([PlatformLocation? platform])
      : this.withLocation(platform ?? BrowserPlatformLocation());
  CompatiblePathUrlStrategy.withLocation(this.location) : super(location);

  @override
  String getPath() {
    final hash = _hashOrEmpty(location.hash);
    if ((location.pathname == '/' || location.pathname.isEmpty) &&
        hash.startsWith('#/')) {
      return hash.substring(1);
    }
    return super.getPath();
  }
}

void configureWebUrlStrategy() {
  setUrlStrategy(CompatiblePathUrlStrategy());
}
