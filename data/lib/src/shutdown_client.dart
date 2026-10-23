import 'dart:async';
import 'dart:convert';

import 'package:ai_electricity_core/core.dart';
import 'package:http/http.dart' as http;

class HttpShutdownScheduleRepository implements ShutdownScheduleRepository {
  HttpShutdownScheduleRepository(this.endpoint, {http.Client? client})
      : _client = client ?? http.Client() {
    final loopback = ['127.0.0.1', 'localhost', '::1'].contains(endpoint.host);
    if ((!loopback && endpoint.scheme != 'https') ||
        !['https', 'http'].contains(endpoint.scheme) ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment) {
      throw ArgumentError('Collector must use HTTPS or loopback HTTP.');
    }
  }

  final Uri endpoint;
  final http.Client _client;

  void close() => _client.close();

  @override
  Future<ShutdownSchedule?> fetch(Location location) async {
    if (!location.hasShutdownAddress || location.isArchived) return null;
    try {
      final response = await _client
          .post(endpoint,
              headers: {
                'Content-Type': 'application/json',
                'Accept': 'application/json'
              },
              body: jsonEncode({
                'region': location.region.code,
                'city': location.city.trim(),
                'street': location.street.trim(),
                'building': location.building.trim()
              }))
          .timeout(const Duration(seconds: 100));
      if (response.statusCode != 200) {
        throw const ShutdownException(
            'Shutdown collector unavailable. Check the collector and retry.');
      }
      final json =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if ((json['region'] ?? 'krem') != location.region.code) {
        throw const FormatException('Collector returned the wrong region');
      }
      final days = (json['days'] as List).map((value) {
        final day = value as Map<String, dynamic>;
        final date = day['date'] as String;
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
          throw const FormatException('Invalid schedule date');
        }
        final intervals = (day['intervals'] as List).map((entry) {
          final interval = entry as Map<String, dynamic>;
          final start = interval['startMinute'] as int;
          final end = interval['endMinute'] as int;
          if (start < 0 || end > 1440 || start >= end) {
            throw const FormatException('Invalid interval');
          }
          return ShutdownInterval(start, end);
        }).toList();
        return ShutdownDay(date, intervals);
      }).toList();
      final groups = (json['groups'] as List).cast<String>();
      if (days.isEmpty || groups.isEmpty) {
        throw const FormatException('Missing schedule');
      }
      return ShutdownSchedule(
          region: location.region,
          city: json['city'] as String,
          street: json['street'] as String,
          building: json['building'] as String,
          groups: groups,
          updatedAt: json['updatedAt'] as String,
          fetchedAt: DateTime.parse(json['fetchedAt'] as String),
          days: days,
          currentOutage: json['currentOutage'] as String?);
    } on ShutdownException {
      rethrow;
    } on TimeoutException {
      throw const ShutdownException(
          'Shutdown lookup timed out. Retry after checking the collector browser.');
    } on Exception {
      throw const ShutdownException(
          'Could not read shutdown data. Check the collector and retry.');
    } on TypeError {
      throw const ShutdownException(
          'The shutdown collector returned invalid data.');
    }
  }
}
