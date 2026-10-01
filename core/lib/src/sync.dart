import 'domain.dart';

/// A reading identified independently of device-local database row IDs.
class SyncReading {
  SyncReading({
    required this.id,
    required this.locationId,
    required this.zoneId,
    required this.readingDate,
    required this.valueKwh,
    this.note,
    this.isReset = false,
  }) {
    if (id.isEmpty || locationId.isEmpty || zoneId.isEmpty) {
      throw ArgumentError('Sync identities must not be empty');
    }
    if (readingDate.hour != 0 ||
        readingDate.minute != 0 ||
        readingDate.second != 0 ||
        readingDate.millisecond != 0 ||
        readingDate.microsecond != 0) {
      throw ArgumentError.value(readingDate, 'readingDate', 'must be a date');
    }
  }

  final String id;
  final String locationId;
  final String zoneId;
  final DateTime readingDate;
  final Kwh valueKwh;
  final String? note;
  final bool isReset;

  String get dateKey =>
      '${readingDate.year}-${readingDate.month}-${readingDate.day}';

  bool sameContent(SyncReading other) =>
      locationId == other.locationId &&
      zoneId == other.zoneId &&
      dateKey == other.dateKey &&
      valueKwh == other.valueKwh &&
      note == other.note &&
      isReset == other.isReset;
}

/// Candidate readings that cannot be merged without an explicit decision.
class ReadingConflict {
  const ReadingConflict(this.candidates);

  final List<SyncReading> candidates;
}

/// Safe readings and unresolved conflicts from an order-independent union.
class ReadingMergeResult {
  const ReadingMergeResult(this.readings, this.conflicts);

  final List<SyncReading> readings;
  final List<ReadingConflict> conflicts;
}

/// Merges reading snapshots without choosing a winner for conflicting values.
class ReadingMerger {
  ReadingMergeResult merge(
      Iterable<SyncReading> local, Iterable<SyncReading> remote) {
    final candidates = [...local, ...remote]
      ..sort((first, second) => first.id.compareTo(second.id));
    final groups = <List<SyncReading>>[];
    for (final candidate in candidates) {
      final matching = <List<SyncReading>>[];
      for (final group in groups) {
        if (group.any((existing) =>
            existing.id == candidate.id ||
            (existing.locationId == candidate.locationId &&
                existing.zoneId == candidate.zoneId &&
                existing.dateKey == candidate.dateKey))) {
          matching.add(group);
        }
      }
      if (matching.isEmpty) {
        groups.add([candidate]);
      } else {
        final combined = matching.first;
        combined.add(candidate);
        for (final group in matching.skip(1)) {
          combined.addAll(group);
          groups.remove(group);
        }
      }
    }

    final readings = <SyncReading>[];
    final conflicts = <ReadingConflict>[];
    for (final group in groups) {
      final distinct = <SyncReading>[];
      for (final candidate in group) {
        if (!distinct.any((existing) =>
            existing.id == candidate.id && existing.sameContent(candidate))) {
          distinct.add(candidate);
        }
      }
      if (distinct.length == 1) {
        readings.add(distinct.single);
      } else {
        conflicts.add(ReadingConflict(distinct));
      }
    }
    return ReadingMergeResult(readings, conflicts);
  }
}
