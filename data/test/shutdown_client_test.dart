import 'dart:convert';

import 'package:ai_electricity_core/core.dart';
import 'package:ai_electricity_data/data.dart'
    show HttpShutdownScheduleRepository;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final endpoint = Uri.parse('http://127.0.0.1:47831/shutdowns');
  const location =
      Location(1, 'Home', city: 'Village', street: 'Main', building: '66');

  test('empty, partial and archived addresses never contact collector',
      () async {
    var requests = 0;
    final repository = HttpShutdownScheduleRepository(endpoint,
        client: MockClient((request) async {
      requests++;
      return http.Response('', 500);
    }));
    addTearDown(repository.close);
    for (final item in [
      const Location(1, 'Empty'),
      location.copyWith(city: ''),
      location.copyWith(street: ' '),
      location.copyWith(building: ''),
      location.copyWith(isArchived: true)
    ]) {
      expect(await repository.fetch(item), isNull);
    }
    expect(requests, 0);
  });

  test('posts a private address and parses dated half-hour intervals',
      () async {
    final repository = HttpShutdownScheduleRepository(endpoint,
        client: MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.hasQuery, isFalse);
      expect(jsonDecode(request.body), {
        'region': 'krem',
        'city': 'Village',
        'street': 'Main',
        'building': '66'
      });
      return http.Response(
          jsonEncode({
            'city': 'Village',
            'street': 'Main',
            'building': '66',
            'groups': ['GPV4.1'],
            'updatedAt': '22.10.2026 21:44',
            'fetchedAt': '2026-10-23T08:02:00Z',
            'currentOutage': null,
            'days': [
              {
                'date': '2026-10-23',
                'intervals': [
                  {'startMinute': 1290, 'endMinute': 1440}
                ]
              }
            ]
          }),
          200);
    }));
    addTearDown(repository.close);
    final result = (await repository.fetch(location))!;
    expect(result.city, 'Village');
    expect(result.region, ShutdownRegion.kyivRegion);
    expect(result.street, 'Main');
    expect(result.building, '66');
    expect(result.groups, ['GPV4.1']);
    expect(result.updatedAt, '22.10.2026 21:44');
    expect(result.fetchedAt.isUtc, isTrue);
    expect(result.currentOutage, isNull);
    expect(result.days.single.date, '2026-10-23');
    expect(result.days.single.intervals.single.startMinute, 1290);
    expect(result.days.single.intervals.single.endMinute, 1440);
  });

  test('Kyiv city is sent explicitly and wrong-region replies are rejected',
      () async {
    for (final responseRegion in ['kem', 'krem']) {
      final repository = HttpShutdownScheduleRepository(endpoint,
          client: MockClient((request) async {
        expect((jsonDecode(request.body) as Map)['region'], 'kem');
        return http.Response(
            jsonEncode({
              'region': responseRegion,
              'city': 'Kyiv',
              'street': 'Main',
              'building': '66',
              'groups': ['GPV1.1'],
              'updatedAt': '23.10.2026 12:00',
              'fetchedAt': '2026-10-23T09:00:00Z',
              'days': [
                {'date': '2026-10-23', 'intervals': []}
              ]
            }),
            200);
      }));
      addTearDown(repository.close);
      final request = repository.fetch(const Location(1, 'Kyiv',
          region: ShutdownRegion.kyivCity,
          city: 'Kyiv',
          street: 'Main',
          building: '66'));
      if (responseRegion == 'kem') {
        expect((await request)!.region, ShutdownRegion.kyivCity);
      } else {
        await expectLater(request, throwsA(isA<ShutdownException>()));
      }
    }
  });

  test('rejects unsafe remote HTTP and credentials', () {
    for (final url in [
      'http://example.com/shutdowns',
      'https://user:password@example.com/shutdowns'
    ]) {
      expect(() => HttpShutdownScheduleRepository(Uri.parse(url)),
          throwsArgumentError);
    }
  });

  test('failures are safe and missing data never means no outages', () async {
    for (final response in [
      http.Response('secret upstream HTML', 503),
      http.Response('{}', 200),
      http.Response('<html>challenge</html>', 200)
    ]) {
      final repository = HttpShutdownScheduleRepository(endpoint,
          client: MockClient((request) async => response));
      addTearDown(repository.close);
      await expectLater(
          repository.fetch(location), throwsA(isA<ShutdownException>()));
    }
  });
}
