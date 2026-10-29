import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Server-driven awareness tooltip data model.
class AwarenessTooltipItem {
  final String id;
  final String title;
  final String description;
  final bool enabled;
  final int maxViews;

  const AwarenessTooltipItem({
    required this.id,
    required this.title,
    required this.description,
    this.enabled = true,
    this.maxViews = 2,
  });

  factory AwarenessTooltipItem.fromMap(String id, Map<String, dynamic> map) {
    return AwarenessTooltipItem(
      id: id,
      title: (map['title'] ?? '').toString(),
      description: (map['description'] ?? '').toString(),
      enabled: map['enabled'] != false,
      maxViews: (map['maxViews'] as num?)?.toInt() ?? 2,
    );
  }

  Map<String, dynamic> toMap() => {
        'title': title,
        'description': description,
        'enabled': enabled,
        'maxViews': maxViews,
      };
}

/// Dynamic server-driven awareness and info tooltip system.
///
/// Features:
/// - Fetches and streams awareness guidance content dynamically from Firestore
///   (`system_configs/awareness_tooltips`) on app startup.
/// - Tracks user taps locally in SharedPreferences for 0ms synchronous UI reads.
/// - Syncs interaction metrics to `users/{uid}/metadata.tooltipViews`.
/// - **Auto-Dismiss Rule**: Permanently hides a specific info icon once the user
///   has opened and viewed its guidance twice (2 times).
/// - Clean reinstalls reset local SharedPreferences, automatically restoring
///   onboarding guidance for the user.
class AwarenessTooltipService extends ChangeNotifier {
  AwarenessTooltipService._();

  /// Global singleton instance.
  static final AwarenessTooltipService instance = AwarenessTooltipService._();

  SharedPreferences? _prefs;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _configSub;
  bool _initialized = false;

  /// Default baseline descriptions loaded while offline or before the first
  /// server sync. The server configuration takes precedence once fetched.
  static const Map<String, ({String title, String description})> _defaultContent = {
    'menu_wallet': (
      title: 'Wallet',
      description: 'Manage funds, top up balance, withdraw to your bank, and view transaction ledger.',
    ),
    'menu_earnings': (
      title: 'Earnings',
      description: 'Track daily, weekly, and monthly trip earnings, commissions, net profit, and streak milestones.',
    ),
    'menu_referral': (
      title: 'Refer & Earn',
      description: 'Share your referral code with friends and drivers to earn lifetime commission bonus coins.',
    ),
    'menu_trips_history': (
      title: 'Trips History',
      description: 'Review complete lifetime trip logs, receipts, routes, and order lifecycle statuses.',
    ),
    'menu_support': (
      title: 'Support',
      description: 'Access 24/7 dedicated support, emergency assistance, safety protocols, and live chat.',
    ),
    'menu_settings': (
      title: 'Settings',
      description: 'Configure vehicle fleet, order sounds, app theme (dark/light), and privacy settings.',
    ),
    'menu_trip_history': (
      title: 'Trip History',
      description: 'Completed trips, parcel delivery details, and ride receipts appear here.',
    ),
    'menu_wallet___payments': (
      title: 'Wallet & Payments',
      description: 'Manage your payment balance, linked debit cards, and transaction history.',
    ),
    'menu_bank___payout_details': (
      title: 'Bank & Payout Details',
      description: 'Link and verify your Nigerian bank account for instant withdrawal settlements.',
    ),
    'sese_coin': (
      title: 'SeSe Coin Balance',
      description: 'Bonus rewards earned from referrals and streaks. 1 SeSe Coin = ₦1, converting to main cash upon reaching threshold.',
    ),
    'wallet_balance': (
      title: 'Wallet Balance',
      description: 'Withdrawable cash balance available for trips, peer transfers, and bank payouts.',
    ),
    'dispatch_mode': (
      title: 'Service Mode',
      description: 'Select Ride-Hailing to book a vehicle, or Package Delivery to send or receive parcels.',
    ),
  };

  Map<String, AwarenessTooltipItem> _serverTooltips = {};

  /// Whether the service has loaded local preferences.
  bool get isInitialized => _initialized;

  /// Initializes the awareness service from local storage and subscribes to Firestore.
  Future<void> initialize({
    FirebaseFirestore? firestore,
    SharedPreferences? preferences,
  }) async {
    try {
      _prefs = preferences ?? await SharedPreferences.getInstance();
      _initialized = true;

      // Populate initial server tooltips from compiled defaults
      for (final entry in _defaultContent.entries) {
        _serverTooltips[entry.key] = AwarenessTooltipItem(
          id: entry.key,
          title: entry.value.title,
          description: entry.value.description,
          enabled: true,
          maxViews: 2,
        );
      }

      // Subscribe to Firestore system_configs/awareness_tooltips for dynamic over-the-air updates
      final db = firestore ?? _resolveFirestore();
      if (db != null) {
        _configSub?.cancel();
        _configSub = db
            .collection('system_configs')
            .doc('awareness_tooltips')
            .snapshots()
            .listen(
          (snap) {
            if (snap.exists && snap.data() != null) {
              final data = snap.data()!;
              final updated = Map<String, AwarenessTooltipItem>.from(_serverTooltips);

              data.forEach((key, val) {
                if (val is Map) {
                  final map = Map<String, dynamic>.from(val);
                  updated[key] = AwarenessTooltipItem.fromMap(key, map);
                }
              });

              _serverTooltips = updated;
              notifyListeners();
            }
          },
          onError: (e) {
            debugPrint('AwarenessTooltipService snapshots error: $e');
          },
        );
      }
    } catch (e) {
      debugPrint('AwarenessTooltipService.initialize error: $e');
    }
  }

  FirebaseFirestore? _resolveFirestore() {
    try {
      return FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  /// Returns how many times the user has opened this specific tooltip section.
  int getViewCount(String tooltipId) {
    return _prefs?.getInt('awareness_view_$tooltipId') ?? 0;
  }

  /// Evaluates whether the info icon for [tooltipId] should be rendered in the UI.
  ///
  /// Permanently returns `false` if the user has viewed this section twice (>= 2),
  /// or if the server configuration has disabled this tooltip.
  bool shouldShow(String tooltipId) {
    final item = _serverTooltips[tooltipId];
    if (item != null && !item.enabled) {
      return false;
    }

    final maxViews = item?.maxViews ?? 2;
    final views = getViewCount(tooltipId);
    return views < maxViews;
  }

  /// Resolves the title and description for a tooltip, prioritizing server data.
  AwarenessTooltipItem getTooltip(
    String tooltipId, {
    String? fallbackTitle,
    String? fallbackDescription,
  }) {
    final serverItem = _serverTooltips[tooltipId];
    if (serverItem != null && serverItem.description.isNotEmpty) {
      return serverItem;
    }

    final defaultEntry = _defaultContent[tooltipId];
    return AwarenessTooltipItem(
      id: tooltipId,
      title: fallbackTitle ?? defaultEntry?.title ?? 'Info',
      description: fallbackDescription ?? defaultEntry?.description ?? '',
    );
  }

  /// Increments the local view count for [tooltipId] and syncs to user metadata in Firestore.
  ///
  /// Triggers [notifyListeners] so UI widgets automatically hide the icon once it hits 2.
  Future<void> recordView(String tooltipId, {String? userId}) async {
    final current = getViewCount(tooltipId);
    final newCount = current + 1;

    try {
      await _prefs?.setInt('awareness_view_$tooltipId', newCount);
    } catch (e) {
      debugPrint('AwarenessTooltipService failed to persist view count: $e');
    }

    notifyListeners();

    // Sync to Firestore user metadata in the background
    if (userId != null && userId.isNotEmpty) {
      try {
        final db = _resolveFirestore();
        if (db != null) {
          unawaited(
            db.collection('users').doc(userId).set({
              'metadata': {
                'tooltipViews': {
                  tooltipId: newCount,
                },
                'lastTooltipViewedAt': FieldValue.serverTimestamp(),
              },
            }, SetOptions(merge: true)),
          );
        }
      } catch (e) {
        debugPrint('AwarenessTooltipService metadata sync error: $e');
      }
    }
  }

  /// Resets all local awareness view counts (useful for testing or profile onboarding restart).
  Future<void> resetAllViews() async {
    final keys = _prefs?.getKeys() ?? {};
    for (final key in keys) {
      if (key.startsWith('awareness_view_')) {
        await _prefs?.remove(key);
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _configSub?.cancel();
    super.dispose();
  }
}
