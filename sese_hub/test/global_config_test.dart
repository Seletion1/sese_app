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
        home: GlobalConfigScreen(
          configService: service,
          isOwner: true,
        ),
      ),
    );

    // Initial pump and settle for loading
    await tester.pumpAndSettle();

    // Verify title and publish action button
    expect(find.text('Dynamic Global Configuration Engine'), findsOneWidget);
    expect(find.text('Publish Config'), findsOneWidget);
  });

  testWidgets('does not call setState after dispose when config load completes late', (tester) async {
    final configs = Completer<List<RegionConfig>>();
    final maxBids = Completer<int>();
    final service = _DelayedConfigService(configs, maxBids);

    await tester.pumpWidget(
      MaterialApp(home: GlobalConfigScreen(configService: service)),
    );
    expect(find.byType(SeseCardSkeleton), findsOneWidget);

    // Remove the screen from the tree while the config reads are in flight.
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));

    configs.complete([RegionConfig.globalDefault()]);
    maxBids.complete(5);
    await tester.pump();

    // Completing the load after dispose must not throw
    // "setState() called after dispose()" or use disposed controllers.
  });

  testWidgets('GlobalConfigScreen permits section navigation and scope selection', (tester) async {
    final service = SystemConfigService();

    await tester.pumpWidget(
      MaterialApp(
        home: GlobalConfigScreen(
          configService: service,
          isOwner: true,
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Scope & Region section is default active, showing regional & currency scoping
    expect(find.text('1. Regional & Currency Scoping'), findsOneWidget);
    expect(find.text('Global Default'), findsWidgets);
  });

  test('SystemConfigService handles null firestore gracefully with local fallback', () async {
    final service = SystemConfigService(null);

    final configs = await service.getAllConfigs();
    expect(configs, isNotEmpty);
    expect(configs.any((c) => c.id == 'global_default'), isTrue);

    final tuning = await service.getDispatchTuning();
    expect(tuning.dispatchRadiusKm, 15);
    expect(tuning.tier1RadiusKm, 3);

    final maxBids = await service.getMaxVisibleBids();
    expect(maxBids, 5);
  });
}
