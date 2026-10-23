import 'package:ai_electricity_core/core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class ShutdownStatusView extends StatefulWidget {
  const ShutdownStatusView({super.key, this.location, this.repository});
  final Location? location;
  final ShutdownScheduleRepository? repository;

  @override
  State<ShutdownStatusView> createState() => _ShutdownStatusViewState();
}

class _ShutdownStatusViewState extends State<ShutdownStatusView> {
  bool loading = false;
  ShutdownSchedule? schedule;
  String? error;
  int requestVersion = 0;

  Object _addressKey(Location? location) => (
        location?.id,
        location?.region,
        location?.city,
        location?.street,
        location?.building,
        location?.isArchived
      );

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ShutdownStatusView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_addressKey(oldWidget.location) != _addressKey(widget.location) ||
        oldWidget.repository != widget.repository) {
      _load();
    }
  }

  Future<void> _load() async {
    final version = ++requestVersion;
    final location = widget.location;
    final repository = widget.repository;
    final enabled = location != null &&
        !location.isArchived &&
        location.hasShutdownAddress &&
        repository != null;
    setState(() {
      loading = enabled;
      schedule = null;
      error = null;
    });
    if (!enabled) return;
    try {
      final result = await repository.fetch(location);
      if (mounted && version == requestVersion) {
        setState(() {
          schedule = result;
          if (result == null) error = 'Shutdown schedule unavailable.';
        });
      }
    } catch (failure) {
      if (mounted && version == requestVersion) {
        setState(() => error = failure is ShutdownException
            ? failure.message
            : 'Shutdown schedule unavailable. Try again.');
      }
    } finally {
      if (mounted && version == requestVersion) setState(() => loading = false);
    }
  }

  String _time(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final location = widget.location;
    final result = schedule;
    final enabled = location != null &&
        !location.isArchived &&
        location.hasShutdownAddress &&
        widget.repository != null;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                  child: Text(location?.name ?? 'Status',
                      style: Theme.of(context).textTheme.headlineSmall)),
              IconButton(
                  tooltip: 'Refresh schedule',
                  onPressed: loading || !enabled ? null : _load,
                  icon: const Icon(Icons.refresh)),
            ]),
            const SizedBox(height: 12),
            if (location == null || location.isArchived)
              const Text('No active location.')
            else ...[
              Text(location.region.label),
              if (!location.hasShutdownAddress)
                const Text('Address incomplete.')
              else if (widget.repository == null)
                const Text('Shutdown collector is not configured.'),
            ],
            if (loading) const Center(child: CircularProgressIndicator()),
            if (error != null)
              Text(error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (result != null) ...[
              Text('${result.city}, ${result.street}, ${result.building}'),
              const SizedBox(height: 8),
              Text('Group: ${result.groups.join(', ')}'),
              Text('DTEK updated: ${result.updatedAt}'),
              Text(
                  'Fetched: ${DateFormat('yyyy-MM-dd HH:mm').format(result.fetchedAt.toLocal())}'),
              const Text('Schedule time zone: Europe/Kyiv'),
              if (result.groups.length > 1)
                const Text('Intervals cover any listed group.'),
              if (result.currentOutage != null)
                Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(result.currentOutage!)),
              for (final day in result.days) ...[
                const Divider(height: 24),
                Text(day.date, style: Theme.of(context).textTheme.titleMedium),
                if (day.intervals.isEmpty)
                  const Text('No planned outages published for this date.'),
                for (final interval in day.intervals)
                  Text(
                      '${_time(interval.startMinute)} - ${_time(interval.endMinute)}'),
              ],
            ],
          ]),
    );
  }
}
