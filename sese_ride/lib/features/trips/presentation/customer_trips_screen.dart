import 'package:flutter/material.dart';

import '../../trips/models/trip_models.dart';
import '../../trips/presentation/live_trip_screen.dart';
import '../../trips/services/trip_service.dart';

/// Customer Trips tab: restores any live server-side request.
///
/// Queries Firestore for active trips (`status` not COMPLETED/CANCELLED) so
/// a customer who closed the app after tapping Done lands back on live
/// tracking. Tapping a trip opens [LiveTripScreen].
class CustomerTripsScreen extends StatelessWidget {
  final String customerId;
  final TripRepository? tripRepository;

  const CustomerTripsScreen({
    super.key,
    required this.customerId,
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
        stream: _repo.activeTripsStream(customerId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final trips = (snapshot.data ?? []).where((t) => t.isLive).toList();
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
                      'No active trips',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Book a ride or send an item from Home — '
                      'live requests will appear here.',
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
              return Card(
                child: ListTile(
                  leading: Icon(
                    trip.serviceType == 'ride'
                        ? Icons.directions_car
                        : Icons.local_shipping,
                    color: Theme.of(context).primaryColor,
                  ),
                  title: Text(
                    trip.pickupAddress.isEmpty
                        ? 'Trip ${trip.tripId}'
                        : trip.pickupAddress,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(_statusLabel(trip)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LiveTripScreen(
                        tripId: trip.tripId,
                        repository: _repo,
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  static String _statusLabel(ActiveTrip trip) {
    switch (trip.status) {
      case TripStatus.searchingDriver:
        return 'Looking for drivers…';
      case TripStatus.waitingForAcceptance:
      case TripStatus.driverPinged:
        return 'Waiting for driver to accept…';
      case TripStatus.marketplaceOpen:
      case TripStatus.marketplaceList:
        return 'Broadcasting to drivers…';
      case TripStatus.bidding:
        return 'Drivers are bidding — choose an offer';
      case TripStatus.driverAccepted:
      case TripStatus.driverArriving:
        return 'Driver on the way';
      case TripStatus.driverArrived:
        return 'Driver arrived';
      case TripStatus.inProgress:
        return 'In progress';
      case TripStatus.completed:
        return 'Completed';
      case TripStatus.cancelled:
        if (trip.cancellationSource == 'driver') return 'Cancelled by Driver';
        if (trip.cancellationSource == 'customer') return 'Cancelled by You';
        return 'Cancelled';
      case TripStatus.needsCustomerAction:
        return 'No driver found — raise your fare';
      case TripStatus.unknown:
        return 'Active';
    }
  }
}
