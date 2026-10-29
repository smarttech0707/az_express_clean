/// Public identification links are deliberately not delivery credentials.
String? partnerQrToken(String value) {
  final uri=Uri.tryParse(value);
  if(uri==null||uri.scheme!='https'||uri.host!='az-express-b0469.web.app'||uri.hasPort||uri.userInfo.isNotEmpty||uri.hasQuery||uri.hasFragment){return null;}
  if(uri.pathSegments.length!=2||uri.pathSegments.first!='partenaire'){return null;}
  final token=uri.pathSegments[1];
  return RegExp(r'^[-a-zA-Z0-9]{20,80}$').hasMatch(token)?token:null;
}
