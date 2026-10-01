import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_hub/features/config/presentation/global_config_screen.dart';
import 'package:sese_hub/features/config/services/system_config_service.dart';

class _DelayedConfigService extends SystemConfigService {
  _DelayedConfigService(this._configs, this._maxBids);

  final Completer<List<RegionConfig>> _configs;
  final Completer<int> _maxBids;

  @override
  Future<List<RegionConfig>> getAllConfigs() => _configs.future;

  @override
  Future<int> getMaxVisibleBids() => _maxBids.future;
}

void main() {
  testWidgets('GlobalConfigScreen displays hierarchy banner, scoping, and vehicle pricing', (tester) async {
    final service = SystemConfigService();

    await tester.pumpWidget(
      MaterialApp(
        home: GlobalConfigScreen(configService: service),
      ),
    );

    // Initial pump and settle for loading
    await tester.pumpAndSettle();

    // Verify top section '1. Regional & Currency Scoping' is displayed directly at top
    expect(find.text('System Fallback Hierarchy Engine'), findsNothing);
    expect(find.text('1. Regional & Currency Scoping'), findsOneWidget);

    // Verify vehicle category entries
    expect(find.text('Bicycle'), findsOneWidget);
    expect(find.text('Motorcycle'), findsOneWidget);
    expect(find.text('Tricycle (Keke)'), findsOneWidget);
    expect(find.text('Car / Sedan'), findsOneWidget);
    expect(find.text('Van'), findsOneWidget);
    expect(find.text('Truck'), findsOneWidget);

    // Verify Car / Sedan Ride Tiers
    expect(find.text('3. Car / Sedan Passenger Ride Tiers (Year-Based Logic)'), findsOneWidget);
    expect(find.text('Standard / Comfort'), findsOneWidget);
    expect(find.text('Executive / Premium'), findsOneWidget);
    expect(find.text('Luxe / Super'), findsOneWidget);

    // Verify Publish Config action button
    expect(find.text('Publish Config'), findsOneWidget);
  });

  testWidgets('does not call setState after dispose when config load completes late', (tester) async {
    final configs = Completer<List<RegionConfig>>();
    final maxBids = Completer<int>();
    final service = _DelayedConfigService(configs, maxBids);

    await tester.pumpWidget(
      MaterialApp(home: GlobalConfigScreen(configService: service)),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Remove the screen from the tree while the config reads are in flight.
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));

    configs.complete([RegionConfig.globalDefault()]);
    maxBids.complete(5);
    await tester.pump();

    // Completing the load after dispose must not throw
    // "setState() called after dispose()" or use disposed controllers.
  });
}
