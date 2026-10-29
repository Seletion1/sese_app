import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../../trips/models/trip_models.dart';
import '../../trips/presentation/live_trip_screen.dart';
import '../../trips/services/trip_service.dart';

/// Unified real-time trip feed for customer and driver apps.
///
/// Subscribes to [TripRepository.userTripHistoryStream] to display a direct
/// chronological activity feed of all trip events (active, completed, cancelled)
/// with route summaries, fare amounts, and lifecycle status badges.
class CustomerTripsScreen extends StatelessWidget {
  final String customerId;
  final bool isDriver;
  final TripRepository? tripRepository;

  const CustomerTripsScreen({
    super.key,
    required this.customerId,
    this.isDriver = false,
    this.tripRepository,
  });

  TripRepository get _repo => tripRepository ?? FirestoreTripRepository();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('Trips')),
      body: StreamBuilder<List<ActiveTrip>>(
        stream: _repo.userTripHistoryStream(customerId, isDriver: isDriver),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off, size: 52, color: Colors.grey),
                    const SizedBox(height: 12),
                    Text(
                      'Unable to load trips',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${snapshot.error}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            );
          }
          final trips = snapshot.data ?? [];
          if (trips.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.receipt_long,
                      size: 56,
                      color: theme.textTheme.bodySmall?.color ?? Colors.grey,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No trips available yet',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isDriver
                          ? 'Go online to accept orders and start earning — '
                              'your trip activity will appear here.'
                          : 'Book a ride or send an item from Home — '
                              'your trip activity will appear here.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async {
              // Stream updates automatically in real-time
              await Future<void>.delayed(const Duration(milliseconds: 400));
            },
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: trips.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final trip = trips[i];
                return _TripFeedCard(
                  trip: trip,
                  repository: _repo,
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _TripFeedCard extends StatelessWidget {
  final ActiveTrip trip;
  final TripRepository repository;

  const _TripFeedCard({
    required this.trip,
    required this.repository,
  });

  String _formatDate(DateTime? dt) {
    if (dt == null) return '';
    const monthNames = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    final m = monthNames[dt.month - 1];
    final hour = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final year = dt.year != DateTime.now().year ? ' ${dt.year}' : '';
    return '$m ${dt.day}$year • $hour:$min';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fareStr = trip.fareFormatted.isNotEmpty
        ? trip.fareFormatted
        : '₦${trip.fareAmount.toStringAsFixed(0)}';

    return Card(
      elevation: 1.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          if (trip.isLive) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => LiveTripScreen(
                  tripId: trip.tripId,
                  repository: repository,
                ),
              ),
            );
          } else {
            _showTripSummarySheet(context, trip);
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Row: Service Icon, Service Type + Date, Fare Amount
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.seseGold.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      trip.serviceType == 'ride'
                          ? Icons.directions_car_rounded
                          : Icons.local_shipping_rounded,
                      color: const Color(0xFFD97706),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          trip.serviceType == 'ride'
                              ? 'Ride-Hailing'
                              : 'Package Delivery',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          _formatDate(trip.createdAt ?? trip.updatedAt ?? trip.settledAt),
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.textTheme.bodySmall?.color,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    fareStr,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Divider(height: 1),
              ),
              // Route Summary: Pickup -> Dropoff
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Icon(Icons.circle, size: 8, color: Colors.green),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      trip.pickupAddress.isEmpty
                          ? 'Pickup location'
                          : trip.pickupAddress,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Icon(Icons.location_on, size: 10, color: Colors.red),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      trip.dropoffAddress.isEmpty
                          ? 'Drop-off destination'
                          : trip.dropoffAddress,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Status Badge
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _StatusChip(status: trip.status, source: trip.cancellationSource),
                  if (trip.isLive)
                    const Row(
                      children: [
                        Text(
                          'Track Live',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFD97706),
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: Color(0xFFD97706),
                        ),
                      ],
                    )
                  else
                    const Row(
                      children: [
                        Text(
                          'View Details',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey,
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: Colors.grey,
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showTripSummarySheet(BuildContext context, ActiveTrip trip) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final fareStr = trip.fareFormatted.isNotEmpty
            ? trip.fareFormatted
            : '₦${trip.fareAmount.toStringAsFixed(0)}';

        return Container(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Trip Details',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  _StatusChip(status: trip.status, source: trip.cancellationSource),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.cardColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.withValues(alpha: 0.15)),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          trip.serviceType == 'ride' ? 'Ride Fare' : 'Delivery Fare',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          fareStr,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            color: AppColors.seseGold,
                          ),
                        ),
                      ],
                    ),
                    if (trip.paymentMode == 'split') ...[
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Split Breakdown', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          Text(
                            'Sender: ₦${trip.senderShareAmount?.toStringAsFixed(0) ?? "0"} • Receiver: ₦${trip.receiverShareAmount?.toStringAsFixed(0) ?? "0"}',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Icon(Icons.circle, size: 10, color: Colors.green),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Pickup', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        Text(
                          trip.pickupAddress.isEmpty ? 'Pickup location' : trip.pickupAddress,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                        if (trip.pickupName.isNotEmpty)
                          Text('Contact: ${trip.pickupName}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Divider(indent: 20),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Icon(Icons.location_on, size: 12, color: Colors.red),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Destination', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        Text(
                          trip.dropoffAddress.isEmpty ? 'Drop-off destination' : trip.dropoffAddress,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                        if (trip.dropoffName.isNotEmpty)
                          Text('Contact: ${trip.dropoffName}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Status badge rendered on every trip card and in the trip detail sheet.
///
/// Covers the full server lifecycle including the driver-side
/// `CANCELLED_WAITING_CASH_SETTLEMENT` state, which was previously falling
/// through to `TripStatus.unknown` and showing as "Active" — a misleading
/// label for what is actually a terminal-pending cancellation.
class _StatusChip extends StatelessWidget {
  final TripStatus status;

  /// `cancellationSource` value from Firestore — used to distinguish
  /// driver-declined, driver-cancelled, and customer-cancelled flows inside
  /// the generic [TripStatus.cancelled] bucket.
  final String? source;

  const _StatusChip({
    required this.status,
    this.source,
  });

  @override
  Widget build(BuildContext context) {
    final String label;
    final Color color;
    final Color bgColor;

    switch (status) {
      // ── Terminal success ───────────────────────────────────────────────
      case TripStatus.completed:
        label = 'Completed';
        color = const Color(0xFF059669);
        bgColor = const Color(0xFFD1FAE5);

      // ── Active / live states ───────────────────────────────────────────
      case TripStatus.inProgress:
        label = 'In Progress';
        color = const Color(0xFF2563EB);
        bgColor = const Color(0xFFDBEAFE);
      case TripStatus.driverAccepted:
      case TripStatus.driverArriving:
        label = 'Driver En Route';
        color = const Color(0xFF059669);
        bgColor = const Color(0xFFD1FAE5);
      case TripStatus.driverArrived:
        label = 'Driver Arrived';
        color = const Color(0xFF059669);
        bgColor = const Color(0xFFD1FAE5);

      // ── Searching / matchmaking ────────────────────────────────────────
      case TripStatus.searchingDriver:
      case TripStatus.waitingForAcceptance:
      case TripStatus.driverPinged:
      case TripStatus.marketplaceOpen:
      case TripStatus.marketplaceList:
      case TripStatus.bidding:
        label = 'Searching for Driver';
        color = const Color(0xFFD97706);
        bgColor = const Color(0xFFFEF3C7);

      // ── Customer action needed ─────────────────────────────────────────
      case TripStatus.needsCustomerAction:
        label = 'Action Needed';
        color = const Color(0xFFD97706);
        bgColor = const Color(0xFFFEF3C7);

      // ── Pending cash confirmation (driver must confirm before closing) ─
      case TripStatus.cancelledWaitingCashSettlement:
        label = 'Awaiting Cash Confirmation';
        color = const Color(0xFFD97706);
        bgColor = const Color(0xFFFEF3C7);

      // ── Cancelled — differentiated by cancellationSource ──────────────
      case TripStatus.cancelled:
        if (source == 'driver_declined' ||
            source == 'driver_rejected' ||
            source == 'rejected' ||
            source == 'declined' ||
            source == 'ping_expired') {
          label = 'Order Declined';
          color = const Color(0xFFD97706);
          bgColor = const Color(0xFFFEF3C7);
        } else if (source == 'driver' ||
            source == 'driver_cancelled' ||
            source == 'driver_before_arrival' ||
            source == 'driver_cancelled_reassigning' ||
            source == 'driver_cancelled_max_reached') {
          label = 'Cancelled by Driver';
          color = const Color(0xFFDC2626);
          bgColor = const Color(0xFFFEE2E2);
        } else if (source == 'customer' || source == 'customer_cancelled') {
          label = 'Cancelled by You';
          color = const Color(0xFFDC2626);
          bgColor = const Color(0xFFFEE2E2);
        } else if (source == 'admin_hub') {
          label = 'Cancelled by Support';
          color = const Color(0xFF6B7280);
          bgColor = const Color(0xFFF3F4F6);
        } else {
          label = 'Cancelled';
          color = const Color(0xFFDC2626);
          bgColor = const Color(0xFFFEE2E2);
        }

      // ── Catch-all (unknown is never shown in history — trips.ts only
      // writes known statuses, but guard avoids missing-case warnings) ───
      case TripStatus.unknown:
        label = 'Processing';
        color = const Color(0xFF6B7280);
        bgColor = const Color(0xFFF3F4F6);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
