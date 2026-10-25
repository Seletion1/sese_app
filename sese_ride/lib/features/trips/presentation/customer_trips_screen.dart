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
          return ListView.separated(
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
    return '$m ${dt.day}, $hour:$min';
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
                          _formatDate(trip.createdAt),
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
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final TripStatus status;
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
      case TripStatus.completed:
        label = 'Completed';
        color = const Color(0xFF059669);
        bgColor = const Color(0xFFD1FAE5);
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
      case TripStatus.searchingDriver:
      case TripStatus.waitingForAcceptance:
      case TripStatus.driverPinged:
      case TripStatus.marketplaceOpen:
      case TripStatus.marketplaceList:
      case TripStatus.bidding:
        label = 'Searching for Driver...';
        color = const Color(0xFFD97706);
        bgColor = const Color(0xFFFEF3C7);
      case TripStatus.needsCustomerAction:
        label = 'Action Needed: Boost Fare';
        color = const Color(0xFFD97706);
        bgColor = const Color(0xFFFEF3C7);
      case TripStatus.cancelled:
        if (source == 'driver') {
          label = 'Cancelled by Driver';
        } else if (source == 'customer') {
          label = 'Cancelled by Customer';
        } else {
          label = 'Cancelled';
        }
        color = const Color(0xFFDC2626);
        bgColor = const Color(0xFFFEE2E2);
      case TripStatus.unknown:
        label = 'Active';
        color = const Color(0xFF2563EB);
        bgColor = const Color(0xFFDBEAFE);
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
