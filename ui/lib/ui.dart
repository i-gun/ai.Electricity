library;

import 'package:ai_electricity_core/core.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

ThemeData lightTheme() => ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    useMaterial3: true);
ThemeData darkTheme() => ThemeData(
    colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.teal, brightness: Brightness.dark),
    useMaterial3: true);

class SharedHome extends StatefulWidget {
  const SharedHome(
      {super.key,
      this.compact = false,
      this.readingRepository,
      this.zoneRepository,
      this.rateRepository,
      this.locationRepository});
  final bool compact;
  final MeterReadingRepository? readingRepository;
  final TariffZoneRepository? zoneRepository;
  final TariffRateRepository? rateRepository;
  final LocationRepository? locationRepository;
  @override
  State<SharedHome> createState() => _SharedHomeState();
}

/// Mirrors the seed migration in `data/` so the widget also works without a database.
List<TariffZone> _seedZones() => [
      TariffZone(1, ZoneCode('total'), 'Total', ZoneKind.total,
          colorArgb: 0xff008577),
      TariffZone(2, ZoneCode('day'), 'Day', ZoneKind.day,
          colorArgb: 0xfff4b400, sortOrder: 1, isArchived: true),
      TariffZone(3, ZoneCode('night'), 'Night', ZoneKind.night,
          colorArgb: 0xff4285f4, sortOrder: 2, isArchived: true),
    ];

/// Mirrors the schemaVersion-2 seed migration in `data/`.
List<Location> _seedLocations() => [const Location(1, 'Home')];

class _SharedHomeState extends State<SharedHome> {
  int tab = 0;
  final readings = <MeterReading>[];
  final zones = _seedZones();
  final locations = _seedLocations();
  final rates = <TariffRate>[
    TariffRate(1, 'total', Money(25), DateTime(2000, 1, 1)),
  ];
  DateRange range = DateRange.lastMonths(3);
  String rangeKey = '3M';
  String currencyCode = 'EUR';

  List<TariffZone> get activeZones =>
      zones.where((zone) => !zone.isArchived).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  @override
  void initState() {
    super.initState();
    widget.readingRepository?.watchAll().listen((items) {
      if (!mounted) return;
      setState(() {
        readings
          ..clear()
          ..addAll(items);
      });
    });
    widget.zoneRepository?.watchAll(includeArchived: true).listen((items) {
      if (!mounted) return;
      setState(() {
        zones
          ..clear()
          ..addAll(items);
      });
    });
    widget.rateRepository?.watchAll().listen((items) {
      if (!mounted) return;
      setState(() {
        rates
          ..clear()
          ..addAll(items);
        // Keep the display currency aligned with stored rates so restarts
        // don't fall back to the 'EUR' default and crash expense totals.
        if (items.isNotEmpty) {
          currencyCode = items.first.pricePerKwh.currencyCode;
        }
      });
    });
    widget.locationRepository?.watchAll(includeArchived: true).listen((items) {
      if (!mounted) return;
      setState(() {
        locations
          ..clear()
          ..addAll(items);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      ReadingsView(
          readings: readings,
          zones: zones,
          onAdd: _addReading,
          onEdit: _editReading,
          onDelete: _deleteReading),
      ZonesView(
          zones: zones,
          rates: rates,
          currencyCode: currencyCode,
          onCurrencyChanged: (code) => setState(() => currencyCode = code),
          onToggleZone: _toggleZone,
          onAddZone: _addZone,
          onEditZone: _editZone,
          onDeleteZone: _deleteZone,
          onAddRate: _addRate,
          onEditRate: _editRate,
          onDeleteRate: _deleteRate),
      StatsView(
          readings: readings,
          rates: rates,
          zones: zones,
          locations: locations,
          range: range,
          rangeKey: rangeKey,
          currencyCode: currencyCode,
          onRangeChanged: (r, key) => setState(() {
                range = r;
                rangeKey = key;
              })),
      LocationsView(
          locations: locations,
          zones: zones,
          onToggleLocation: _toggleLocation,
          onAddLocation: _addLocation,
          onEditLocation: _editLocation,
          onDeleteLocation: _deleteLocation),
    ];
    return Scaffold(
        appBar: AppBar(title: const Text('ai.Electricity')),
        body: widget.compact
            ? pages[tab]
            : Row(children: [
                NavigationRail(
                    selectedIndex: tab,
                    onDestinationSelected: (v) => setState(() => tab = v),
                    labelType: NavigationRailLabelType.all,
                    destinations: const [
                      NavigationRailDestination(
                          icon: Icon(Icons.speed_outlined),
                          label: Text('Readings')),
                      NavigationRailDestination(
                          icon: Icon(Icons.tune),
                          label: Text('Zones & tariffs')),
                      NavigationRailDestination(
                          icon: Icon(Icons.insights_outlined),
                          label: Text('Stats')),
                      NavigationRailDestination(
                          icon: Icon(Icons.home_work_outlined),
                          label: Text('Locations'))
                    ]),
                const VerticalDivider(width: 1),
                Expanded(child: pages[tab])
              ]),
        bottomNavigationBar: widget.compact
            ? NavigationBar(
                selectedIndex: tab,
                onDestinationSelected: (v) => setState(() => tab = v),
                destinations: const [
                    NavigationDestination(
                        icon: Icon(Icons.speed_outlined), label: 'Readings'),
                    NavigationDestination(
                        icon: Icon(Icons.tune), label: 'Zones'),
                    NavigationDestination(
                        icon: Icon(Icons.insights_outlined), label: 'Stats'),
                    NavigationDestination(
                        icon: Icon(Icons.home_work_outlined),
                        label: 'Locations')
                  ])
            : null,
        floatingActionButton: widget.compact && tab == 0
            ? FloatingActionButton(
                onPressed: _addReading, child: const Icon(Icons.add))
            : null);
  }

  Future<void> _addReading() async {
    final available = activeZones;
    if (available.isEmpty) {
      _notify('Enable at least one zone on the Zones tab first.');
      return;
    }
    final batch = await showDialog<List<MeterReading>>(
        context: context,
        builder: (_) => _ReadingDialog(zones: available, readings: readings));
    if (batch == null) return;
    await _saveReadings(batch);
  }

  Future<void> _editReading(MeterReading original) async {
    final available = activeZones.isEmpty ? zones : activeZones;
    final batch = await showDialog<List<MeterReading>>(
        context: context,
        builder: (_) => _ReadingDialog(
            zones: available, readings: readings, initial: original));
    if (batch == null) return;
    await _saveReading(batch.single);
  }

  Future<void> _saveReadings(List<MeterReading> batch) async {
    var nextId = _nextId(readings.map((item) => item.id));
    for (final reading in batch) {
      await _saveReading(widget.readingRepository == null
          ? reading.copyWith(id: nextId++)
          : reading);
    }
  }

  Future<void> _saveReading(MeterReading reading) async {
    final repository = widget.readingRepository;
    if (repository == null) {
      setState(() {
        final index = readings.indexWhere((item) => item.id == reading.id);
        if (index >= 0) {
          readings[index] = reading;
        } else {
          readings.add(reading);
        }
      });
      return;
    }
    try {
      await repository.save(reading);
    } on Exception {
      _notify('A reading already exists for that zone and date.');
    }
  }

  Future<void> _deleteReading(MeterReading reading) async {
    final confirmed = await _confirm('Delete reading?',
        '${reading.valueKwh.value.toStringAsFixed(3)} kWh on ${_formatDate(context, reading.readingDate)} will be removed.');
    if (!confirmed) return;
    final repository = widget.readingRepository;
    if (repository == null) {
      setState(() => readings.remove(reading));
    } else {
      await repository.delete(reading.id);
    }
    _notifyUndo('Reading deleted', () => _saveReading(reading));
  }

  Future<void> _toggleZone(TariffZone zone) =>
      _saveZone(zone.copyWith(isArchived: !zone.isArchived));

  Future<void> _addZone() async {
    final zone = await showDialog<TariffZone>(
        context: context,
        builder: (_) => _ZoneDialog(existing: zones, locations: locations));
    if (zone == null) return;
    await _saveZone(widget.zoneRepository == null
        ? TariffZone(_nextId(zones.map((item) => item.id)), zone.code,
            zone.name, zone.kind,
            colorArgb: zone.colorArgb,
            sortOrder: zone.sortOrder,
            locationId: zone.locationId)
        : zone);
  }

  Future<void> _editZone(TariffZone zone) async {
    final updated = await showDialog<TariffZone>(
        context: context,
        builder: (_) =>
            _ZoneDialog(existing: zones, locations: locations, initial: zone));
    if (updated == null) return;
    await _saveZone(updated);
  }

  Future<void> _saveZone(TariffZone zone) async {
    final repository = widget.zoneRepository;
    if (repository == null) {
      setState(() {
        final index = zones.indexWhere((item) => item.id == zone.id);
        if (index >= 0) {
          zones[index] = zone;
        } else {
          zones.add(zone);
        }
      });
      return;
    }
    await repository.save(zone);
  }

  Future<void> _deleteZone(TariffZone zone) async {
    if (zone.kind == ZoneKind.total) {
      _notify('Total is the reconciliation baseline and cannot be deleted.');
      return;
    }
    if (readings.any((item) => item.zoneId == zone.code.value)) {
      _notify('${zone.name} still has readings — archive it instead.');
      return;
    }
    final confirmed = await _confirm('Delete ${zone.name}?',
        'The zone and its tariff rate history will be removed.');
    if (!confirmed) return;
    final repository = widget.zoneRepository;
    final zoneRates =
        rates.where((item) => item.zoneId == zone.code.value).toList();
    if (repository == null) {
      setState(() {
        rates.removeWhere((item) => item.zoneId == zone.code.value);
        zones.remove(zone);
      });
    } else {
      for (final rate in zoneRates) {
        await widget.rateRepository?.delete(rate.id);
      }
      await repository.delete(zone.id);
    }
    _notifyUndo('Zone deleted', () async {
      await _saveZone(zone);
      if (widget.rateRepository == null) {
        setState(() => rates.addAll(zoneRates));
      } else {
        for (final rate in zoneRates) {
          await widget.rateRepository!.save(rate);
        }
      }
    });
  }

  Future<void> _toggleLocation(Location location) =>
      _saveLocation(location.copyWith(isArchived: !location.isArchived));

  Future<void> _addLocation() async {
    final location = await showDialog<Location>(
        context: context, builder: (_) => const _LocationDialog());
    if (location == null) return;
    await _saveLocation(widget.locationRepository == null
        ? Location(_nextId(locations.map((item) => item.id)), location.name,
            colorArgb: location.colorArgb, sortOrder: location.sortOrder)
        : location);
  }

  Future<void> _editLocation(Location location) async {
    final updated = await showDialog<Location>(
        context: context, builder: (_) => _LocationDialog(initial: location));
    if (updated == null) return;
    await _saveLocation(updated);
  }

  Future<void> _saveLocation(Location location) async {
    final repository = widget.locationRepository;
    if (repository == null) {
      setState(() {
        final index = locations.indexWhere((item) => item.id == location.id);
        if (index >= 0) {
          locations[index] = location;
        } else {
          locations.add(location);
        }
      });
      return;
    }
    await repository.save(location);
  }

  Future<void> _deleteLocation(Location location) async {
    if (zones.any((zone) => zone.locationId == location.id)) {
      _notify('${location.name} still has zones — archive it instead.');
      return;
    }
    final confirmed = await _confirm(
        'Delete ${location.name}?', 'The location will be removed.');
    if (!confirmed) return;
    final repository = widget.locationRepository;
    if (repository == null) {
      setState(() => locations.remove(location));
    } else {
      await repository.delete(location.id);
    }
    _notifyUndo('Location deleted', () => _saveLocation(location));
  }

  Future<void> _addRate(TariffZone zone) async {
    final rate = await showDialog<TariffRate>(
        context: context,
        builder: (_) => _RateDialog(zone: zone, currencyCode: currencyCode));
    if (rate == null) return;
    final zoneRates =
        rates.where((item) => item.zoneId == zone.code.value).toList();
    // A new window closes the open-ended one it supersedes, preserving history.
    final superseded = <int, TariffRate>{
      for (final existing in zoneRates)
        if (existing.validTo == null &&
            existing.validFrom.isBefore(rate.validFrom))
          existing.id: existing.copyWith(validTo: rate.validFrom)
    };
    final projected = <TariffRate>[
      for (final existing in zoneRates) superseded[existing.id] ?? existing,
      rate,
    ];
    if (RateValidator().overlaps(projected) is! Valid) {
      _notify('That rate window overlaps an existing one.');
      return;
    }
    final repository = widget.rateRepository;
    if (repository == null) {
      setState(() {
        for (final entry in superseded.entries) {
          rates[rates.indexWhere((item) => item.id == entry.key)] = entry.value;
        }
        rates.add(TariffRate(_nextId(rates.map((item) => item.id)), rate.zoneId,
            rate.pricePerKwh, rate.validFrom,
            validTo: rate.validTo));
      });
      return;
    }
    for (final entry in superseded.values) {
      await repository.save(entry);
    }
    await repository.save(rate);
  }

  Future<void> _editRate(TariffRate rate) async {
    final zone = _zoneFor(zones, rate.zoneId);
    if (zone == null) return;
    final updated = await showDialog<TariffRate>(
        context: context,
        builder: (_) =>
            _RateDialog(zone: zone, currencyCode: currencyCode, initial: rate));
    if (updated == null) return;
    final projected = [
      ...rates
          .where((item) => item.id != rate.id && item.zoneId == rate.zoneId),
      updated,
    ];
    if (RateValidator().overlaps(projected) is! Valid) {
      _notify('That rate window overlaps an existing one.');
      return;
    }
    await _saveRate(updated);
  }

  Future<void> _deleteRate(TariffRate rate) async {
    final confirmed = await _confirm('Delete tariff rate?',
        '${_money(context, rate.pricePerKwh)} per kWh from ${_formatDate(context, rate.validFrom)} will be removed.');
    if (!confirmed) return;
    final repository = widget.rateRepository;
    if (repository == null) {
      setState(() => rates.remove(rate));
    } else {
      await repository.delete(rate.id);
    }
    _notifyUndo('Tariff rate deleted', () => _saveRate(rate));
  }

  Future<void> _saveRate(TariffRate rate) async {
    if (widget.rateRepository == null) {
      setState(() {
        final index = rates.indexWhere((item) => item.id == rate.id);
        if (index >= 0) {
          rates[index] = rate;
        } else {
          rates.add(rate);
        }
      });
    } else {
      await widget.rateRepository!.save(rate);
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // Clear any bar still showing so a new one doesn't queue behind it.
    messenger.clearSnackBars();
    messenger.showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 4)));
  }

  void _notifyUndo(String message, Future<void> Function() undo) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // Clear any bar still showing so a new one doesn't queue behind it.
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              messenger.hideCurrentSnackBar();
              undo();
            })));
  }

  Future<bool> _confirm(String title, String message) async {
    final result = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: Text(title),
              content: Text(message),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('Delete')),
              ],
            ));
    return result ?? false;
  }
}

int _nextId(Iterable<int> ids) =>
    ids.fold(0, (maximum, id) => id > maximum ? id : maximum) + 1;

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String _formatDate(BuildContext context, DateTime value) =>
    DateFormat.yMMMd(Localizations.localeOf(context).toString())
        .format(value.toLocal());

class ReadingsView extends StatelessWidget {
  const ReadingsView(
      {super.key,
      required this.readings,
      required this.zones,
      required this.onAdd,
      required this.onEdit,
      required this.onDelete});
  final List<MeterReading> readings;
  final List<TariffZone> zones;
  final VoidCallback onAdd;
  final ValueChanged<MeterReading> onEdit;
  final ValueChanged<MeterReading> onDelete;
  @override
  Widget build(BuildContext context) {
    final groupedReadings = _readingsByZone(readings);
    final readingZones = _readingZones(zones, groupedReadings.keys);
    return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(
              alignment: WrapAlignment.spaceBetween,
              runSpacing: 12,
              children: [
                Text('Meter readings',
                    style: Theme.of(context).textTheme.headlineSmall),
                FilledButton.icon(
                    onPressed: onAdd,
                    icon: const Icon(Icons.add),
                    label: const Text('Add reading'))
              ]),
          const SizedBox(height: 16),
          Expanded(
              child: readings.isEmpty
                  ? const _EmptyState(
                      icon: Icons.speed_outlined,
                      title: 'No readings yet',
                      message:
                          'Add the first cumulative meter value to start tracking.')
                  : SingleChildScrollView(
                      child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final zone in readingZones) ...[
                                  _ReadingZoneTable(
                                      zoneName: zone.name,
                                      zoneColor: Color(zone.colorArgb),
                                      readings:
                                          groupedReadings[zone.code.value]!,
                                      onEdit: onEdit,
                                      onDelete: onDelete),
                                  if (zone != readingZones.last)
                                    const SizedBox(width: 16),
                                ]
                              ]))))
        ]));
  }
}

Map<String, List<MeterReading>> _readingsByZone(List<MeterReading> readings) {
  final grouped = <String, List<MeterReading>>{};
  for (final reading in readings) {
    grouped.putIfAbsent(reading.zoneId, () => []).add(reading);
  }
  for (final zoneReadings in grouped.values) {
    zoneReadings.sort((a, b) => b.readingDate.compareTo(a.readingDate));
  }
  return grouped;
}

List<TariffZone> _readingZones(
    List<TariffZone> zones, Iterable<String> zoneIds) {
  final zoneIdSet = zoneIds.toSet();
  final knownZones = zones
      .where((zone) => zoneIdSet.contains(zone.code.value))
      .toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  final knownZoneIds = knownZones.map((zone) => zone.code.value).toSet();
  return [
    ...knownZones,
    for (final zoneId in zoneIdSet.where((id) => !knownZoneIds.contains(id)))
      TariffZone(0, ZoneCode(zoneId), zoneId, ZoneKind.custom),
  ];
}

class _ReadingZoneTable extends StatelessWidget {
  const _ReadingZoneTable(
      {required this.zoneName,
      required this.zoneColor,
      required this.readings,
      required this.onEdit,
      required this.onDelete});

  final String zoneName;
  final Color zoneColor;
  final List<MeterReading> readings;
  final ValueChanged<MeterReading> onEdit;
  final ValueChanged<MeterReading> onDelete;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 360),
      child: Card(
          child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      CircleAvatar(backgroundColor: zoneColor, radius: 6),
                      const SizedBox(width: 8),
                      Text(zoneName,
                          style: Theme.of(context).textTheme.titleMedium),
                    ]),
                    const SizedBox(height: 8),
                    DataTable(columns: const [
                      DataColumn(label: Text('Date')),
                      DataColumn(label: Text('Reading')),
                      DataColumn(label: Text('Label')),
                      DataColumn(label: Text('Actions')),
                    ], rows: [
                      for (final reading in readings)
                        DataRow(cells: [
                          DataCell(
                              Text(_formatDate(context, reading.readingDate))),
                          DataCell(Text(
                              '${reading.valueKwh.value.toStringAsFixed(3)} kWh')),
                          DataCell(Text([
                            if (reading.note != null &&
                                reading.note!.isNotEmpty)
                              reading.note!,
                            if (reading.isReset) 'meter reset',
                          ].join(' • '))),
                          DataCell(Wrap(children: [
                            IconButton(
                                tooltip: 'Edit reading',
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () => onEdit(reading)),
                            IconButton(
                                tooltip: 'Delete reading',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => onDelete(reading)),
                          ])),
                        ]),
                    ]),
                  ]))));
}

TariffZone? _zoneFor(List<TariffZone> zones, String zoneId) {
  for (final zone in zones) {
    if (zone.code.value == zoneId) return zone;
  }
  return null;
}

class ZonesView extends StatelessWidget {
  const ZonesView(
      {super.key,
      required this.zones,
      required this.rates,
      required this.currencyCode,
      required this.onCurrencyChanged,
      required this.onToggleZone,
      required this.onAddZone,
      required this.onEditZone,
      required this.onDeleteZone,
      required this.onAddRate,
      required this.onEditRate,
      required this.onDeleteRate});
  final List<TariffZone> zones;
  final List<TariffRate> rates;
  final String currencyCode;
  final ValueChanged<String> onCurrencyChanged;
  final ValueChanged<TariffZone> onToggleZone;
  final VoidCallback onAddZone;
  final ValueChanged<TariffZone> onEditZone;
  final ValueChanged<TariffZone> onDeleteZone;
  final ValueChanged<TariffZone> onAddRate;
  final ValueChanged<TariffRate> onEditRate;
  final ValueChanged<TariffRate> onDeleteRate;

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
            alignment: WrapAlignment.spaceBetween,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Zones & tariffs',
                  style: Theme.of(context).textTheme.headlineSmall),
              Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _CurrencyPicker(
                        currencyCode: currencyCode,
                        onChanged: onCurrencyChanged),
                    FilledButton.icon(
                        onPressed: onAddZone,
                        icon: const Icon(Icons.add),
                        label: const Text('New zone'))
                  ])
            ]),
        const SizedBox(height: 8),
        Text('Switch a zone on to record readings and tariffs against it.',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 16),
        Expanded(
            child: ListView(children: [
          for (final zone in zones)
            Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: _ZoneTile(
                    zone: zone,
                    rates: rates
                        .where((rate) => rate.zoneId == zone.code.value)
                        .toList(),
                    onToggle: () => onToggleZone(zone),
                    onEdit: () => onEditZone(zone),
                    onDelete: () => onDeleteZone(zone),
                    onAddRate: () => onAddRate(zone),
                    onEditRate: onEditRate,
                    onDeleteRate: onDeleteRate)),
        ]))
      ]));
}

class _ZoneTile extends StatelessWidget {
  const _ZoneTile(
      {required this.zone,
      required this.rates,
      required this.onToggle,
      required this.onEdit,
      required this.onDelete,
      required this.onAddRate,
      required this.onEditRate,
      required this.onDeleteRate});
  final TariffZone zone;
  final List<TariffRate> rates;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onAddRate;
  final ValueChanged<TariffRate> onEditRate;
  final ValueChanged<TariffRate> onDeleteRate;

  @override
  Widget build(BuildContext context) {
    final sorted = [...rates]
      ..sort((a, b) => b.validFrom.compareTo(a.validFrom));
    return ExpansionTile(
      leading: CircleAvatar(
          backgroundColor: Color(zone.colorArgb),
          child: Text(zone.name.isEmpty ? '?' : zone.name[0].toUpperCase(),
              style: const TextStyle(color: Colors.white))),
      title: Text(zone.name),
      subtitle: Text(
          '${zone.isArchived ? 'Archived' : 'Active'} • ${sorted.length} rate window${sorted.length == 1 ? '' : 's'}'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Semantics(
            label: '${zone.name} active',
            child:
                Switch(value: !zone.isArchived, onChanged: (_) => onToggle())),
        IconButton(
            tooltip: 'Edit zone',
            icon: const Icon(Icons.edit_outlined),
            onPressed: onEdit),
        IconButton(
            tooltip: 'Delete zone',
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete),
      ]),
      children: [
        if (sorted.isEmpty)
          const ListTile(
              dense: true, title: Text('No tariff rates for this zone yet.')),
        for (final rate in sorted)
          ListTile(
              dense: true,
              leading: const Icon(Icons.sell_outlined),
              title: Text('${_money(context, rate.pricePerKwh)} per kWh'),
              subtitle: Text(
                  '${_formatDate(context, rate.validFrom)} → ${rate.validTo == null ? 'open' : _formatDate(context, rate.validTo!)}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                    tooltip: 'Edit rate',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => onEditRate(rate)),
                IconButton(
                    tooltip: 'Delete rate',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => onDeleteRate(rate)),
              ])),
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                    onPressed: onAddRate,
                    icon: const Icon(Icons.add),
                    label: const Text('Add tariff rate')))),
      ],
    );
  }
}

class LocationsView extends StatelessWidget {
  const LocationsView(
      {super.key,
      required this.locations,
      required this.zones,
      required this.onToggleLocation,
      required this.onAddLocation,
      required this.onEditLocation,
      required this.onDeleteLocation});
  final List<Location> locations;
  final List<TariffZone> zones;
  final ValueChanged<Location> onToggleLocation;
  final VoidCallback onAddLocation;
  final ValueChanged<Location> onEditLocation;
  final ValueChanged<Location> onDeleteLocation;

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
            alignment: WrapAlignment.spaceBetween,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Locations',
                  style: Theme.of(context).textTheme.headlineSmall),
              FilledButton.icon(
                  onPressed: onAddLocation,
                  icon: const Icon(Icons.add),
                  label: const Text('New location'))
            ]),
        const SizedBox(height: 8),
        Text(
            'Track more than one property/meter; each owns its own zones and tariffs.',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 16),
        Expanded(
            child: ListView(children: [
          for (final location in locations)
            Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                    leading: CircleAvatar(
                        backgroundColor: Color(location.colorArgb),
                        child: Text(
                            location.name.isEmpty
                                ? '?'
                                : location.name[0].toUpperCase(),
                            style: const TextStyle(color: Colors.white))),
                    title: Text(location.name),
                    subtitle: Text(
                        '${location.isArchived ? 'Archived' : 'Active'} • ${zones.where((zone) => zone.locationId == location.id).length} zone(s)'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Semantics(
                          label: '${location.name} active',
                          child: Switch(
                              value: !location.isArchived,
                              onChanged: (_) => onToggleLocation(location))),
                      IconButton(
                          tooltip: 'Edit location',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => onEditLocation(location)),
                      IconButton(
                          tooltip: 'Delete location',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => onDeleteLocation(location)),
                    ]))),
        ]))
      ]));
}

class StatsView extends StatefulWidget {
  const StatsView(
      {super.key,
      required this.readings,
      required this.rates,
      required this.zones,
      this.locations = const [],
      required this.range,
      required this.rangeKey,
      required this.currencyCode,
      required this.onRangeChanged});
  final List<MeterReading> readings;
  final List<TariffRate> rates;
  final List<TariffZone> zones;
  final List<Location> locations;
  final DateRange range;
  final String rangeKey;
  final String currencyCode;
  final void Function(DateRange range, String key) onRangeChanged;
  @override
  State<StatsView> createState() => _StatsViewState();
}

class _StatsViewState extends State<StatsView> {
  bool combined = false;

  @override
  Widget build(BuildContext context) {
    final readings = widget.readings;
    final rates = widget.rates;
    final zones = widget.zones;
    final locations = widget.locations;
    final range = widget.range;
    final rangeKey = widget.rangeKey;
    final currencyCode = widget.currencyCode;
    final onRangeChanged = widget.onRangeChanged;
    final calculator = ConsumptionCalculator();
    final consumption = calculator
        .deltas(readings)
        .where((delta) => range.contains(delta.to))
        .toList();
    final total =
        consumption.fold(0.0, (sum, delta) => sum + delta.consumption.value);
    final consumptionByZone = calculator.totalsByZone(consumption);
    final deltasByZone = <String, List<ConsumptionDelta>>{};
    for (final delta in consumption) {
      deltasByZone
          .putIfAbsent(delta.zoneId, () => <ConsumptionDelta>[])
          .add(delta);
    }
    final expenseByZone = ExpenseCalculator()
        .calculateByZone(consumption, rates, currencyCode: currencyCode);
    final granularity = calculator.granularityFor(range);
    final buckets = calculator.bucketed(calculator.deltas(readings), range);
    final averageDaily = range.days == 0 ? 0 : total / range.days;
    final dayKwh = consumptionByZone.entries
        .where((entry) => _zoneFor(zones, entry.key)?.kind == ZoneKind.day)
        .fold(0.0, (sum, entry) => sum + entry.value.value);
    final nightKwh = consumptionByZone.entries
        .where((entry) => _zoneFor(zones, entry.key)?.kind == ZoneKind.night)
        .fold(0.0, (sum, entry) => sum + entry.value.value);
    final dayNightTotal = dayKwh + nightKwh;
    final dayShare = dayNightTotal == 0 ? 0 : dayKwh / dayNightTotal;
    final chartZones = _chartZones(zones, consumptionByZone.keys);
    final warning = _reconcile(zones, consumptionByZone);
    final activeLocations = locations.where((l) => !l.isArchived).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    // The scope switch only appears once a second location exists, so a
    // single-location install keeps today's Stats tab visually unchanged.
    final showLocationScope = locations.length > 1;
    final showCombined = showLocationScope && combined;
    final excludedLocations = showCombined
        ? activeLocations
            .where((location) =>
                !_locationHasCurrency(location.id, zones, rates, currencyCode))
            .toList()
        : const <Location>[];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Stats', style: Theme.of(context).textTheme.headlineSmall),
          const Spacer(),
          DropdownButton<String>(
            value: rangeKey,
            items: const [
              DropdownMenuItem(value: '1M', child: Text('1 month')),
              DropdownMenuItem(value: '3M', child: Text('3 months')),
              DropdownMenuItem(value: '6M', child: Text('6 months')),
              DropdownMenuItem(value: '1Y', child: Text('1 year')),
              DropdownMenuItem(value: 'custom', child: Text('Custom range')),
            ],
            onChanged: (value) async {
              if (value != null) {
                if (value == 'custom') {
                  final picked = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now(),
                      initialDateRange:
                          DateTimeRange(start: range.start, end: range.end));
                  if (picked != null) {
                    onRangeChanged(
                        DateRange(picked.start, picked.end), 'custom');
                  }
                } else {
                  final amount =
                      int.parse(value.substring(0, value.length - 1));
                  final unit = value.substring(value.length - 1);
                  final months = unit == 'Y' ? amount * 12 : amount;
                  onRangeChanged(DateRange.lastMonths(months), value);
                }
              }
            },
          ),
        ]),
        if (showLocationScope) ...[
          const SizedBox(height: 12),
          SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Per zone')),
                ButtonSegment(
                    value: true, label: Text('Combined (all locations)')),
              ],
              selected: {
                combined
              },
              onSelectionChanged: (selection) =>
                  setState(() => combined = selection.first)),
        ],
        const SizedBox(height: 16),
        Wrap(spacing: 12, children: [
          _SummaryTile(
              label: 'Total consumption',
              value: '${total.toStringAsFixed(1)} kWh'),
          _SummaryTile(
              label: 'Total cost',
              value: _money(
                  context,
                  ExpenseCalculator().calculate(consumption, rates,
                      currencyCode: currencyCode))),
          _SummaryTile(
              label: 'Average daily consumption',
              value: '${averageDaily.toStringAsFixed(1)} kWh'),
          _SummaryTile(
              label: 'Day / night share',
              value: dayNightTotal == 0
                  ? 'n/a'
                  : '${(dayShare * 100).round()}% / ${(100 - dayShare * 100).round()}%'),
          _SummaryTile(label: 'Range', value: '${range.days} days'),
        ]),
        if (warning != null) ...[
          const SizedBox(height: 16),
          Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                  leading: const Icon(Icons.warning_amber_outlined),
                  title: const Text('Zone totals do not reconcile'),
                  subtitle: Text(
                      'Day + night is ${warning.components.value.toStringAsFixed(3)} kWh against a total of '
                      '${warning.total.value.toStringAsFixed(3)} kWh (difference ${warning.difference.value.toStringAsFixed(3)} kWh).'))),
        ],
        const SizedBox(height: 24),
        if (consumption.isEmpty)
          const _EmptyState(
              icon: Icons.bar_chart,
              title: 'Charts will appear here',
              message: 'Add at least two readings to calculate consumption.')
        else if (showCombined) ...[
          LayoutBuilder(builder: (context, constraints) {
            final consumptionDonut = _LocationDonut(
                title: 'Consumption by location',
                semanticsLabel: 'Consumption by location donut chart',
                locations: activeLocations,
                valueOf: (location) =>
                    _locationConsumption(location.id, zones, consumptionByZone)
                        .value,
                labelOf: (location) =>
                    '${_locationConsumption(location.id, zones, consumptionByZone).value.toStringAsFixed(1)} kWh');
            final expenseDonut = _LocationDonut(
                title: 'Expenses by location',
                semanticsLabel: 'Expenses by location donut chart',
                locations: activeLocations
                    .where((location) => !excludedLocations.contains(location))
                    .toList(),
                valueOf: (location) => _locationExpense(
                        location.id, zones, expenseByZone, currencyCode)
                    .minorUnits
                    .toDouble(),
                labelOf: (location) => _money(
                    context,
                    _locationExpense(
                        location.id, zones, expenseByZone, currencyCode)));
            if (constraints.maxWidth < 600) {
              return Column(children: [consumptionDonut, expenseDonut]);
            }
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: consumptionDonut),
              const SizedBox(width: 16),
              Expanded(child: expenseDonut),
            ]);
          }),
          if (excludedLocations.isNotEmpty)
            Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                    '${excludedLocations.map((location) => location.name).join(', ')} '
                    '${excludedLocations.length == 1 ? 'uses' : 'use'} a different currency and '
                    '${excludedLocations.length == 1 ? 'is' : 'are'} excluded from the expense chart.',
                    style: Theme.of(context).textTheme.bodySmall)),
          _ChartPanel(
              title: 'Consumption by period, by location',
              child: SizedBox(
                  height: 240,
                  child: Semantics(
                      label: 'Consumption by location stacked bar chart',
                      child: BarChart(BarChartData(
                          titlesData: FlTitlesData(
                              topTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false)),
                              rightTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false)),
                              leftTitles: const AxisTitles(
                                  sideTitles: SideTitles(
                                      showTitles: true, reservedSize: 40)),
                              bottomTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 32,
                                      getTitlesWidget: (value, meta) {
                                        final index = value.round();
                                        if (index < 0 ||
                                            index >= buckets.length) {
                                          return const SizedBox.shrink();
                                        }
                                        return Padding(
                                            padding:
                                                const EdgeInsets.only(top: 8),
                                            child: Text(
                                                _bucketLabel(
                                                    context,
                                                    buckets[index].start,
                                                    granularity),
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .labelSmall));
                                      }))),
                          barGroups: [
                            for (var i = 0; i < buckets.length; i++)
                              BarChartGroupData(x: i, barRods: [
                                BarChartRodData(
                                    toY: buckets[i].total.value,
                                    rodStackItems: _locationStackItems(
                                        buckets[i], zones, activeLocations),
                                    width: 18)
                              ]),
                          ]))))),
        ] else ...[
          LayoutBuilder(builder: (context, constraints) {
            final consumptionDonut = _ZoneDonut(
                title: 'Consumption by zone',
                semanticsLabel: 'Consumption by zone donut chart',
                zones: chartZones,
                valueOf: (zone) =>
                    consumptionByZone[zone.code.value]?.value ?? 0,
                labelOf: (zone) =>
                    '${(consumptionByZone[zone.code.value]?.value ?? 0).toStringAsFixed(1)} kWh');
            final expenseDonut = _ZoneDonut(
                title: 'Expenses by zone',
                semanticsLabel: 'Expenses by zone donut chart',
                zones: chartZones,
                valueOf: (zone) =>
                    (expenseByZone[zone.code.value]?.minorUnits ?? 0)
                        .toDouble(),
                labelOf: (zone) => _money(
                    context,
                    expenseByZone[zone.code.value] ??
                        Money(0, currencyCode: currencyCode)));
            if (constraints.maxWidth < 600) {
              return Column(children: [consumptionDonut, expenseDonut]);
            }
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: consumptionDonut),
              const SizedBox(width: 16),
              Expanded(child: expenseDonut),
            ]);
          }),
          _ChartPanel(
              title: 'Consumption by period',
              child: SizedBox(
                  height: 240,
                  child: Semantics(
                      label: 'Consumption stacked bar chart',
                      child: BarChart(BarChartData(
                          titlesData: FlTitlesData(
                              topTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false)),
                              rightTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false)),
                              leftTitles: const AxisTitles(
                                  sideTitles: SideTitles(
                                      showTitles: true, reservedSize: 40)),
                              bottomTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 32,
                                      getTitlesWidget: (value, meta) {
                                        final index = value.round();
                                        if (index < 0 ||
                                            index >= buckets.length) {
                                          return const SizedBox.shrink();
                                        }
                                        return Padding(
                                            padding:
                                                const EdgeInsets.only(top: 8),
                                            child: Text(
                                                _bucketLabel(
                                                    context,
                                                    buckets[index].start,
                                                    granularity),
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .labelSmall));
                                      }))),
                          barGroups: [
                            for (var i = 0; i < buckets.length; i++)
                              BarChartGroupData(x: i, barRods: [
                                BarChartRodData(
                                    toY: buckets[i].total.value,
                                    rodStackItems:
                                        _stackItems(buckets[i], zones),
                                    width: 18)
                              ]),
                          ]))))),
          _ChartPanel(
              title: 'Cumulative meter value',
              child: SizedBox(
                  height: 240,
                  child: Semantics(
                      label: 'Cumulative meter value line chart',
                      child: LineChart(LineChartData(
                          titlesData: FlTitlesData(
                              topTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false)),
                              rightTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false)),
                              leftTitles: const AxisTitles(
                                  sideTitles: SideTitles(
                                      showTitles: true, reservedSize: 48)),
                              bottomTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 32,
                                      getTitlesWidget: (value, meta) => Padding(
                                          padding:
                                              const EdgeInsets.only(top: 8),
                                          child: Text(
                                              _formatDate(context,
                                                  _dateFromDayValue(value)),
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .labelSmall))))),
                          lineBarsData: [
                            for (final zone in chartZones)
                              _cumulativeLine(readings, zone),
                          ]))))),
          for (final zone
              in zones.where((z) => deltasByZone.containsKey(z.code.value)))
            Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Card(
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(zone.name,
                                  style:
                                      Theme.of(context).textTheme.titleSmall),
                              const SizedBox(height: 8),
                              DataTable(columns: const [
                                DataColumn(label: Text('Period')),
                                DataColumn(label: Text('Consumption'))
                              ], rows: [
                                for (final delta
                                    in deltasByZone[zone.code.value]!)
                                  DataRow(cells: [
                                    DataCell(
                                        Text(_formatDate(context, delta.to))),
                                    DataCell(Text(
                                        '${delta.consumption.value.toStringAsFixed(3)} kWh'))
                                  ]),
                              ]),
                            ])))),
        ],
      ]),
    );
  }
}

/// Day/night replace the total slice once they carry data, so nothing is double-counted.
List<TariffZone> _chartZones(
    List<TariffZone> zones, Iterable<String> withData) {
  final data = withData.toSet();
  final present =
      zones.where((zone) => data.contains(zone.code.value)).toList();
  final components =
      present.where((zone) => zone.kind != ZoneKind.total).toList();
  return components.isEmpty ? present : components;
}

List<BarChartRodStackItem> _stackItems(
    ConsumptionBucket bucket, List<TariffZone> zones) {
  var from = 0.0;
  return [
    for (final entry in bucket.byZone.entries)
      if (entry.value.value > 0)
        BarChartRodStackItem(from, from += entry.value.value,
            Color(_zoneFor(zones, entry.key)?.colorArgb ?? 0xff008577)),
  ];
}

/// A location's consumption is its component zones (day/night, ...) when they
/// have data, falling back to its total zone otherwise — the same
/// double-counting guard `_chartZones` applies within a single location.
Kwh _locationConsumption(int locationId, List<TariffZone> zones,
    Map<String, Kwh> consumptionByZone) {
  final locationZones =
      zones.where((zone) => zone.locationId == locationId).toList();
  final selected = _chartZones(locationZones, consumptionByZone.keys);
  return selected.fold(Kwh(0),
      (sum, zone) => sum + (consumptionByZone[zone.code.value] ?? Kwh(0)));
}

Money _locationExpense(int locationId, List<TariffZone> zones,
    Map<String, Money> expenseByZone, String currencyCode) {
  final locationZones =
      zones.where((zone) => zone.locationId == locationId).toList();
  final selected = _chartZones(locationZones, expenseByZone.keys);
  return selected.fold(
      Money(0, currencyCode: currencyCode),
      (sum, zone) =>
          sum +
          (expenseByZone[zone.code.value] ??
              Money(0, currencyCode: currencyCode)));
}

/// True if any tariff rate for this location's zones is priced in
/// [currencyCode]; otherwise the location has nothing to contribute to the
/// combined expense chart and must be excluded rather than silently zeroed.
bool _locationHasCurrency(int locationId, List<TariffZone> zones,
    List<TariffRate> rates, String currencyCode) {
  final zoneCodes = zones
      .where((zone) => zone.locationId == locationId)
      .map((zone) => zone.code.value)
      .toSet();
  return rates.any((rate) =>
      zoneCodes.contains(rate.zoneId) &&
      rate.pricePerKwh.currencyCode == currencyCode);
}

Map<int, Kwh> _sumByLocation(Map<String, Kwh> byZone, List<TariffZone> zones) {
  final locationOf = {
    for (final zone in zones) zone.code.value: zone.locationId
  };
  final result = <int, Kwh>{};
  for (final entry in byZone.entries) {
    final locationId = locationOf[entry.key];
    if (locationId == null) continue;
    result[locationId] = (result[locationId] ?? Kwh(0)) + entry.value;
  }
  return result;
}

List<BarChartRodStackItem> _locationStackItems(ConsumptionBucket bucket,
    List<TariffZone> zones, List<Location> locations) {
  var from = 0.0;
  return [
    for (final entry in _sumByLocation(bucket.byZone, zones).entries)
      if (entry.value.value > 0)
        BarChartRodStackItem(from, from += entry.value.value,
            Color(_locationFor(locations, entry.key)?.colorArgb ?? 0xff008577)),
  ];
}

Location? _locationFor(List<Location> locations, int id) {
  for (final location in locations) {
    if (location.id == id) return location;
  }
  return null;
}

ReconciliationWarning? _reconcile(
    List<TariffZone> zones, Map<String, Kwh> consumptionByZone) {
  Kwh? total;
  final components = <Kwh>[];
  for (final zone in zones) {
    final value = consumptionByZone[zone.code.value];
    if (value == null) continue;
    if (zone.kind == ZoneKind.total) {
      total = value;
    } else {
      components.add(value);
    }
  }
  if (total == null || components.isEmpty) return null;
  return ZoneReconciliation().compare(total, components);
}

LineChartBarData _cumulativeLine(List<MeterReading> readings, TariffZone zone) {
  final zoneReadings = readings
      .where((reading) => reading.zoneId == zone.code.value)
      .toList()
    ..sort((a, b) => a.readingDate.compareTo(b.readingDate));
  return LineChartBarData(spots: [
    for (final reading in zoneReadings)
      FlSpot(_dayValue(reading.readingDate), reading.valueKwh.value)
  ], color: Color(zone.colorArgb));
}

/// Days since epoch, used as the shared x-axis coordinate for date-based charts.
double _dayValue(DateTime date) =>
    DateTime(date.year, date.month, date.day).millisecondsSinceEpoch / 86400000;

DateTime _dateFromDayValue(double value) =>
    DateTime.fromMillisecondsSinceEpoch((value * 86400000).round());

String _bucketLabel(
    BuildContext context, DateTime start, ConsumptionGranularity granularity) {
  final locale = Localizations.localeOf(context).toString();
  return granularity == ConsumptionGranularity.month
      ? DateFormat.MMM(locale).format(start)
      : DateFormat.Md(locale).format(start);
}

class _ZoneDonut extends StatelessWidget {
  const _ZoneDonut(
      {required this.title,
      required this.semanticsLabel,
      required this.zones,
      required this.valueOf,
      required this.labelOf});
  final String title;
  final String semanticsLabel;
  final List<TariffZone> zones;
  final double Function(TariffZone) valueOf;
  final String Function(TariffZone) labelOf;

  @override
  Widget build(BuildContext context) {
    final slices = zones.where((zone) => valueOf(zone) > 0).toList();
    final sum = slices.fold(0.0, (total, zone) => total + valueOf(zone));
    return _ChartPanel(
        title: title,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              height: 200,
              child: Semantics(
                  label: semanticsLabel,
                  child: slices.isEmpty
                      ? const Center(child: Text('No data in this range'))
                      : PieChart(PieChartData(
                          centerSpaceRadius: 48,
                          sectionsSpace: 2,
                          sections: [
                              for (final zone in slices)
                                PieChartSectionData(
                                    value: valueOf(zone),
                                    radius: 44,
                                    color: Color(zone.colorArgb),
                                    title:
                                        '${(valueOf(zone) / sum * 100).round()}%',
                                    titleStyle: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white)),
                            ])))),
          const SizedBox(height: 12),
          for (final zone in slices)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                          color: Color(zone.colorArgb),
                          shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(zone.name)),
                  Text(labelOf(zone),
                      style: Theme.of(context).textTheme.labelLarge),
                ])),
        ]));
  }
}

class _LocationDonut extends StatelessWidget {
  const _LocationDonut(
      {required this.title,
      required this.semanticsLabel,
      required this.locations,
      required this.valueOf,
      required this.labelOf});
  final String title;
  final String semanticsLabel;
  final List<Location> locations;
  final double Function(Location) valueOf;
  final String Function(Location) labelOf;

  @override
  Widget build(BuildContext context) {
    final slices =
        locations.where((location) => valueOf(location) > 0).toList();
    final sum =
        slices.fold(0.0, (total, location) => total + valueOf(location));
    return _ChartPanel(
        title: title,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              height: 200,
              child: Semantics(
                  label: semanticsLabel,
                  child: slices.isEmpty
                      ? const Center(child: Text('No data in this range'))
                      : PieChart(PieChartData(
                          centerSpaceRadius: 48,
                          sectionsSpace: 2,
                          sections: [
                              for (final location in slices)
                                PieChartSectionData(
                                    value: valueOf(location),
                                    radius: 44,
                                    color: Color(location.colorArgb),
                                    title:
                                        '${(valueOf(location) / sum * 100).round()}%',
                                    titleStyle: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white)),
                            ])))),
          const SizedBox(height: 12),
          for (final location in slices)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                          color: Color(location.colorArgb),
                          shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(location.name)),
                  Text(labelOf(location),
                      style: Theme.of(context).textTheme.labelLarge),
                ])),
        ]));
  }
}

class _ChartPanel extends StatelessWidget {
  const _ChartPanel({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            child,
          ]),
        ),
      );
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 180,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label),
              const SizedBox(height: 8),
              Text(value, style: Theme.of(context).textTheme.titleLarge),
            ]),
          ),
        ),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState(
      {required this.icon, required this.title, required this.message});
  final IconData icon;
  final String title;
  final String message;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            Text(message, textAlign: TextAlign.center),
          ]),
        ),
      );
}

class _ReadingDialog extends StatefulWidget {
  const _ReadingDialog(
      {required this.zones, required this.readings, this.initial});
  final List<TariffZone> zones;
  final List<MeterReading> readings;
  final MeterReading? initial;
  @override
  State<_ReadingDialog> createState() => _ReadingDialogState();
}

class _ReadingDialogState extends State<_ReadingDialog> {
  late final TextEditingController value;
  late final TextEditingController note;
  late final Map<String, TextEditingController> zoneValues;
  final zoneResets = <String, bool>{};
  late String zoneId;
  late DateTime date;
  late bool isReset;
  String? error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    value = TextEditingController(
        text: initial == null ? '' : initial.valueKwh.value.toString());
    note = TextEditingController(text: initial?.note ?? '');
    final codes = widget.zones.map((zone) => zone.code.value).toList();
    zoneValues = {
      for (final zone in widget.zones)
        zone.code.value: TextEditingController(
            text: initial?.zoneId == zone.code.value
                ? initial!.valueKwh.value.toString()
                : '')
    };
    for (final zone in widget.zones) {
      zoneResets[zone.code.value] =
          initial?.zoneId == zone.code.value && initial!.isReset;
    }
    zoneId = initial != null && codes.contains(initial.zoneId)
        ? initial.zoneId
        : codes.first;
    date = _dateOnly(initial?.readingDate ?? DateTime.now());
    isReset = initial?.isReset ?? false;
  }

  @override
  void dispose() {
    value.dispose();
    note.dispose();
    for (final controller in zoneValues.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
        context: context,
        initialDate: date,
        firstDate: DateTime(2000),
        lastDate: _dateOnly(DateTime.now()));
    if (picked != null) setState(() => date = _dateOnly(picked));
  }

  double? _previousValue(String forZone) {
    double? result;
    DateTime? closest;
    for (final item in widget.readings) {
      if (item.zoneId != forZone || item.id == widget.initial?.id) continue;
      if (!item.readingDate.isBefore(date)) continue;
      if (closest == null || item.readingDate.isAfter(closest)) {
        closest = item.readingDate;
        result = item.valueKwh.value;
      }
    }
    return result;
  }

  void _save() {
    final validator = ReadingValidator(_dateOnly(DateTime.now()));
    final entries = <MeterReading>[];
    final codes = widget.initial == null ? zoneValues.keys : [zoneId];
    for (final code in codes) {
      final controller = widget.initial == null ? zoneValues[code]! : value;
      final parsed =
          double.tryParse(controller.text.trim().replaceAll(',', '.'));
      if (parsed == null || parsed < 0) {
        setState(() => error = 'Enter a non-negative number for $code.');
        return;
      }
      final reset =
          widget.initial == null ? zoneResets[code] ?? false : isReset;
      final duplicate = widget.readings.any((item) =>
          item.id != widget.initial?.id &&
          item.zoneId == code &&
          _dateOnly(item.readingDate) == date);
      final results = [
        validator.validateDuplicate(duplicate),
        validator.validateFuture(date),
        validator.validateDecrease(_previousValue(code) ?? 0, parsed, reset),
      ];
      for (final result in results) {
        if (result is! Valid) {
          setState(() => error = '$code: ${result.message}');
          return;
        }
      }
      entries.add(MeterReading(widget.initial?.id ?? 0, code, date, Kwh(parsed),
          note: note.text.trim().isEmpty ? null : note.text.trim(),
          createdAt: widget.initial?.createdAt,
          updatedAt: DateTime.now(),
          isReset: reset));
    }
    Navigator.pop(context, entries);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.initial == null ? 'Add reading' : 'Edit reading'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (widget.initial != null)
                InputDecorator(
                    decoration: const InputDecoration(labelText: 'Zone'),
                    child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                            isExpanded: true,
                            value: zoneId,
                            items: [
                              for (final zone in widget.zones)
                                DropdownMenuItem(
                                    value: zone.code.value,
                                    child: Text(zone.name))
                            ],
                            onChanged: (selected) =>
                                setState(() => zoneId = selected ?? zoneId))))
              else ...[
                const Align(
                    alignment: Alignment.centerLeft, child: Text('Zone')),
                for (final zone in widget.zones) ...[
                  const SizedBox(height: 8),
                  TextField(
                      controller: zoneValues[zone.code.value],
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                          labelText: widget.zones.length > 1
                              ? '${zone.name}: Cumulative value (kWh)'
                              : 'Cumulative value (kWh)')),
                  CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: zoneResets[zone.code.value],
                      onChanged: (checked) => setState(
                          () => zoneResets[zone.code.value] = checked ?? false),
                      title: Text(widget.zones.length > 1
                          ? '${zone.name}: Meter was reset'
                          : 'Meter was reset')),
                ],
              ],
              const SizedBox(height: 12),
              InputDecorator(
                  decoration: const InputDecoration(labelText: 'Reading date'),
                  child: Row(children: [
                    Expanded(child: Text(_formatDate(context, date))),
                    TextButton.icon(
                        onPressed: _pickDate,
                        icon: const Icon(Icons.calendar_today_outlined),
                        label: const Text('Pick'))
                  ])),
              const SizedBox(height: 12),
              if (widget.initial != null)
                TextField(
                  controller: value,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Cumulative value (kWh)'),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: note,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                    labelText: 'Label (optional)',
                    hintText: 'e.g. photo checked, estimated'),
              ),
              if (widget.initial != null)
                CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: isReset,
                    onChanged: (checked) =>
                        setState(() => isReset = checked ?? false),
                    title: const Text('Meter was reset'),
                    subtitle: const Text(
                        'Allows a value lower than the previous one')),
              if (error != null)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)))),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      );
}

const _zonePalette = <int>[
  0xff008577,
  0xfff4b400,
  0xff4285f4,
  0xffdb4437,
  0xff9c27b0,
  0xff795548,
];

class _ZoneDialog extends StatefulWidget {
  const _ZoneDialog(
      {required this.existing, this.locations = const [], this.initial});
  final List<TariffZone> existing;
  final List<Location> locations;
  final TariffZone? initial;
  @override
  State<_ZoneDialog> createState() => _ZoneDialogState();
}

class _ZoneDialogState extends State<_ZoneDialog> {
  late final TextEditingController name;
  late int colorArgb;
  late int locationId;
  String? error;

  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.initial?.name ?? '');
    colorArgb = widget.initial?.colorArgb ??
        _zonePalette[widget.existing.length % _zonePalette.length];
    final activeLocations =
        widget.locations.where((location) => !location.isArchived).toList();
    locationId = widget.initial?.locationId ??
        (activeLocations.isEmpty ? 1 : activeLocations.first.id);
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void _save() {
    final label = name.text.trim();
    if (label.isEmpty) {
      setState(() => error = 'Enter a zone name.');
      return;
    }
    final initial = widget.initial;
    if (initial != null) {
      Navigator.pop(
          context,
          initial.copyWith(
              name: label, colorArgb: colorArgb, locationId: locationId));
      return;
    }
    final slug = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.isEmpty) {
      setState(() => error = 'Use at least one letter or digit.');
      return;
    }
    if (widget.existing.any((zone) => zone.code.value == slug)) {
      setState(() => error = 'A zone with that name already exists.');
      return;
    }
    Navigator.pop(
        context,
        TariffZone(0, ZoneCode(slug), label, ZoneKind.custom,
            colorArgb: colorArgb,
            sortOrder: widget.existing.length,
            locationId: locationId));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.initial == null ? 'New zone' : 'Edit zone'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Zone name')),
            // Only shown once a second location exists, so a single-location
            // install keeps today's dialog layout unchanged.
            if (widget.locations.length > 1) ...[
              const SizedBox(height: 16),
              InputDecorator(
                  decoration: const InputDecoration(labelText: 'Location'),
                  child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                          isExpanded: true,
                          value: locationId,
                          items: [
                            for (final location in widget.locations)
                              DropdownMenuItem(
                                  value: location.id,
                                  child: Text(location.name))
                          ],
                          onChanged: (selected) => setState(
                              () => locationId = selected ?? locationId)))),
            ],
            const SizedBox(height: 16),
            Align(
                alignment: Alignment.centerLeft,
                child: Text('Colour',
                    style: Theme.of(context).textTheme.bodySmall)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final swatch in _zonePalette)
                IconButton(
                    tooltip: 'Select colour',
                    onPressed: () => setState(() => colorArgb = swatch),
                    icon: CircleAvatar(
                        backgroundColor: Color(swatch),
                        child: colorArgb == swatch
                            ? const Icon(Icons.check,
                                size: 18, color: Colors.white)
                            : null)),
            ]),
            if (error != null)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)))),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      );
}

class _LocationDialog extends StatefulWidget {
  const _LocationDialog({this.initial});
  final Location? initial;
  @override
  State<_LocationDialog> createState() => _LocationDialogState();
}

class _LocationDialogState extends State<_LocationDialog> {
  late final TextEditingController name;
  late int colorArgb;
  String? error;

  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.initial?.name ?? '');
    colorArgb = widget.initial?.colorArgb ?? _zonePalette[0];
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void _save() {
    final label = name.text.trim();
    if (label.isEmpty) {
      setState(() => error = 'Enter a location name.');
      return;
    }
    final initial = widget.initial;
    Navigator.pop(
        context,
        initial == null
            ? Location(0, label, colorArgb: colorArgb)
            : initial.copyWith(name: label, colorArgb: colorArgb));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.initial == null ? 'New location' : 'Edit location'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Location name')),
            const SizedBox(height: 16),
            Align(
                alignment: Alignment.centerLeft,
                child: Text('Colour',
                    style: Theme.of(context).textTheme.bodySmall)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final swatch in _zonePalette)
                IconButton(
                    tooltip: 'Select colour',
                    onPressed: () => setState(() => colorArgb = swatch),
                    icon: CircleAvatar(
                        backgroundColor: Color(swatch),
                        child: colorArgb == swatch
                            ? const Icon(Icons.check,
                                size: 18, color: Colors.white)
                            : null)),
            ]),
            if (error != null)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)))),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      );
}

String _money(BuildContext context, Money money) => NumberFormat.currency(
        locale: Localizations.localeOf(context).toString(),
        name: money.currencyCode,
        decimalDigits: 2)
    .format(money.minorUnits / 100);

const _commonCurrencies = <String>[
  'EUR',
  'USD',
  'GBP',
  'CHF',
  'JPY',
  'PLN',
  'CZK',
  'SEK',
  'NOK',
  'DKK',
  'AUD',
  'CAD',
];

const _customCurrencyValue = '__custom__';

class _CurrencyPicker extends StatelessWidget {
  const _CurrencyPicker({required this.currencyCode, required this.onChanged});
  final String currencyCode;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = {..._commonCurrencies, currencyCode}.toList()..sort();
    return InputDecorator(
        decoration: const InputDecoration(labelText: 'Currency'),
        child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
                value: currencyCode,
                items: [
                  for (final code in options)
                    DropdownMenuItem(value: code, child: Text(code)),
                  const DropdownMenuItem(
                      value: _customCurrencyValue, child: Text('Other…')),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  if (value == _customCurrencyValue) {
                    final custom =
                        await _promptCurrencyCode(context, currencyCode);
                    if (custom != null) onChanged(custom);
                    return;
                  }
                  onChanged(value);
                })));
  }
}

Future<String?> _promptCurrencyCode(
    BuildContext context, String initial) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
            title: const Text('Custom currency code'),
            content: TextField(
                controller: controller,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                maxLength: 3,
                decoration: const InputDecoration(
                    labelText: 'ISO 4217 code (e.g. USD)')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () {
                    final code = controller.text.trim().toUpperCase();
                    if (code.length == 3) Navigator.pop(dialogContext, code);
                  },
                  child: const Text('Save')),
            ],
          ));
  controller.dispose();
  return result;
}

class _RateDialog extends StatefulWidget {
  const _RateDialog(
      {required this.zone, required this.currencyCode, this.initial});
  final TariffZone zone;
  final String currencyCode;
  final TariffRate? initial;
  @override
  State<_RateDialog> createState() => _RateDialogState();
}

class _RateDialogState extends State<_RateDialog> {
  final price = TextEditingController();
  DateTime validFrom = _dateOnly(DateTime.now());
  DateTime? validTo;
  String? error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial == null) return;
    price.text = (initial.pricePerKwh.minorUnits / 100).toString();
    validFrom = initial.validFrom;
    validTo = initial.validTo;
  }

  @override
  void dispose() {
    price.dispose();
    super.dispose();
  }

  Future<void> _pick({required bool from}) async {
    final picked = await showDatePicker(
        context: context,
        initialDate: from ? validFrom : (validTo ?? validFrom),
        firstDate: DateTime(2000),
        lastDate: DateTime(2100));
    if (picked == null) return;
    setState(() {
      if (from) {
        validFrom = _dateOnly(picked);
      } else {
        validTo = _dateOnly(picked);
      }
    });
  }

  void _save() {
    final value = double.tryParse(price.text.trim().replaceAll(',', '.'));
    if (value == null || value < 0) {
      setState(() => error = 'Enter a non-negative price.');
      return;
    }
    final end = validTo;
    if (end != null && !end.isAfter(validFrom)) {
      setState(() => error = 'Valid to must be after valid from.');
      return;
    }
    Navigator.pop(
        context,
        TariffRate(
            widget.initial?.id ?? 0,
            widget.zone.code.value,
            Money.fromMajor(value, currencyCode: widget.currencyCode),
            validFrom,
            validTo: end));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(
            '${widget.initial == null ? 'Add' : 'Edit'} ${widget.zone.name} tariff rate'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: price,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: 'Price per kWh (${widget.currencyCode})'),
            ),
            const SizedBox(height: 12),
            InputDecorator(
                decoration: const InputDecoration(labelText: 'Valid from'),
                child: Row(children: [
                  Expanded(child: Text(_formatDate(context, validFrom))),
                  TextButton.icon(
                      onPressed: () => _pick(from: true),
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: const Text('Pick'))
                ])),
            const SizedBox(height: 12),
            InputDecorator(
                decoration:
                    const InputDecoration(labelText: 'Valid to (optional)'),
                child: Row(children: [
                  Expanded(
                      child: Text(validTo == null
                          ? 'Open-ended'
                          : _formatDate(context, validTo!))),
                  if (validTo != null)
                    IconButton(
                        tooltip: 'Clear end date',
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() => validTo = null)),
                  TextButton.icon(
                      onPressed: () => _pick(from: false),
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: const Text('Pick'))
                ])),
            if (error != null)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)))),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(onPressed: _save, child: const Text('Save'))
        ],
      );
}
