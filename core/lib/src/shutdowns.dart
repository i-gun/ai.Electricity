import 'domain.dart';

/// A planned outage interval in Europe/Kyiv wall-clock minutes from midnight.
class ShutdownInterval {
  const ShutdownInterval(this.startMinute, this.endMinute);
  final int startMinute;
  final int endMinute;
}

/// Published intervals for one Kyiv calendar date, not an inferred power state.
class ShutdownDay {
  const ShutdownDay(this.date, this.intervals);
  final String date;
  final List<ShutdownInterval> intervals;
}

/// Latest successfully collected DTEK data for one resolved address.
class ShutdownSchedule {
  const ShutdownSchedule(
      {required this.city,
      this.region = ShutdownRegion.kyivRegion,
      required this.street,
      required this.building,
      required this.groups,
      required this.updatedAt,
      required this.fetchedAt,
      required this.days,
      this.currentOutage});
  final String city;
  final ShutdownRegion region;
  final String street;
  final String building;
  final List<String> groups;
  final String updatedAt;
  final DateTime fetchedAt;
  final List<ShutdownDay> days;
  final String? currentOutage;
}

/// Incomplete addresses must return null without contacting a collector.
abstract interface class ShutdownScheduleRepository {
  Future<ShutdownSchedule?> fetch(Location location);
}

/// Safe displayable failure; never contains cookies, tokens, or upstream HTML.
class ShutdownException implements Exception {
  const ShutdownException(this.message);
  final String message;
}
