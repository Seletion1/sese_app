import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_hub/features/dashboard/services/hub_pending_counts_service.dart';
import 'package:sese_hub/widgets/hub_badge.dart';

void main() {
  group('HubCountBadge Zero-State & Rendering', () {
    testWidgets('renders SizedBox.shrink when count <= 0', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HubCountBadge(count: 0),
          ),
        ),
      );

      expect(find.byType(Container), findsNothing);
      expect(find.text('0'), findsNothing);
      expect(find.byType(SizedBox), findsOneWidget);
    });

    testWidgets('renders badge pill when count > 0', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HubCountBadge(count: 5),
          ),
        ),
      );

      expect(find.text('5'), findsOneWidget);
      expect(find.byType(Container), findsOneWidget);
    });

    testWidgets('caps badge display text at 99+ when count > 99', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HubCountBadge(count: 150),
          ),
        ),
      );

      expect(find.text('99+'), findsOneWidget);
    });

    testWidgets('HubCountBadge.stream handles zero-state cleanly', (tester) async {
      final stream = Stream.value(0);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HubCountBadge.stream(stream: stream),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('0'), findsNothing);
      expect(find.byType(Container), findsNothing);
    });

    testWidgets('HubCountBadge.stream updates dynamically when count changes', (tester) async {
      final streamController = StreamController<int>.broadcast();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HubCountBadge.stream(stream: streamController.stream),
          ),
        ),
      );

      // Initial null/zero state
      await tester.pump();
      expect(find.byType(Container), findsNothing);

      // Emit pending count
      streamController.add(3);
      await tester.pumpAndSettle();
      expect(find.text('3'), findsOneWidget);

      // Item resolved -> emit 0
      streamController.add(0);
      await tester.pumpAndSettle();
      expect(find.text('3'), findsNothing);
      expect(find.byType(Container), findsNothing);

      await streamController.close();
    });
  });

  group('DriverVerification.isPendingDriverKycDoc', () {
    test('returns true for active pending driver profile', () {
      final data = {
        DriverVerification.fieldStatus: DriverVerification.pending,
        'profileStatus': 'pending_verification',
        'isPendingReview': true,
      };
      expect(DriverVerification.isPendingDriverKycDoc(data), isTrue);
    });

    test('returns false for approved or verified driver profile', () {
      final data = {
        DriverVerification.fieldStatus: DriverVerification.approved,
        'profileStatus': 'approved',
        'isPendingReview': false,
      };
      expect(DriverVerification.isPendingDriverKycDoc(data), isFalse);

      final data2 = {
        DriverVerification.fieldStatus: 'verified',
        'profileStatus': 'verified',
        'isPendingReview': false,
      };
      expect(DriverVerification.isPendingDriverKycDoc(data2), isFalse);
    });

    test('returns false for rejected driver profile', () {
      final data = {
        DriverVerification.fieldStatus: DriverVerification.rejected,
        'profileStatus': 'rejected',
        'isPendingReview': false,
      };
      expect(DriverVerification.isPendingDriverKycDoc(data), isFalse);
    });

    test('retains true if profileStatus is explicitly pending_verification even with legacy status', () {
      final data = {
        DriverVerification.fieldStatus: 'submitted',
        'profileStatus': 'pending_verification',
        'isPendingReview': true,
      };
      expect(DriverVerification.isPendingDriverKycDoc(data), isTrue);
    });
  });

  group('HubPendingCountsService Zero-State Fallback Streams', () {
    late HubPendingCountsService countsService;

    setUp(() {
      countsService = HubPendingCountsService();
    });

    test('Zero-state: offline/uninitialized Firestore yields 0 counts', () async {
      expect(await countsService.pendingVehiclesCountStream.first, 0);
      expect(await countsService.pendingDriverKycCountStream.first, 0);
      expect(await countsService.pendingCustomerKycCountStream.first, 0);
      expect(await countsService.pendingUserOnboardingCountStream.first, 0);
      expect(await countsService.pendingAgentApplicationsCountStream.first, 0);
      expect(await countsService.pendingSupportChatsCountStream.first, 0);
      expect(await countsService.pendingPayoutsCountStream.first, 0);
      expect(await countsService.fleetTotalPendingCountStream.first, 0);
      expect(await countsService.onboardingTotalPendingCountStream.first, 0);
    });

    test('combineStreams handles multiple streams, calculates sum, and cancels cleanly', () async {
      final s1 = StreamController<int>.broadcast();
      final s2 = StreamController<int>.broadcast();

      final combined = HubPendingCountsService.combineStreams([s1.stream, s2.stream]);

      final expectFuture = expectLater(combined, emitsInOrder([5, 12, 7]));

      s1.add(5); // 5 + 0 = 5
      s2.add(7); // 5 + 7 = 12
      s1.add(0); // 0 + 7 = 7

      await expectFuture;

      await s1.close();
      await s2.close();
    });
  });
}
