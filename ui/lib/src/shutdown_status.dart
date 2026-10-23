import 'package:ai_electricity_core/core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'shutdown_indicator.dart';

class ShutdownStatusView extends StatefulWidget {
  const ShutdownStatusView(
      {super.key, this.location, this.repository, this.controller});
  final Location? location;
  final ShutdownScheduleRepository? repository;
  final ShutdownStatusController? controller;

  @override
  State<ShutdownStatusView> createState() => _ShutdownStatusViewState();
}

class _ShutdownStatusViewState extends State<ShutdownStatusView> {
  late ShutdownStatusController _controller;
  bool get loading => _controller.loading;
  ShutdownSchedule? get schedule => _controller.schedule;
  String? get error => _controller.error;
  String? selectedDate;
  final timelineScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _attachController();
  }

  void _attachController() {
    _controller = widget.controller ?? ShutdownStatusController();
    _controller.configure(widget.location, widget.repository);
    _controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    if (widget.controller == null) _controller.dispose();
    timelineScroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ShutdownStatusView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _controller.removeListener(_changed);
      if (oldWidget.controller == null) _controller.dispose();
      _attachController();
    } else {
      _controller.configure(widget.location, widget.repository);
    }
  }

  Future<void> _load() => _controller.refresh();

  String _time(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final location = widget.location;
    final result = schedule;
    final selectedDay =
        result?.days.where((day) => day.date == selectedDate).firstOrNull ??
            result?.days.firstOrNull;
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
              if (selectedDay != null) ...[
                const Divider(height: 24),
                if (result.days.length > 1) ...[
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<String>(
                      segments: [
                        for (final day in result.days)
                          ButtonSegment(
                              value: day.date,
                              label: Text(
                                  DateFormat('EEE, dd MMM')
                                      .format(DateTime.parse(day.date)),
                                  key: ValueKey('shutdown-day-${day.date}'))),
                      ],
                      selected: {selectedDay.date},
                      onSelectionChanged: (dates) =>
                          setState(() => selectedDate = dates.single),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                Text(selectedDay.date,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                _ShutdownTimeline(day: selectedDay, controller: timelineScroll),
                const SizedBox(height: 16),
                const _ShutdownLegend(),
                const SizedBox(height: 20),
                Text('Planned outages',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                if (selectedDay.intervals.isEmpty)
                  const Text('No planned outages published for this date.'),
                Wrap(spacing: 24, runSpacing: 8, children: [
                  for (final interval in selectedDay.intervals)
                    Text(
                        '${_time(interval.startMinute)} - ${_time(interval.endMinute)}',
                        style: Theme.of(context).textTheme.bodyLarge),
                ]),
              ],
            ],
          ]),
    );
  }
}

class _ShutdownTimeline extends StatelessWidget {
  const _ShutdownTimeline({required this.day, required this.controller});
  final ShutdownDay day;
  final ScrollController controller;

  bool _unavailable(int start) => day.intervals.any((interval) =>
      interval.startMinute < start + 30 && interval.endMinute > start);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      const labelWidth = 104.0;
      final hourWidth = ((constraints.maxWidth - labelWidth) / 24)
          .clamp(36.0, double.infinity);
      final width = labelWidth + hourWidth * 24;
      return Scrollbar(
        controller: controller,
        thumbVisibility: width > constraints.maxWidth,
        child: SingleChildScrollView(
          key: const ValueKey('shutdown-timeline-scroll'),
          controller: controller,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(bottom: 12),
          child: SizedBox(
              width: width,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Table(
                  border: TableBorder.all(color: scheme.outlineVariant),
                  columnWidths: {
                    0: const FixedColumnWidth(labelWidth),
                    for (var hour = 0; hour < 24; hour++)
                      hour + 1: FixedColumnWidth(hourWidth)
                  },
                  children: [
                    TableRow(
                        decoration:
                            BoxDecoration(color: scheme.surfaceContainerLow),
                        children: [
                          SizedBox(
                              height: 80,
                              child: Center(
                                  child: Text('Hours',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge))),
                          for (var hour = 0; hour < 24; hour++)
                            SizedBox(
                                height: 80,
                                child: Center(
                                    child: RotatedBox(
                                        quarterTurns: 1,
                                        child: Text(
                                            '${hour.toString().padLeft(2, '0')}-${(hour + 1).toString().padLeft(2, '0')}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelLarge)))),
                        ]),
                    TableRow(children: [
                      SizedBox(
                          height: 48,
                          child: Center(
                              child: Text('Planned\noutages',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelMedium))),
                      for (var hour = 0; hour < 24; hour++)
                        _ShutdownHourCell(
                            hour: hour,
                            first: _unavailable(hour * 60),
                            second: _unavailable(hour * 60 + 30)),
                    ]),
                  ],
                ),
              )),
        ),
      );
    });
  }
}

class _ShutdownHourCell extends StatelessWidget {
  const _ShutdownHourCell(
      {this.hour, required this.first, required this.second});
  final int? hour;
  final bool first;
  final bool second;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = first && second
        ? 'Outage for the full hour'
        : first
            ? 'Outage in first 30 minutes'
            : second
                ? 'Outage in last 30 minutes'
                : 'No planned outage';
    final description = hour == null
        ? state
        : '${hour.toString().padLeft(2, '0')}:00 - ${(hour! + 1).toString().padLeft(2, '0')}:00: $state';
    return Semantics(
      label: description,
      excludeSemantics: true,
      child: Tooltip(
          message: description,
          child: SizedBox(
            height: 48,
            child: Stack(children: [
              Positioned.fill(
                  child: Row(children: [
                for (var half = 0; half < 2; half++)
                  Expanded(
                      child: ColoredBox(
                    key: hour == null
                        ? null
                        : ValueKey('shutdown-half-$hour-$half'),
                    color: (half == 0 ? first : second)
                        ? scheme.errorContainer
                        : scheme.surfaceContainerLowest,
                    child: Center(
                        child: first != second && (half == 0 ? first : second)
                            ? Icon(Icons.flash_off,
                                size: 16, color: scheme.onErrorContainer)
                            : const SizedBox.shrink()),
                  )),
              ])),
              if (first && second)
                Center(
                    child: Icon(Icons.flash_off,
                        size: 20, color: scheme.onErrorContainer)),
            ]),
          )),
    );
  }
}

class _ShutdownLegend extends StatelessWidget {
  const _ShutdownLegend();

  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 24, runSpacing: 12, children: [
        for (final entry in const [
          (false, false, 'No planned outage'),
          (true, true, 'Outage'),
          (true, false, 'First 30 min'),
          (false, true, 'Last 30 min'),
        ])
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 36,
                height: 32,
                decoration: BoxDecoration(
                    border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant)),
                child: _ShutdownHourCell(first: entry.$1, second: entry.$2)),
            const SizedBox(width: 8),
            Text(entry.$3, style: Theme.of(context).textTheme.bodySmall),
          ]),
      ]);
}
