import 'dart:async';
import 'package:flutter/foundation.dart';

import 'network_status_service.dart';

/// Production network resilience utility for wrapping asynchronous operations
/// with defensive timeouts and automatic reachability awareness.
abstract final class NetworkTimeoutHelper {
  /// Default timeout for interactive network calls (8 seconds).
  static const Duration defaultTimeout = Duration(seconds: 8);

  /// Executes [action] with a bounded [timeout].
  ///
  /// If the operation times out:
  /// 1. Triggers background network reachability check to update the top status banner.
  /// 2. If [fallback] is provided, returns [fallback] instead of throwing.
  /// 3. Otherwise rethrows a descriptive [TimeoutException].
  static Future<T> withTimeout<T>(
    Future<T> Function() action, {
    Duration timeout = defaultTimeout,
    T? fallback,
    String operationName = 'Network operation',
  }) async {
    try {
      return await action().timeout(timeout);
    } on TimeoutException {
      if (kDebugMode) {
        debugPrint('NetworkTimeoutHelper: $operationName timed out after ${timeout.inSeconds}s.');
      }
      // Probe reachability in the background to update the top warning banner
      unawaited(NetworkStatusService.instance.checkConnectivity());

      if (fallback != null) {
        return fallback;
      }
      throw TimeoutException('$operationName timed out after ${timeout.inSeconds}s.');
    } catch (e) {
      if (e is TimeoutException) {
        unawaited(NetworkStatusService.instance.checkConnectivity());
      }
      rethrow;
    }
  }
}
