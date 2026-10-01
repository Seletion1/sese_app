import 'package:flutter_test/flutter_test.dart';
import 'package:sese_hub/features/verification/services/fleet_repository.dart';

/// Canonical doc as written by the driver app (registerVehicle → toMap):
/// 2018 Toyota Corolla (LAG-734-XY), PENDING.
Map<String, dynamic> _corolla({
  String verificationStatus = 'PENDING',
  String? status,
  bool? isVerified,
}) {
  final map = <String, dynamic>{
    'id': 'veh-1',
    'driverId': 'driver-1',
    'category': 'car',
    'tier': 'premium',
    'make': 'Toyota',
    'model': 'Corolla',
    'year': 2018,
    'licensePlate': 'LAG-734-XY',
    'color': 'Silver',
    'documents': {'Vehicle License': 'https://example.com/doc.jpg'},
    'verificationStatus': verificationStatus,
    'lifecycleStatus': 'ACTIVE',
    'createdAt': '2026-09-25T08:00:00.000Z',
    'updatedAt': '2026-09-25T08:00:00.000Z',
  };
  if (status != null) map['status'] = status;
  if (isVerified != null) map['isVerified'] = isVerified;
  return map;
}

PendingVehicleDoc _doc(String key, Map<String, dynamic> data) =>
    PendingVehicleDoc(id: 'veh-$key', key: key, data: data);

void main() {
  group('isPendingQueueMatch', () {
    test('canonical PENDING Corolla matches (renders immediately)', () {
      expect(FleetRepository.isPendingQueueMatch(_corolla()), isTrue);
    });

    test('lowercase pending matches (case-tolerant)', () {
      expect(FleetRepository.isPendingQueueMatch(_corolla(verificationStatus: 'pending')),
          isTrue);
    });

    test('legacy isVerified:false doc matches without canonical status', () {
      final data = _corolla()..remove('verificationStatus');
      data['isVerified'] = false;
      expect(FleetRepository.isPendingQueueMatch(data), isTrue);
    });

    test('legacy doc with no status fields at all still matches', () {
      final data = _corolla()..remove('verificationStatus');
      expect(FleetRepository.isPendingQueueMatch(data), isTrue);
    });

    test('rejected docs never match (canonical or legacy marker)', () {
      expect(
          FleetRepository.isPendingQueueMatch(
              _corolla(verificationStatus: 'REJECTED', isVerified: false)),
          isFalse);
      expect(FleetRepository.isPendingQueueMatch(_corolla(status: 'rejected')), isFalse);
    });

    test('approved / active docs never match', () {
      expect(
          FleetRepository.isPendingQueueMatch(
              _corolla(verificationStatus: 'APPROVED', isVerified: true)),
          isFalse);
      expect(FleetRepository.isPendingQueueMatch(_corolla(status: 'active')), isFalse);
      final approvedLegacy = _corolla()..remove('verificationStatus');
      approvedLegacy['isVerified'] = true;
      expect(FleetRepository.isPendingQueueMatch(approvedLegacy), isFalse);
    });
  });

  group('mergePendingDocs', () {
    test('de-duplicates across both backing queries, newest first', () {
      final same = _corolla();
      final older = _corolla()
        ..['licensePlate'] = 'LAG-000-AA'
        ..['createdAt'] = '2026-09-24T08:00:00.000Z'
        ..['updatedAt'] = '2026-09-24T08:00:00.000Z';
      final merged = FleetRepository.mergePendingDocs([
        _doc('driver-1/veh-1', same),
        _doc('driver-1/veh-1', Map.of(same)), // legacy-query duplicate
        _doc('driver-1/veh-0', older),
      ]);
      expect(merged.map((v) => v.licensePlate),
          ['LAG-734-XY', 'LAG-000-AA']);
      expect(merged.first.displayTitle,
          '2018 Toyota Corolla (LAG-734-XY)');
    });

    test('drops rejected docs leaking in via the legacy query', () {
      final merged = FleetRepository.mergePendingDocs([
        _doc('driver-1/veh-1', _corolla()),
        _doc(
            'driver-2/veh-9',
            _corolla(
                verificationStatus: 'PENDING',
                status: 'rejected',
                isVerified: false)),
      ]);
      expect(merged.map((v) => v.id), ['veh-driver-1/veh-1']);
    });

    test('skips unparsable docs instead of throwing', () {
      final merged = FleetRepository.mergePendingDocs([
        _doc('driver-1/veh-1', {'year': 'not-a-year'}),
      ]);
      expect(merged, isEmpty);
    });
  });

  group('pendingVehiclesStream offline', () {
    test('emits empty list when Firestore is unavailable', () async {
      // No injected Firestore and no Firebase in tests → empty, no throw.
      await expectLater(
        const FleetRepository().pendingVehiclesStream(),
        emits(const <dynamic>[]),
      );
    });
  });
}
