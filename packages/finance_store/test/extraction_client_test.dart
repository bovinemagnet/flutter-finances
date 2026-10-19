import 'dart:convert';

import 'package:finance_store/finance_store.dart';
import 'package:finance_store/src/sync/transport.dart' show SyncTransport;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late List<http.Request> requests;
  late ExtractionClient client;
  var hasResults = true;

  setUp(() {
    requests = [];
    hasResults = true;
    final http.Client mock = MockClient((request) async {
      requests.add(request);
      return switch ((request.method, request.url.path)) {
        ('GET', '/v1/workspaces/w1/extraction-consent') => http.Response(
          jsonEncode({
            'workspaceId': 'w1',
            'status': 'none',
            'available': true,
            'offeredProvider': 'Example OCR',
            'offeredRetention': 'Deleted within 24 hours',
          }),
          200,
        ),
        ('PUT', '/v1/workspaces/w1/extraction-consent') => http.Response(
          jsonEncode({
            'workspaceId': 'w1',
            'status': (jsonDecode(request.body) as Map)['granted'] == true
                ? 'granted'
                : 'withdrawn',
            'providerName': 'Example OCR',
            'disclosedRetention': 'Deleted within 24 hours',
            'available': true,
            'offeredProvider': 'Example OCR',
            'offeredRetention': 'Deleted within 24 hours',
          }),
          200,
        ),
        ('GET', '/v1/receipts/rc1/extraction') =>
          hasResults
              ? http.Response(
                  jsonEncode({
                    'receiptId': 'rc1',
                    'untrusted': true,
                    'results': [
                      {
                        'assetId': 'a1',
                        'provider': 'Example OCR',
                        'text': 'GROCER\nTOTAL 42.50',
                        'lines': ['GROCER', 'TOTAL 42.50'],
                        'extractedAt': '2026-10-19T00:00:00Z',
                      },
                    ],
                  }),
                  200,
                )
              : http.Response(
                  jsonEncode({'error': 'EXTRACTION_NOT_FOUND'}),
                  404,
                ),
        _ => http.Response('', 404),
      };
    });
    client = ExtractionClient(
      SyncTransport(
        client: mock,
        baseUri: Uri.parse('https://sync.test'),
        accessToken: () async => 'token',
      ),
    );
  });

  test('the consent view shows what is offered before consent', () async {
    final consent = await client.consent('w1');
    expect(consent.status, ExtractionConsentStatus.none);
    expect(consent.available, isTrue);
    expect(consent.offeredProvider, 'Example OCR');
    expect(consent.offeredRetention, 'Deleted within 24 hours');
  });

  test('granting repeats the offered provider and retention', () async {
    final offered = await client.consent('w1');
    final granted = await client.grant('w1', offered);
    expect(jsonDecode(requests.last.body), {
      'granted': true,
      'providerName': 'Example OCR',
      'disclosedRetention': 'Deleted within 24 hours',
    });
    expect(granted.status, ExtractionConsentStatus.granted);
    final withdrawn = await client.withdraw('w1');
    expect(jsonDecode(requests.last.body), {'granted': false});
    expect(withdrawn.status, ExtractionConsentStatus.withdrawn);
  });

  test('results are untrusted text; none is null', () async {
    final text = await client.extractedText('rc1');
    expect(text, 'GROCER\nTOTAL 42.50');
    hasResults = false;
    expect(await client.extractedText('rc1'), isNull);
  });
}
