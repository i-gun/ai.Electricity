import 'package:ai_electricity_ui/ui.dart';
import 'package:ai_electricity_data/data.dart';
import 'package:ai_electricity_core/core.dart';
import 'package:flutter/material.dart';

void main() {
  final database = openElectricityDatabase();
  runApp(DesktopApp(
      readingRepository: DriftMeterReadingRepository(database),
      zoneRepository: DriftTariffZoneRepository(database),
      rateRepository: DriftTariffRateRepository(database)));
}

class DesktopApp extends StatelessWidget {
  const DesktopApp(
      {super.key,
      this.readingRepository,
      this.zoneRepository,
      this.rateRepository});
  final MeterReadingRepository? readingRepository;
  final TariffZoneRepository? zoneRepository;
  final TariffRateRepository? rateRepository;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ai.Electricity',
      theme: lightTheme(),
      darkTheme: darkTheme(),
      home: SharedHome(
          readingRepository: readingRepository,
          zoneRepository: zoneRepository,
          rateRepository: rateRepository),
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
