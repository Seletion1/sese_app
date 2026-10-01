import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../../trips/models/trip_models.dart';
import '../../services/driver_streak_service.dart';
import 'order_feed.dart';

/// Bottom sheet listing every Tier-3 pool order near the driver.
///
/// Same geo-filtered pool the badge counts (`OrderFeedState.withinPoolRadius`),
/// so the sheet never disagrees with the badge. Each row shows pickup,
/// drop-off, fare, distance, order type, and an honest age ("waiting Xm" —
/// pool trips carry no server expiry, so there is deliberately no countdown
/// timer). Accepting calls the zero-trust `acceptTrip` callable (atomic
/// first-wins + verified + approved-vehicle checks); it is NOT a separate
/// `claimPoolOrder` endpoint because a second entry point to the same
/// transaction would be a duplicate, not a feature.
class OrderPoolSheet extends StatefulWidget {
  final DriverStreakService streakService;
  final LatLng driverPosition;
  final String currencySymbol;

  const OrderPoolSheet({
    super.key,
    required this.streakService,
    required this.driverPosition,
    required this.currencySymbol,
  });

  @override
  State<OrderPoolSheet> createState() => _OrderPoolSheetState();
}

class _OrderPoolSheetState extends State<OrderPoolSheet> {
  String? _acceptingId;

  String _fareLabel(ActiveTrip trip) {
    if (trip.fareFormatted.isNotEmpty) return trip.fareFormatted;
    return '${widget.currencySymbol}${trip.fareAmount.toStringAsFixed(0)}';
  }

  String _typeLabel(ActiveTrip trip) {
    return trip.serviceType == 'ride' ? 'Ride' : 'Delivery';
  }

  String _ageText(ActiveTrip trip) {
    final ts = trip.updatedAt ?? trip.createdAt;
    if (ts == null) return 'waiting';
    final mins = DateTime.now().difference(ts).inMinutes;
    if (mins < 1) return 'just now';
    if (mins == 1) return 'waiting 1m';
    return 'waiting ${mins}m';
  }

  Future<void> _accept(ActiveTrip trip) async {
    if (_acceptingId != null) return;
    setState(() => _acceptingId = trip.tripId);
    try {
      await widget.streakService.acceptTrip(trip.tripId);
      if (!mounted) return;
      Navigator.of(context).pop(trip.tripId);
    } on DriverStreakException catch (e) {
      if (!mounted) return;
      setState(() => _acceptingId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.userMessage)),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _acceptingId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Could not accept this order. Try another.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return StreamBuilder<List<ActiveTrip>>(
          stream: widget.streakService.marketplaceStream(),
          builder: (context, snap) {
            final trips = (snap.data ?? const <ActiveTrip>[])
                .where((t) => OrderFeedState.withinPoolRadius(
                    t, widget.driverPosition))
                .toList();
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant
                        .withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      const Icon(Icons.radar, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Order Pool (${trips.length})',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
                if (trips.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: 24, vertical: 32),
                    child: Text(
                      'No open orders near you right now. New requests '
                      'appear here the moment they hit the pool.',
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  Expanded(
                    child: ListView.separated(
                      key: const Key('order_pool_list'),
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                      itemCount: trips.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: 8),
                      itemBuilder: (context, i) =>
                          _PoolRow(
                        trip: trips[i],
                        fareLabel: _fareLabel(trips[i]),
                        typeLabel: _typeLabel(trips[i]),
                        ageText: _ageText(trips[i]),
                        accepting:
                            _acceptingId == trips[i].tripId,
                        onAccept: () => _accept(trips[i]),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _PoolRow extends StatelessWidget {
  final ActiveTrip trip;
  final String fareLabel;
  final String typeLabel;
  final String ageText;
  final bool accepting;
  final VoidCallback onAccept;

  const _PoolRow({
    required this.trip,
    required this.fareLabel,
    required this.typeLabel,
    required this.ageText,
    required this.accepting,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    typeLabel,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    fareLabel,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                Text(
                  ageText,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '◉ ${trip.pickupAddress.isEmpty ? 'Pickup (see map)' : trip.pickupAddress}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
            Text(
              '◎ ${trip.dropoffAddress.isEmpty ? 'Drop-off (see map)' : trip.dropoffAddress}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
            Text(
              '${trip.distanceKm.toStringAsFixed(1)} km',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: Key('accept_pool_order_${trip.tripId}'),
              onPressed: accepting ? null : onAccept,
              child: accepting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Accept Order'),
            ),
          ],
        ),
      ),
    );
  }
}
