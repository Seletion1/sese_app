import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';
import 'package:sese_ride/features/trips/models/bid_models.dart';

void main() {
  group('DispatchTuning & Bid Queue Tests', () {
    test('DispatchTuning correctly parses maxConcurrentBids and bidCountdownSec from map', () {
      final defaultTuning = DispatchTuning.fromMap(null);
      expect(defaultTuning.maxConcurrentBids, 5);
      expect(defaultTuning.bidCountdownSec, 15);

      final customTuning = DispatchTuning.fromMap({
        'maxConcurrentBids': 3,
        'bidCountdownSec': 20,
      });
      expect(customTuning.maxConcurrentBids, 3);
      expect(customTuning.bidCountdownSec, 20);

      final legacyTuning = DispatchTuning.fromMap({
        'max_visible_bids': 4,
        'bidCountdownSeconds': 25,
      });
      expect(legacyTuning.maxConcurrentBids, 4);
      expect(legacyTuning.bidCountdownSec, 25);
    });

    test('Bid queue caps visible bids and promotes next queued bid on rejection', () {
      // Create 6 pending bids
      final allBids = List.generate(
        6,
        (i) => BidModel(
          bidId: 'bid_$i',
          driverId: 'driver_$i',
          driverName: 'Driver $i',
          offeredFare: 2000.0 + (i * 100),
          status: BidStatus.pending,
          createdAt: DateTime.now(),
        ),
      );

      const maxConcurrentBids = 5;

      // 1. Initial queue state: top 5 visible
      var pending = allBids.where((b) => b.status == BidStatus.pending).toList();
      var visible = pending.take(maxConcurrentBids).toList();

      expect(visible.length, 5);
      expect(visible.map((b) => b.driverId), contains('driver_0'));
      expect(visible.map((b) => b.driverId), isNot(contains('driver_5')));

      // 2. Reject bid_0 (customer rejects driver_0)
      final updatedBids = allBids.map((b) {
        if (b.driverId == 'driver_0') {
          return BidModel(
            bidId: b.bidId,
            driverId: b.driverId,
            driverName: b.driverName,
            offeredFare: b.offeredFare,
            status: BidStatus.rejected,
            createdAt: b.createdAt,
          );
        }
        return b;
      }).toList();

      // 3. Re-evaluate visible queue
      pending = updatedBids.where((b) => b.status == BidStatus.pending).toList();
      visible = pending.take(maxConcurrentBids).toList();

      expect(visible.length, 5); // Still 5 active bids
      expect(visible.map((b) => b.driverId), isNot(contains('driver_0'))); // rejected bid gone
      expect(visible.map((b) => b.driverId), contains('driver_5')); // driver_5 promoted into view!
    });
  });
}
