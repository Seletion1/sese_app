import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('ImageCompressionService Tests', () {
    test('default constraints match specification (1280x1280, 80% quality)', () {
      expect(ImageCompressionService.defaultMaxDimension, 1280);
      expect(ImageCompressionService.defaultQuality, 80);
    });

    test('formatBytes formats file sizes correctly', () {
      expect(ImageCompressionService.formatBytes(0), '0 B');
      expect(ImageCompressionService.formatBytes(-50), '0 B');
      expect(ImageCompressionService.formatBytes(512), '512 B');
      expect(ImageCompressionService.formatBytes(1024), '1.0 KB');
      expect(ImageCompressionService.formatBytes(1536), '1.5 KB');
      expect(ImageCompressionService.formatBytes(1024 * 1024), '1.0 MB');
      expect(ImageCompressionService.formatBytes((2.5 * 1024 * 1024).toInt()), '2.5 MB');
    });

    test('compressBytes skips re-encoding when payload is below target threshold', () async {
      // 100 bytes payload is well below 300KB threshold
      final dummyBytes = Uint8List(100);
      final result = await ImageCompressionService.compressBytes(dummyBytes);
      expect(result.length, 100);
      expect(identical(result, dummyBytes), isTrue);
    });
  });

  group('IconCacheService & Dynamic Asset Manifest Tests', () {
    test('defaultManifest defines entries for all vehicle categories and packaging types', () {
      final manifest = IconCacheService.defaultManifest;

      // Essential vehicle categories
      expect(manifest.containsKey('vehicle_bicycle'), isTrue);
      expect(manifest.containsKey('vehicle_motorcycle'), isTrue);
      expect(manifest.containsKey('vehicle_keke'), isTrue);
      expect(manifest.containsKey('vehicle_tricycle'), isTrue);
      expect(manifest.containsKey('vehicle_sedan'), isTrue);
      expect(manifest.containsKey('vehicle_car'), isTrue);
      expect(manifest.containsKey('vehicle_comfort'), isTrue);
      expect(manifest.containsKey('vehicle_premium'), isTrue);
      expect(manifest.containsKey('vehicle_luxe'), isTrue);
      expect(manifest.containsKey('vehicle_van'), isTrue);
      expect(manifest.containsKey('vehicle_truck'), isTrue);

      // Packaging types
      expect(manifest.containsKey('sender_box'), isTrue);
      expect(manifest.containsKey('package_send'), isTrue);
      expect(manifest.containsKey('receiver_box'), isTrue);
      expect(manifest.containsKey('package_receive'), isTrue);
    });

    test('all manifest entries point to Firebase Storage public ui_assets tokens', () {
      for (final entry in IconCacheService.defaultManifest.entries) {
        final info = entry.value;
        expect(info.filename.endsWith('.png'), isTrue);
        expect(info.url.startsWith('https://firebasestorage.googleapis.com/'), isTrue);
        expect(info.url.contains('ui_assets%2Ficons%2F'), isTrue);
        expect(info.sizeBytes, greaterThan(0));
      }
    });

    test('uninitialized or missing file returns null from getLocalFile', () {
      final file = IconCacheService.instance.getLocalFile('vehicle_sedan');
      expect(file, isNull);
    });
  });

  group('CachedDocumentThumbnail Widget Tests', () {
    testWidgets('renders fallback icon when imageUrl is empty', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CachedDocumentThumbnail(
              imageUrl: '',
              title: 'Driver License',
              fallbackIcon: Icons.badge_outlined,
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.badge_outlined), findsOneWidget);
    });

    testWidgets('renders fallback icon for whitespace-only imageUrl', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CachedDocumentThumbnail(
              imageUrl: '   ',
              title: 'Driver License',
              fallbackIcon: Icons.badge_outlined,
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.badge_outlined), findsOneWidget);
    });

    testWidgets('CachedDocumentThumbnailChip renders disabled without URL', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CachedDocumentThumbnailChip(
              imageUrl: '',
              label: 'NIN Document',
              fallbackIcon: Icons.assignment_outlined,
            ),
          ),
        ),
      );

      expect(find.text('NIN Document'), findsOneWidget);
      expect(find.byIcon(Icons.assignment_outlined), findsOneWidget);
      final chip = tester.widget<ActionChip>(find.byType(ActionChip));
      expect(chip.onPressed, isNull);
    });
  });
}
