import 'dart:async';

import 'package:ai_electricity_core/core.dart';
import 'package:flutter/material.dart';
import 'package:timezone/data/latest.dart' as zone_data;
import 'package:timezone/timezone.dart' as zones;

enum StatusBulbState { available, outage, unknown }

class ShutdownStatusController extends ChangeNotifier {
  ShutdownStatusController({DateTime Function()? now})
      : _now = now ?? DateTime.now;

  static final _kyiv = () {
    zone_data.initializeTimeZones();
    return zones.getLocation('Europe/Kyiv');
  }();

  final DateTime Function() _now;
  Location? _location;
  ShutdownScheduleRepository? _repository;
  ShutdownSchedule? schedule;
  String? error;
  bool loading = false;
  bool _disposed = false;
  int _version = 0;
  Timer? _timer;

  Object _addressKey(Location? location) => (
        location?.id,
        location?.region,
        location?.city,
        location?.street,
        location?.building,
        location?.isArchived
      );

  bool get _enabled =>
      _location != null &&
      !_location!.isArchived &&
      _location!.hasShutdownAddress &&
      _repository != null;

  void configure(Location? location, ShutdownScheduleRepository? repository) {
    if (_addressKey(location) == _addressKey(_location) &&
        repository == _repository) {
      return;
    }
    _location = location;
    _repository = repository;
    final version = ++_version;
    _reset();
    scheduleMicrotask(() {
      if (_disposed || version != _version) return;
      notifyListeners();
      unawaited(_fetch(version));
    });
  }

  void _reset() {
    _timer?.cancel();
    _timer = null;
    schedule = null;
    error = null;
    loading = _enabled;
  }

  Future<void> refresh() {
    final version = ++_version;
    _reset();
    notifyListeners();
    return _fetch(version);
  }

  Future<void> _fetch(int version) async {
    if (!_enabled) return;
    try {
      final result = await _repository!.fetch(_location!);
      if (_disposed || version != _version) return;
      schedule = result;
      if (result == null) {
        error = 'Shutdown schedule unavailable.';
      } else {
        _timer = Timer.periodic(const Duration(seconds: 30), (_) {
          notifyListeners();
          if (bulbState == StatusBulbState.unknown) {
            _timer?.cancel();
            _timer = null;
          }
        });
      }
    } catch (failure) {
      if (_disposed || version != _version) return;
      error = failure is ShutdownException
          ? failure.message
          : 'Shutdown schedule unavailable. Try again.';
    } finally {
      if (!_disposed && version == _version) {
        loading = false;
        notifyListeners();
      }
    }
  }

  StatusBulbState get bulbState {
    final result = schedule;
    if (!_enabled || loading || result == null) return StatusBulbState.unknown;
    final now = _now().toUtc();
    final age = now.difference(result.fetchedAt.toUtc());
    if (age.isNegative || age >= const Duration(minutes: 5)) {
      return StatusBulbState.unknown;
    }
    if (result.currentOutage?.trim().isNotEmpty ?? false) {
      return StatusBulbState.outage;
    }
    final kyiv = zones.TZDateTime.from(now, _kyiv);
    final date =
        '${kyiv.year.toString().padLeft(4, '0')}-${kyiv.month.toString().padLeft(2, '0')}-${kyiv.day.toString().padLeft(2, '0')}';
    final day = result.days.where((day) => day.date == date).firstOrNull;
    if (day == null) return StatusBulbState.unknown;
    final minute = kyiv.hour * 60 + kyiv.minute;
    return day.intervals.any((interval) =>
            minute >= interval.startMinute && minute < interval.endMinute)
        ? StatusBulbState.outage
        : StatusBulbState.available;
  }

  String get bulbDescription => switch (bulbState) {
        StatusBulbState.available =>
          'Status: no outage scheduled now (Europe/Kyiv). Not a live power measurement.',
        StatusBulbState.outage =>
          (schedule?.currentOutage?.trim().isNotEmpty ?? false)
              ? 'Status: outage reported by DTEK.'
              : 'Status: scheduled outage now (Europe/Kyiv).',
        StatusBulbState.unknown => loading
            ? 'Status: checking outage schedule.'
            : 'Status: outage status unavailable or outdated.',
      };

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

class ShutdownStatusBulb extends StatelessWidget {
  const ShutdownStatusBulb({super.key, required this.controller});
  final ShutdownStatusController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final state = controller.bulbState;
          final description = controller.bulbDescription;
          return Tooltip(
              message: description,
              child: Semantics(
                label: description,
                excludeSemantics: true,
                child: SizedBox(
                    width: 24,
                    height: 24,
                    child: Stack(children: [
                      Icon(
                          state == StatusBulbState.available
                              ? Icons.lightbulb
                              : Icons.lightbulb_outline,
                          key: ValueKey('status-bulb-${state.name}'),
                          size: 24,
                          color: state == StatusBulbState.available
                              ? Theme.of(context).colorScheme.primary
                              : null),
                      if (state == StatusBulbState.unknown)
                        Positioned(
                            right: 0,
                            bottom: 0,
                            child: ColoredBox(
                                color: Theme.of(context).colorScheme.surface,
                                child: Icon(Icons.help_outline,
                                    size: 11,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant))),
                    ])),
              ));
        },
      );
}
