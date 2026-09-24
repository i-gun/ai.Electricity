import 'dart:math' as math;

class Kwh {
  Kwh(num value) : value = _validatedValue(value);

  static double _validatedValue(num value) {
    if (value < 0 || value.isNaN || value.isInfinite) {
      throw ArgumentError.value(
          value, 'value', 'must be finite and non-negative');
    }
    return _round(value.toDouble());
  }

  final double value;

  static double _round(double value) => (value * 1000).round() / 1000;

  Kwh operator +(Kwh other) => Kwh(value + other.value);
  Kwh operator -(Kwh other) => Kwh(math.max(0, value - other.value));

  @override
  bool operator ==(Object other) => other is Kwh && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => '${value.toStringAsFixed(3)} kWh';
}

class Money {
  const Money(this.minorUnits, {this.currencyCode = 'EUR'})
      : assert(currencyCode.length == 3);

  factory Money.fromMajor(num amount, {String currencyCode = 'EUR'}) =>
      Money((amount * 100).round(), currencyCode: currencyCode);

  final int minorUnits;
  final String currencyCode;

  Money operator +(Money other) {
    _checkCurrency(other);
    return Money(minorUnits + other.minorUnits, currencyCode: currencyCode);
  }

  Money operator *(num factor) =>
      Money((minorUnits * factor).round(), currencyCode: currencyCode);

  void _checkCurrency(Money other) {
    if (currencyCode != other.currencyCode) {
      throw ArgumentError('Currency mismatch');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is Money &&
      other.minorUnits == minorUnits &&
      other.currencyCode == currencyCode;
  @override
  int get hashCode => Object.hash(minorUnits, currencyCode);
}

class ZoneCode {
  ZoneCode(String value) : value = value.trim().toLowerCase() {
    if (this.value.isEmpty || !RegExp(r'^[a-z0-9_-]+$').hasMatch(this.value)) {
      throw ArgumentError.value(value, 'value', 'must be a simple zone code');
    }
  }
  final String value;
  @override
  String toString() => value;
  @override
  bool operator ==(Object other) => other is ZoneCode && other.value == value;
  @override
  int get hashCode => value.hashCode;
}

class DateRange {
  DateRange(this.start, this.end) {
    if (end.isBefore(start)) throw ArgumentError('end must not precede start');
  }
  final DateTime start;
  final DateTime end;
  bool contains(DateTime date) => !date.isBefore(start) && !date.isAfter(end);
  int get days => end.difference(start).inDays + 1;
  factory DateRange.lastMonths(int months, {DateTime? now}) {
    final end = now ?? DateTime.now();
    return DateRange(DateTime(end.year, end.month - months, end.day), end);
  }
}

enum ZoneKind { total, day, night, custom }

/// A physical property/meter that owns one or more [TariffZone]s (ADR 0006).
class Location {
  const Location(this.id, this.name,
      {this.colorArgb = 0xff008577,
      this.sortOrder = 0,
      this.isArchived = false});
  final int id;
  final String name;
  final int colorArgb;
  final int sortOrder;
  final bool isArchived;

  Location copyWith(
          {String? name, int? colorArgb, int? sortOrder, bool? isArchived}) =>
      Location(id, name ?? this.name,
          colorArgb: colorArgb ?? this.colorArgb,
          sortOrder: sortOrder ?? this.sortOrder,
          isArchived: isArchived ?? this.isArchived);
}

class TariffZone {
  // locationId defaults to 1 (the default "Home" location seeded by the
  // schemaVersion-2 migration) so pre-ADR-0006 call sites keep working.
  const TariffZone(this.id, this.code, this.name, this.kind,
      {this.colorArgb = 0xff008577,
      this.sortOrder = 0,
      this.isArchived = false,
      this.locationId = 1});
  final int id;
  final ZoneCode code;
  final String name;
  final ZoneKind kind;
  final int colorArgb;
  final int sortOrder;
  final bool isArchived;
  final int locationId;

  TariffZone copyWith(
          {String? name,
          int? colorArgb,
          int? sortOrder,
          bool? isArchived,
          int? locationId}) =>
      TariffZone(id, code, name ?? this.name, kind,
          colorArgb: colorArgb ?? this.colorArgb,
          sortOrder: sortOrder ?? this.sortOrder,
          isArchived: isArchived ?? this.isArchived,
          locationId: locationId ?? this.locationId);
}

class TariffRate {
  const TariffRate(this.id, this.zoneId, this.pricePerKwh, this.validFrom,
      {this.validTo});
  final int id;
  final String zoneId;
  final Money pricePerKwh;
  final DateTime validFrom;
  final DateTime? validTo;
  bool contains(DateTime date) =>
      !date.isBefore(validFrom) && (validTo == null || date.isBefore(validTo!));

  TariffRate copyWith(
          {Money? pricePerKwh, DateTime? validFrom, DateTime? validTo}) =>
      TariffRate(id, zoneId, pricePerKwh ?? this.pricePerKwh,
          validFrom ?? this.validFrom,
          validTo: validTo ?? this.validTo);
}

class MeterReading {
  const MeterReading(this.id, this.zoneId, this.readingDate, this.valueKwh,
      {this.note, this.createdAt, this.updatedAt, this.isReset = false});
  final int id;
  final String zoneId;
  final DateTime readingDate;
  final Kwh valueKwh;
  final String? note;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final bool isReset;

  MeterReading copyWith(
          {int? id,
          String? zoneId,
          DateTime? readingDate,
          Kwh? valueKwh,
          String? note,
          DateTime? updatedAt,
          bool? isReset}) =>
      MeterReading(id ?? this.id, zoneId ?? this.zoneId,
          readingDate ?? this.readingDate, valueKwh ?? this.valueKwh,
          note: note ?? this.note,
          createdAt: createdAt,
          updatedAt: updatedAt ?? this.updatedAt,
          isReset: isReset ?? this.isReset);
}

abstract interface class MeterReadingRepository {
  Stream<List<MeterReading>> watchAll({String? zoneId});
  Future<MeterReading?> find(int id);
  Future<void> save(MeterReading reading);
  Future<void> delete(int id);
}

abstract interface class TariffZoneRepository {
  Stream<List<TariffZone>> watchAll({bool includeArchived = false});
  Future<void> save(TariffZone zone);
  Future<void> delete(int id);
}

abstract interface class TariffRateRepository {
  Stream<List<TariffRate>> watchAll();
  Stream<List<TariffRate>> watchForZone(String zoneId);
  Future<void> save(TariffRate rate);
  Future<void> delete(int id);
}

abstract interface class LocationRepository {
  Stream<List<Location>> watchAll({bool includeArchived = false});
  Future<void> save(Location location);
  Future<void> delete(int id);
}

class ConsumptionDelta {
  const ConsumptionDelta(this.from, this.to, this.consumption, this.zoneId);
  final DateTime from;
  final DateTime to;
  final Kwh consumption;
  final String zoneId;
}

enum ConsumptionGranularity { day, week, month }

class ConsumptionBucket {
  const ConsumptionBucket(this.start, this.byZone);
  final DateTime start;
  final Map<String, Kwh> byZone;

  Kwh get total => byZone.values.fold(Kwh(0), (sum, value) => sum + value);
}

class ConsumptionCalculator {
  /// Pairs are built per zone so interleaved multi-zone readings still match up.
  List<ConsumptionDelta> deltas(Iterable<MeterReading> source) {
    final byZone = <String, List<MeterReading>>{};
    for (final reading in source) {
      byZone.putIfAbsent(reading.zoneId, () => <MeterReading>[]).add(reading);
    }
    final result = <ConsumptionDelta>[];
    for (final readings in byZone.values) {
      readings.sort((a, b) => a.readingDate.compareTo(b.readingDate));
      for (var index = 1; index < readings.length; index++) {
        final previous = readings[index - 1];
        final current = readings[index];
        if (current.isReset) continue;
        if (current.valueKwh.value >= previous.valueKwh.value) {
          result.add(ConsumptionDelta(previous.readingDate, current.readingDate,
              current.valueKwh - previous.valueKwh, current.zoneId));
        }
      }
    }
    result.sort((a, b) => a.to.compareTo(b.to));
    return result;
  }

  Map<String, Kwh> totalsByZone(Iterable<ConsumptionDelta> deltas) {
    final totals = <String, Kwh>{};
    for (final delta in deltas) {
      totals[delta.zoneId] =
          (totals[delta.zoneId] ?? Kwh(0)) + delta.consumption;
    }
    return totals;
  }

  /// Sums every zone's consumption into its owning location; zones with no
  /// matching entry in [zones] (an unknown/removed zone code) are skipped.
  Map<int, Kwh> totalsByLocation(
      Iterable<ConsumptionDelta> deltas, Iterable<TariffZone> zones) {
    final locationOf = {
      for (final zone in zones) zone.code.value: zone.locationId
    };
    final totals = <int, Kwh>{};
    for (final entry in totalsByZone(deltas).entries) {
      final locationId = locationOf[entry.key];
      if (locationId == null) continue;
      totals[locationId] = (totals[locationId] ?? Kwh(0)) + entry.value;
    }
    return totals;
  }

  /// Groups deltas into stacked-chart buckets and selects a useful scale.
  List<ConsumptionBucket> bucketed(
      Iterable<ConsumptionDelta> source, DateRange range) {
    final deltas = source.where((delta) => range.contains(delta.to));
    final granularity = granularityFor(range);
    final buckets = <DateTime, Map<String, Kwh>>{};
    for (final delta in deltas) {
      final start = _bucketStart(delta.to, granularity);
      final values = buckets.putIfAbsent(start, () => <String, Kwh>{});
      values[delta.zoneId] =
          (values[delta.zoneId] ?? Kwh(0)) + delta.consumption;
    }
    final starts = buckets.keys.toList()..sort();
    return [
      for (final start in starts)
        ConsumptionBucket(start, Map.unmodifiable(buckets[start]!)),
    ];
  }

  ConsumptionGranularity granularityFor(DateRange range) => range.days <= 31
      ? ConsumptionGranularity.day
      : range.days <= 180
          ? ConsumptionGranularity.week
          : ConsumptionGranularity.month;

  DateTime _bucketStart(DateTime date, ConsumptionGranularity granularity) {
    final local = DateTime(date.year, date.month, date.day);
    switch (granularity) {
      case ConsumptionGranularity.day:
        return local;
      case ConsumptionGranularity.week:
        return local.subtract(Duration(days: local.weekday - DateTime.monday));
      case ConsumptionGranularity.month:
        return DateTime(local.year, local.month);
    }
  }
}

class ExpenseCalculator {
  Money calculate(Iterable<ConsumptionDelta> deltas, Iterable<TariffRate> rates,
      {String currencyCode = 'EUR'}) {
    var total = Money(0, currencyCode: currencyCode);
    for (final delta in deltas) {
      // Rates recorded in a different currency than requested can't be summed
      // without a conversion rate, so they're excluded rather than crashing.
      final matching = rates
          .where((rate) =>
              rate.zoneId == delta.zoneId &&
              rate.pricePerKwh.currencyCode == currencyCode)
          .toList();
      final duration = math.max(1, delta.to.difference(delta.from).inDays);
      for (var day = 0; day < duration; day++) {
        final date = delta.from.add(Duration(days: day));
        final rate =
            matching.where((candidate) => candidate.contains(date)).firstOrNull;
        if (rate != null) {
          total += rate.pricePerKwh * (delta.consumption.value / duration);
        }
      }
    }
    return total;
  }

  Map<String, Money> calculateByZone(
      Iterable<ConsumptionDelta> deltas, Iterable<TariffRate> rates,
      {String currencyCode = 'EUR'}) {
    final grouped = <String, List<ConsumptionDelta>>{};
    for (final delta in deltas) {
      grouped.putIfAbsent(delta.zoneId, () => <ConsumptionDelta>[]).add(delta);
    }
    return {
      for (final entry in grouped.entries)
        entry.key: calculate(entry.value, rates, currencyCode: currencyCode),
    };
  }

  /// Sums each zone's expense into its owning location. `Money.+` already
  /// throws on a currency mismatch, so mixed-currency locations surface as a
  /// hard error rather than a silently wrong total (ADR 0006 Decision 5).
  Map<int, Money> calculateByLocation(Iterable<ConsumptionDelta> deltas,
      Iterable<TariffRate> rates, Iterable<TariffZone> zones,
      {String currencyCode = 'EUR'}) {
    final locationOf = {
      for (final zone in zones) zone.code.value: zone.locationId
    };
    final totals = <int, Money>{};
    for (final entry
        in calculateByZone(deltas, rates, currencyCode: currencyCode).entries) {
      final locationId = locationOf[entry.key];
      if (locationId == null) continue;
      totals[locationId] =
          (totals[locationId] ?? Money(0, currencyCode: currencyCode)) +
              entry.value;
    }
    return totals;
  }
}

class ReconciliationWarning {
  const ReconciliationWarning(this.total, this.components, this.difference);
  final Kwh total;
  final Kwh components;
  final Kwh difference;
}

class ZoneReconciliation {
  ReconciliationWarning? compare(Kwh total, Iterable<Kwh> components,
      {Kwh? tolerance}) {
    final allowedDifference = tolerance ?? Kwh(0.1);
    final sum = components.fold(Kwh(0), (value, item) => value + item);
    final difference = (total.value - sum.value).abs();
    return difference > allowedDifference.value
        ? ReconciliationWarning(total, sum, Kwh(difference))
        : null;
  }
}

sealed class ValidationResult {
  const ValidationResult(this.message);
  final String message;
}

class Valid extends ValidationResult {
  const Valid() : super('valid');
}

class DuplicateReading extends ValidationResult {
  const DuplicateReading()
      : super('a reading already exists for this zone and date');
}

class DecreasingReading extends ValidationResult {
  const DecreasingReading()
      : super('reading is lower than the previous reading');
}

class FutureReading extends ValidationResult {
  const FutureReading() : super('reading date cannot be in the future');
}

class OverlappingRates extends ValidationResult {
  const OverlappingRates() : super('tariff rate windows overlap');
}

class ReadingValidator {
  const ReadingValidator(this.today);
  final DateTime today;
  ValidationResult validateDuplicate(bool duplicate) =>
      duplicate ? const DuplicateReading() : const Valid();
  ValidationResult validateDecrease(num previous, num next, bool isReset) =>
      next < previous && !isReset ? const DecreasingReading() : const Valid();
  ValidationResult validateFuture(DateTime date) =>
      date.isAfter(today) ? const FutureReading() : const Valid();
}

class RateValidator {
  ValidationResult overlaps(Iterable<TariffRate> rates) {
    final grouped = <String, List<TariffRate>>{};
    for (final rate in rates) {
      grouped.putIfAbsent(rate.zoneId, () => []).add(rate);
    }
    for (final group in grouped.values) {
      group.sort((a, b) => a.validFrom.compareTo(b.validFrom));
      for (var i = 1; i < group.length; i++) {
        final previousEnd = group[i - 1].validTo;
        if (previousEnd == null || group[i].validFrom.isBefore(previousEnd)) {
          return const OverlappingRates();
        }
      }
    }
    return const Valid();
  }
}
