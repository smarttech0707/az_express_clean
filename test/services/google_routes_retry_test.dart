import 'dart:io';

import 'package:az_express/services/google_routes_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _SequenceClient extends http.BaseClient {
  _SequenceClient(this._responses);

  final List<Object> _responses;
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = _responses[calls++];
    if (response is Exception) throw response;
    return http.StreamedResponse(
      Stream.value((response as String).codeUnits),
      200,
    );
  }
}

void main() {
  final uri = Uri.parse('https://example.test/directions');

  test('réessaie une fois après une erreur réseau transitoire', () async {
    final client = _SequenceClient([const SocketException('offline'), 'ok']);

    final response = await getDirectionsWithTransientRetry(
      uri,
      client: client,
      retryDelay: Duration.zero,
    );

    expect(response.statusCode, 200);
    expect(client.calls, 2);
  });

  test("ne réessaie pas lorsqu'une réponse HTTP est reçue", () async {
    final client = _StatusClient(500);

    final response = await getDirectionsWithTransientRetry(
      uri,
      client: client,
      retryDelay: Duration.zero,
    );

    expect(response.statusCode, 500);
    expect(client.calls, 1);
  });
}

class _StatusClient extends http.BaseClient {
  _StatusClient(this.statusCode);

  final int statusCode;
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    return http.StreamedResponse(const Stream.empty(), statusCode);
  }
}
