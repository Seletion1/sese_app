import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'network_status_service.dart';

/// Representation of an optimistically queued trip cancellation.
class QueuedCancellation {
  final String tripId;
  final String? reason;
  final bool useCashSettlement;
  final int timestamp;
  final int attempts;

  const QueuedCancellation({
    required this.tripId,
    this.reason,
    this.useCashSettlement = false,
    required this.timestamp,
    this.attempts = 0,
  });

  Map<String, dynamic> toMap() => {
    'tripId': tripId,
    if (reason != null) 'reason': reason,
    'useCashSettlement': useCashSettlement,
    'timestamp': timestamp,
    'attempts': attempts,
  };

  factory QueuedCancellation.fromMap(Map<String, dynamic> map) => QueuedCancellation(
    tripId: map['tripId'] as String,
    reason: map['reason'] as String?,
    useCashSettlement: map['useCashSettlement'] as bool? ?? false,
    timestamp: map['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
    attempts: map['attempts'] as int? ?? 0,
  );
}

/// Service managing optimistic trip cancellations and background retry synchronization.
///
/// Features:
/// 1. Instant local removal: maintains an in-memory & reactive set of optimistically cancelled
///    trips so customer UI immediately hides cancelled orders without waiting for network round-trip.
/// 2. Persistent queue: persists pending cancellations across app restarts in [SharedPreferences].
/// 3. Auto-drain on reconnect: listens to [NetworkStatusService.onReconnected] to automatically
///    drain and retry queued cancellations when internet connection is restored.
class CancellationQueueService {
  static final CancellationQueueService instance = CancellationQueueService._internal();
  CancellationQueueService._internal();

  static const String _prefsKey = 'sese_pending_trip_cancellations';

  final ValueNotifier<Set<String>> cancelledTripIds = ValueNotifier<Set<String>>({});
  final List<QueuedCancellation> _queue = [];
  bool _isProcessing = false;
  StreamSubscription? _reconnectSubscription;

  /// Function responsible for executing backend cancellation callable.
  Future<void> Function(QueuedCancellation cancellation)? cancellationExecutor;

  /// Initializes the service, restores pending queue from storage, and binds to network reconnection.
  Future<void> init({SharedPreferences? prefsOverride}) async {
    await _loadFromStorage(prefs: prefsOverride);
    _reconnectSubscription?.cancel();
    _reconnectSubscription = NetworkStatusService.instance.onReconnected.listen((_) {
      unawaited(processQueue());
    });
  }

  /// Checks whether a trip has been marked as cancelled (optimistically or confirmed).
  bool isTripCancelled(String tripId) {
    return cancelledTripIds.value.contains(tripId);
  }

  /// Optimistically marks a trip as cancelled in memory so UI hides it instantly.
  void markCancelledLocally(String tripId) {
    final updated = Set<String>.from(cancelledTripIds.value)..add(tripId);
    cancelledTripIds.value = updated;
  }

  /// Enqueues a cancellation request locally and attempts immediate submission if online.
  Future<void> enqueueCancellation({
    required String tripId,
    String? reason,
    bool useCashSettlement = false,
  }) async {
    markCancelledLocally(tripId);

    final req = QueuedCancellation(
      tripId: tripId,
      reason: reason,
      useCashSettlement: useCashSettlement,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    // Deduplicate in queue
    _queue.removeWhere((item) => item.tripId == tripId);
    _queue.add(req);
    await _saveToStorage();

    // Attempt processing immediately if online
    if (NetworkStatusService.instance.isOnline.value) {
      unawaited(processQueue());
    }
  }

  /// Processes all pending cancellations in queue.
  Future<void> processQueue() async {
    if (_isProcessing || _queue.isEmpty) return;
    _isProcessing = true;

    try {
      final pending = List<QueuedCancellation>.from(_queue);
      for (final req in pending) {
        if (cancellationExecutor == null) break;
        try {
          await cancellationExecutor!(req);
          _queue.removeWhere((item) => item.tripId == req.tripId);
          await _saveToStorage();
        } catch (e) {
          debugPrint('Cancellation execution error for ${req.tripId}: $e');
          // If the error indicates trip is already cancelled / closed / not-found,
          // it is safe to remove from queue
          final errStr = e.toString().toLowerCase();
          if (errStr.contains('already') ||
              errStr.contains('closed') ||
              errStr.contains('not-found') ||
              errStr.contains('not found')) {
            _queue.removeWhere((item) => item.tripId == req.tripId);
            await _saveToStorage();
          }
        }
      }
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _loadFromStorage({SharedPreferences? prefs}) async {
    try {
      final p = prefs ?? await SharedPreferences.getInstance();
      final raw = p.getStringList(_prefsKey) ?? [];
      _queue.clear();
      final set = Set<String>.from(cancelledTripIds.value);
      for (final item in raw) {
        try {
          final map = jsonDecode(item) as Map<String, dynamic>;
          final parsed = QueuedCancellation.fromMap(map);
          _queue.add(parsed);
          set.add(parsed.tripId);
        } catch (_) {}
      }
      cancelledTripIds.value = set;
    } catch (e) {
      debugPrint('CancellationQueueService: failed to load storage: $e');
    }
  }

  Future<void> _saveToStorage() async {
    try {
      final p = await SharedPreferences.getInstance();
      final encoded = _queue.map((q) => jsonEncode(q.toMap())).toList();
      await p.setStringList(_prefsKey, encoded);
    } catch (e) {
      debugPrint('CancellationQueueService: failed to save storage: $e');
    }
  }

  /// For testing: retrieves copy of the current queue.
  List<QueuedCancellation> get queuedItems => List.unmodifiable(_queue);

  /// For testing: clears state.
  void clearForTest() {
    _queue.clear();
    cancelledTripIds.value = {};
  }

  void dispose() {
    _reconnectSubscription?.cancel();
    _reconnectSubscription = null;
  }
}
