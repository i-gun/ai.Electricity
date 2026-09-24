import 'package:ai_electricity_ui/ui.dart';
import 'package:ai_electricity_data/data.dart';
import 'package:ai_electricity_core/core.dart';
import 'package:flutter/material.dart';

void main() {
  final database = openElectricityDatabase();
  runApp(MobileApp(
      readingRepository: DriftMeterReadingRepository(database),
      zoneRepository: DriftTariffZoneRepository(database),
      rateRepository: DriftTariffRateRepository(database),
      locationRepository: DriftLocationRepository(database)));
}

class MobileApp extends StatelessWidget {
  const MobileApp(
      {super.key,
      this.readingRepository,
      this.zoneRepository,
      this.rateRepository,
      this.locationRepository});
  final MeterReadingRepository? readingRepository;
  final TariffZoneRepository? zoneRepository;
  final TariffRateRepository? rateRepository;
  final LocationRepository? locationRepository;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ai.Electricity',
      theme: lightTheme(),
      darkTheme: darkTheme(),
      home: SharedHome(
          compact: true,
          readingRepository: readingRepository,
          zoneRepository: zoneRepository,
          rateRepository: rateRepository,
          locationRepository: locationRepository),
    );
  }
}

class PlaceholderHome extends StatelessWidget {
  const PlaceholderHome({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: const Center(child: Text('Workspace bootstrap complete.')),
    );
  }
}
