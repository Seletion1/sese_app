import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sese_core/sese_core.dart';

import '../customer/presentation/customer_verification_screen.dart';
import '../customer/services/driver_to_customer_sync.dart';
import '../trips/presentation/customer_trips_screen.dart';
import '../trips/services/trip_service.dart';
import '../customer/presentation/customer_home_map_screen.dart';
import '../settings/role_controller.dart';
import '../trips/models/trip_models.dart';
import '../trips/presentation/live_trip_screen.dart';
import 'active_trip_countdown_banner.dart';
import 'customer_profile_screen.dart';
import 'driver_home_shell.dart';

/// Customer home shell: Trips | Home (map) | Profile.
///
/// Bottom-navigation entry point for customers. Home (the live map) is the
/// default tab; Trips restores any active server-side request after the app
/// was closed; Profile hosts account details and sign-out.
class CustomerHomeShell extends StatefulWidget {
  final AppUser user;
  final AuthRepository auth;

  /// Injectable live-dispatch seam (tests pass a fake; the Trips tab falls
  /// back to the production Firestore transport when null).
  final TripRepository? tripRepository;

  const CustomerHomeShell({
    super.key,
    required this.user,
    required this.auth,
    this.tripRepository,
  });

  @override
  State<CustomerHomeShell> createState() => _CustomerHomeShellState();
}

class _CustomerHomeShellState extends State<CustomerHomeShell> {
  /// Default tab: Home (center item, active map view).
  int _selectedNavIndex = 1;

  /// Timestamp of the last back press on the Home tab for 2-second double-tap exit.
  DateTime? _lastBackPressTime;

  /// Local dismissal for the optional verification banner.
  bool _verificationBannerDismissed = false;

  @override
  void initState() {
    super.initState();
    // Customer-topic push (trip updates, bids, arrivals, announcements).
    // ignore: discarded_futures
    PushNotificationService.subscribe('user_${widget.user.uid}');
    // Device token for targeted broadcasts (admin inbox + urgent alerts).
    // ignore: discarded_futures
    PushNotificationService.registerToken(
      uid: widget.user.uid,
      country: CountryDetectionService.instance.currentCountryCode,
    );
    // Approved drivers entering Customer Mode: mirror driver profile/KYC
    // into users/{uid} so verified drivers are never asked to re-verify.
    // Fire-and-forget; the banner + profile screens react to the live
    // Firestore streams once the merge lands.
    // ignore: discarded_futures
    DriverToCustomerSync.syncIfApprovedDriver(widget.user.uid);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        MandatoryLegalAcceptanceDialog.checkAndShow(
          context,
          userId: widget.user.uid,
          userRole: 'customer',
        );
      }
    });
  }

  @override
  void dispose() {
    // ignore: discarded_futures
    PushNotificationService.unsubscribe('user_${widget.user.uid}');
    super.dispose();
  }

  void _handlePopInvoked(bool didPop) {
    if (didPop) return;

    // 1. From Sub-tabs (Trips: 0, Profile: 2): return to Home tab (1)
    if (_selectedNavIndex != 1) {
      setState(() => _selectedNavIndex = 1);
      return;
    }

    // 2. From Home tab: Require double-tap within 2 seconds to exit
    final now = DateTime.now();
    if (_lastBackPressTime == null ||
        now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
      _lastBackPressTime = now;
      ScaffoldMessenger.of(context).removeCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Press back again to exit'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // Second press within 2s window: exit app cleanly without popping root route
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) => _handlePopInvoked(didPop),
      child: Scaffold(
        body: Column(
          children: [
            _VerificationBanner(
              userId: widget.user.uid,
              dismissed: _verificationBannerDismissed,
              onDismiss: () =>
                  setState(() => _verificationBannerDismissed = true),
              onVerify: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      CustomerVerificationScreen(user: widget.user),
                ),
              ),
            ),
            // Persistent floating timer while a driver-turned-customer still
            // has an active order: 10-minute countdown, then auto-switch
            // back to Driver Mode. Self-hides when no protection is armed.
            ActiveTripCountdownBanner(
              onReturnToDriver: () {
                unawaited(RoleController.instance.activateMode(
                  widget.user.uid,
                  UserRole.driver,
                ));
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(
                    builder: (_) => DriverHomeShell(
                      user: widget.user,
                      auth: widget.auth,
                    ),
                  ),
                  (route) => false,
                );
              },
            ),
            Expanded(
              child: IndexedStack(
                index: _selectedNavIndex,
                children: [
                  CustomerTripsScreen(
                    customerId: widget.user.uid,
                    tripRepository: widget.tripRepository,
                  ),
                  CustomerHomeMapScreen(
                    user: widget.user,
                    tripRepository: widget.tripRepository,
                  ),
                  CustomerProfileScreen(
                    user: widget.user,
                    auth: widget.auth,
                    onSelectTab: (index) =>
                        setState(() => _selectedNavIndex = index),
                  ),
                ],
              ),
            ),
            StreamBuilder<List<ActiveTrip>>(
              stream: (widget.tripRepository ?? FirestoreTripRepository())
                  .activeTripsStream(widget.user.uid),
              builder: (context, snapshot) {
                final activeTrips = snapshot.data ?? [];
                if (activeTrips.isEmpty) return const SizedBox.shrink();
                return _MultiBookingBanner(
                  activeTrips: activeTrips,
                  tripRepository: widget.tripRepository,
                );
              },
            ),
          ],
        ),
        bottomNavigationBar: Builder(
          builder: (context) {
            // Bar colors come from AppTheme.bottomNavigationBarTheme (which
            // follows Theme brightness) — never hardcoded here.
            final barTheme = Theme.of(context).bottomNavigationBarTheme;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final barBg =
                barTheme.backgroundColor ?? Theme.of(context).cardColor;
            return Container(
              decoration: BoxDecoration(
                color: barBg,
                boxShadow: [
                  BoxShadow(
                    color: isDark ? Colors.black54 : Colors.black.withValues(alpha: 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: BottomNavigationBar(
                type: barTheme.type ?? BottomNavigationBarType.fixed,
                currentIndex: _selectedNavIndex, // 0: Trips, 1: Home, 2: Profile
                onTap: (index) => setState(() => _selectedNavIndex = index),
                selectedItemColor:
                    barTheme.selectedItemColor ?? AppColors.seseGold,
                unselectedItemColor: barTheme.unselectedItemColor,
                backgroundColor: barBg,
                elevation: 0,
                selectedFontSize: 12,
                unselectedFontSize: 12,
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(Icons.history_outlined),
                    activeIcon: Icon(Icons.history),
                    label: 'Trips',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.home_outlined),
                    activeIcon: Icon(Icons.home_rounded),
                    label: 'Home',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.person_outline),
                    activeIcon: Icon(Icons.person_rounded),
                    label: 'Profile',
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Optional verification banner at the top of the Customer View.
///
/// Shown only while `users/{uid}.customerVerificationStatus` is absent or
/// `unverified`, AND the user is not an approved driver. Approved drivers
/// (`drivers/{uid}.verificationStatus == 'approved'`) never see it — their
/// driver KYC already covers customer verification. Dismissible via [X];
/// tapping the banner opens the verification form.
class _VerificationBanner extends StatelessWidget {
  final String userId;
  final bool dismissed;
  final VoidCallback onDismiss;
  final VoidCallback onVerify;

  const _VerificationBanner({
    required this.userId,
    required this.dismissed,
    required this.onDismiss,
    required this.onVerify,
  });

  @override
  Widget build(BuildContext context) {
    if (dismissed) return const SizedBox.shrink();
    FirebaseFirestore? db;
    try {
      db = FirebaseFirestore.instance;
    } catch (_) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bannerBg = isDark
        ? theme.colorScheme.surfaceContainerHighest
        : AppColors.seseGoldLight;
    final textColor = theme.colorScheme.onSurface;
    final iconColor = theme.colorScheme.primary;
    // Promote the nullable handle for use inside the nested builders below.
    final firestoreDb = db;

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: firestoreDb.collection('drivers').doc(userId).snapshots(),
      builder: (context, driverSnapshot) {
        final driverStatus = driverSnapshot.data
                ?.data()?[DriverVerification.fieldStatus]
                ?.toString() ??
            '';
        if (driverStatus == DriverVerification.approved) {
          // Approved driver: driver KYC covers customer verification.
          return const SizedBox.shrink();
        }
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: firestoreDb.collection('users').doc(userId).snapshots(),
          builder: (context, snapshot) {
            final data = snapshot.data?.data();
            if (data == null) return const SizedBox.shrink();
            final status =
                (data[CustomerVerification.fieldStatus] ?? '').toString();
            final verified =
                status == CustomerVerification.verified ||
                    data[CustomerVerification.fieldIsVerified] == true;
            if (verified || status == CustomerVerification.pending) {
              return const SizedBox.shrink();
            }
            return Container(
              key: const Key('customer_verification_banner'),
              width: double.infinity,
              color: bannerBg,
              child: SafeArea(
                top: true,
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Icon(Icons.verified_outlined,
                          color: iconColor, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: GestureDetector(
                          onTap: onVerify,
                          child: Text(
                            'Complete your profile for instant driver matches!',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: textColor,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        key: const Key(
                            'customer_verification_banner_dismiss'),
                        icon: Icon(Icons.close,
                            size: 18, color: textColor),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: onDismiss,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _MultiBookingBanner extends StatefulWidget {
  final List<ActiveTrip> activeTrips;
  final TripRepository? tripRepository;

  const _MultiBookingBanner({
    required this.activeTrips,
    this.tripRepository,
  });

  @override
  State<_MultiBookingBanner> createState() => _MultiBookingBannerState();
}

class _MultiBookingBannerState extends State<_MultiBookingBanner> {
  int _currentPage = 0;
  final _pageController = PageController();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.activeTrips.isEmpty) return const SizedBox.shrink();

    if (widget.activeTrips.length == 1) {
      return _ActiveTripCardBanner(
        trip: widget.activeTrips.first,
        tripRepository: widget.tripRepository,
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          color: Theme.of(context).colorScheme.primaryContainer,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Active Requests (${_currentPage + 1} of ${widget.activeTrips.length})',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
              Row(
                children: List.generate(
                  widget.activeTrips.length,
                  (index) => Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    width: _currentPage == index ? 14 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      color: _currentPage == index
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context)
                              .colorScheme
                              .onPrimaryContainer
                              .withValues(alpha: 0.3),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 68,
          child: PageView.builder(
            controller: _pageController,
            itemCount: widget.activeTrips.length,
            onPageChanged: (idx) => setState(() => _currentPage = idx),
            itemBuilder: (context, index) {
              return _ActiveTripCardBanner(
                trip: widget.activeTrips[index],
                tripRepository: widget.tripRepository,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ActiveTripCardBanner extends StatelessWidget {
  final ActiveTrip trip;
  final TripRepository? tripRepository;

  const _ActiveTripCardBanner({
    required this.trip,
    this.tripRepository,
  });

  bool get _isSearching =>
      trip.status == TripStatus.searchingDriver ||
      trip.status == TripStatus.waitingForAcceptance ||
      trip.status == TripStatus.bidding ||
      trip.status == TripStatus.marketplaceOpen ||
      trip.status == TripStatus.driverPinged;

  @override
  Widget build(BuildContext context) {
    final onPrimary = Theme.of(context).colorScheme.onPrimaryContainer;

    final String statusText;
    if (trip.status == TripStatus.driverAccepted ||
        trip.status == TripStatus.driverArriving) {
      statusText = 'Driver is on the way';
    } else if (trip.status == TripStatus.driverArrived) {
      statusText = 'Driver has arrived';
    } else if (trip.status == TripStatus.inProgress) {
      statusText = 'Trip in progress';
    } else if (trip.status == TripStatus.needsCustomerAction) {
      statusText = 'Action Needed: Boost Fare';
    } else {
      statusText = 'Searching for driver...';
    }

    return Material(
      elevation: 6,
      color: Theme.of(context).colorScheme.primaryContainer,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => LiveTripScreen(
                tripId: trip.tripId,
                repository: tripRepository ?? FirestoreTripRepository(),
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                trip.serviceType == 'send_item' || trip.serviceType == 'receive_item'
                    ? Icons.local_shipping
                    : Icons.directions_car,
                color: onPrimary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        if (_isSearching) ...[
                          const _SearchingRadarIndicator(
                            color: AppColors.seseGold,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            statusText,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: onPrimary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (trip.dropoffAddress.isNotEmpty)
                      Text(
                        'To: ${trip.dropoffAddress}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: onPrimary.withValues(alpha: 0.8),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'View',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: onPrimary,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: onPrimary,
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

class _SearchingRadarIndicator extends StatefulWidget {
  final Color color;

  const _SearchingRadarIndicator({required this.color});

  @override
  State<_SearchingRadarIndicator> createState() =>
      _SearchingRadarIndicatorState();
}

class _SearchingRadarIndicatorState extends State<_SearchingRadarIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color
                .withValues(alpha: 0.3 + (_controller.value * 0.7)),
            boxShadow: [
              BoxShadow(
                color: widget.color
                    .withValues(alpha: 0.4 * _controller.value),
                blurRadius: 6 * _controller.value,
                spreadRadius: 2 * _controller.value,
              ),
            ],
          ),
          child: Center(
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color,
              ),
            ),
          ),
        );
      },
    );
  }
}
