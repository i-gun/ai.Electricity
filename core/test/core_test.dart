import 'package:test/test.dart';
import 'package:ai_electricity_core/core.dart';

void main() {
  group('value objects', () {
    test('reject invalid kWh and preserves fixed precision', () {
      expect(() => Kwh(-1), throwsArgumentError);
      expect(Kwh(12.3456).value, 12.346);
    });

    test('money uses integer minor units', () {
      final money = Money.fromMajor(12.34, currencyCode: 'EUR');
      expect(money.minorUnits, 1234);
      expect(money + Money(66, currencyCode: 'EUR'),
          Money(1300, currencyCode: 'EUR'));
    });

    test('date ranges expose inclusive dates and presets', () {
      final range = DateRange(DateTime(2026, 1, 1), DateTime(2026, 1, 31));
      expect(range.contains(DateTime(2026, 1, 31)), isTrue);
      expect(DateRange.lastMonths(3, now: DateTime(2026, 4, 15)).end,
          DateTime(2026, 4, 15));
    });
  });

  test('calculates deltas and ignores reset transitions', () {
    final calculator = ConsumptionCalculator();
    final readings = [
      reading(1, 100, DateTime(2026, 1, 1)),
      reading(2, 112.5, DateTime(2026, 1, 2)),
      reading(3, 4, DateTime(2026, 1, 3), isReset: true),
      reading(4, 9, DateTime(2026, 1, 4)),
    ];
    expect(calculator.deltas(readings).map((delta) => delta.consumption.value),
        [12.5, 5]);
  });

  test('buckets consumption by zone with automatic granularity', () {
    final calculator = ConsumptionCalculator();
    final readings = [
      MeterReading(1, 'day', DateTime(2026, 1, 1), Kwh(100)),
      MeterReading(2, 'day', DateTime(2026, 1, 2), Kwh(110)),
      MeterReading(3, 'night', DateTime(2026, 1, 2), Kwh(40)),
      MeterReading(4, 'night', DateTime(2026, 1, 9), Kwh(45)),
    ];
    final range = DateRange(DateTime(2026, 1, 1), DateTime(2026, 1, 31));
    final buckets = calculator.bucketed(calculator.deltas(readings), range);

    expect(calculator.granularityFor(range), ConsumptionGranularity.day);
    expect(buckets, hasLength(2));
    expect(buckets[0].byZone['day'], Kwh(10));
    expect(buckets[0].byZone['night'], isNull);
    expect(
        calculator.granularityFor(
            DateRange(DateTime(2026, 1, 1), DateTime(2026, 7, 1))),
        ConsumptionGranularity.month);
  });

  test('expenses use the historical rate for each delta', () {
    final deltas = [
      ConsumptionDelta(
          DateTime(2026, 1, 1), DateTime(2026, 1, 3), Kwh(10), 'zone')
    ];
    final rates = [
      TariffRate(1, 'zone', Money(10), DateTime(2025, 1, 1),
          validTo: DateTime(2026, 1, 2)),
      TariffRate(2, 'zone', Money(20), DateTime(2026, 1, 2)),
    ];
    expect(ExpenseCalculator().calculate(deltas, rates).minorUnits, 150);
  });

  test('pairs deltas per zone when zones are interleaved by date', () {
    final calculator = ConsumptionCalculator();
    final readings = [
      MeterReading(1, 'day', DateTime(2026, 1, 1), Kwh(100)),
      MeterReading(2, 'night', DateTime(2026, 1, 1), Kwh(50)),
      MeterReading(3, 'day', DateTime(2026, 1, 2), Kwh(110)),
      MeterReading(4, 'night', DateTime(2026, 1, 2), Kwh(54)),
    ];
    final totals = calculator.totalsByZone(calculator.deltas(readings));
    expect(totals['day'], Kwh(10));
    expect(totals['night'], Kwh(4));
  });

  test('expenses split by zone', () {
    final deltas = [
      ConsumptionDelta(
          DateTime(2026, 1, 1), DateTime(2026, 1, 2), Kwh(10), 'day'),
      ConsumptionDelta(
          DateTime(2026, 1, 1), DateTime(2026, 1, 2), Kwh(4), 'night'),
    ];
    final rates = [
      TariffRate(1, 'day', Money(20), DateTime(2025, 1, 1)),
      TariffRate(2, 'night', Money(10), DateTime(2025, 1, 1)),
    ];
    final byZone = ExpenseCalculator().calculateByZone(deltas, rates);
    expect(byZone['day']?.minorUnits, 200);
    expect(byZone['night']?.minorUnits, 40);
  });

  test('copyWith preserves identity fields', () {
    final zone =
        TariffZone(1, ZoneCode('day'), 'Day', ZoneKind.day, isArchived: true);
    final enabled = zone.copyWith(isArchived: false);
    expect(enabled.id, 1);
    expect(enabled.code, zone.code);
    expect(enabled.kind, ZoneKind.day);
    expect(enabled.isArchived, isFalse);

    final rate = TariffRate(1, 'day', Money(20), DateTime(2026, 1, 1));
    expect(rate.copyWith(validTo: DateTime(2026, 2, 1)).validTo,
        DateTime(2026, 2, 1));

    final entry = MeterReading(0, 'day', DateTime(2026, 1, 1), Kwh(5));
    expect(entry.copyWith(id: 7).id, 7);
    expect(entry.copyWith(id: 7).zoneId, 'day');
  });

  test('validation returns explicit result types', () {
    final validation = ReadingValidator(DateTime(2026, 1, 2));
    expect(
        validation.validateFuture(DateTime(2026, 1, 3)), isA<FutureReading>());
    expect(validation.validateDuplicate(true), isA<DuplicateReading>());
    expect(validation.validateDecrease(3, 2, false), isA<DecreasingReading>());
    expect(
        RateValidator().overlaps([
          TariffRate(1, 'z', Money(1), DateTime(2026, 1, 1),
              validTo: DateTime(2026, 2, 1)),
          TariffRate(2, 'z', Money(1), DateTime(2026, 1, 15)),
        ]),
        isA<OverlappingRates>());
  });
}

MeterReading reading(int id, num value, DateTime date,
        {bool isReset = false}) =>
    MeterReading(id, 'zone', date, Kwh(value), isReset: isReset);
