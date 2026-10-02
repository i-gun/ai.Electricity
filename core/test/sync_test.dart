import 'package:ai_electricity_core/core.dart';
import 'package:test/test.dart';

SyncReading reading(String id, double value,
        {String locationId = 'home',
        String zoneId = 'total',
        DateTime? date,
        String? note,
        bool isReset = false}) =>
    SyncReading(
        id: id,
        locationId: locationId,
        zoneId: zoneId,
        readingDate: date ?? DateTime(2026, 9, 29),
        valueKwh: Kwh(value),
        note: note,
        isReset: isReset);

void main() {
  final merger = ReadingMerger();

  test('distinct dates, zones and locations are safely united', () {
    final first = reading('a', 100);
    final second = reading('b', 105, date: DateTime(2026, 9, 30));
    final third = reading('c', 50, zoneId: 'night');
    final fourth = reading('d', 70, locationId: 'apartment');
    final result = merger.merge([first, third], [fourth, second]);
    expect(result.readings.map((item) => item.id), ['a', 'b', 'c', 'd']);
    expect(result.conflicts, isEmpty);
  });

  test('replayed identical record is deduplicated', () {
    final first = reading('a', 100);
    final result = merger.merge([first, first], [reading('a', 100)]);
    expect(result.readings, hasLength(1));
    expect(result.conflicts, isEmpty);
  });

  test('same date with divergent readings retains both candidates', () {
    final first = reading('a', 100);
    final second = reading('b', 105);
    final result = merger.merge([first], [second]);
    expect(result.readings, isEmpty);
    expect(result.conflicts.single.candidates, [first, second]);
    final reversed = merger.merge([second], [first]);
    expect(reversed.conflicts.single.candidates, [first, second]);
  });

  test('same id with changed date remains a conflict', () {
    final first = reading('a', 100);
    final moved = reading('a', 100, date: DateTime(2026, 9, 30));
    final result = merger.merge([first], [moved]);
    expect(result.readings, isEmpty);
    expect(result.conflicts.single.candidates, [first, moved]);
  });

  test('conflict groups also join through a shared identity', () {
    final original = reading('a', 100);
    final independent = reading('b', 105, date: DateTime(2026, 9, 30));
    final moved = reading('a', 110, date: DateTime(2026, 9, 30));
    final result = merger.merge([original, independent], [moved]);
    expect(result.conflicts, hasLength(1));
    expect(result.conflicts.single.candidates, hasLength(3));
  });

  test('a bridging edit combines two otherwise separate conflicts', () {
    final first = reading('a', 100);
    final second = reading('b', 105, date: DateTime(2026, 9, 30));
    final bridgeStart = reading('c', 110);
    final bridgeEnd = reading('c', 115, date: DateTime(2026, 9, 30));
    final result = merger.merge([first, second], [bridgeStart, bridgeEnd]);
    expect(result.readings, isEmpty);
    expect(result.conflicts.single.candidates,
        unorderedEquals([first, second, bridgeStart, bridgeEnd]));
  });

  test('note and meter reset changes cannot be silently discarded', () {
    final original = reading('a', 100);
    final revised = reading('a', 100, note: 'corrected', isReset: true);
    final result = merger.merge([original], [revised]);
    expect(result.conflicts.single.candidates, [original, revised]);
    expect(original.sameContent(revised), isFalse);
    expect(original.sameContent(reading('z', 100)), isTrue);
    expect(original.sameContent(reading('z', 100, zoneId: 'night')), isFalse);
    expect(
        original.sameContent(reading('z', 100, locationId: 'flat')), isFalse);
    expect(original.sameContent(reading('z', 100, date: DateTime(2026, 9, 30))),
        isFalse);
    expect(original.sameContent(reading('z', 101)), isFalse);
    expect(original.sameContent(reading('z', 100, note: 'x')), isFalse);
    expect(original.sameContent(reading('z', 100, isReset: true)), isFalse);
  });

  test('rejects missing identities and time-of-day values', () {
    expect(() => reading('', 100), throwsArgumentError);
    expect(() => reading('a', 100, locationId: ''), throwsArgumentError);
    expect(() => reading('a', 100, zoneId: ''), throwsArgumentError);
    for (final date in [
      DateTime(2026, 9, 29, 1),
      DateTime(2026, 9, 29, 0, 1),
      DateTime(2026, 9, 29, 0, 0, 1),
      DateTime(2026, 9, 29, 0, 0, 0, 1),
      DateTime(2026, 9, 29, 0, 0, 0, 0, 1),
    ]) {
      expect(() => reading('a', 100, date: date), throwsArgumentError);
    }
    expect(reading('a', 100).dateKey, '2026-9-29');
  });
}
