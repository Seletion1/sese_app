import 'dart:async';
import 'package:flutter/foundation.dart';

/// Helper utility for managing optimistic UI state updates with silent background
/// synchronization, automatic retry, and graceful rollback on failure.
class OptimisticState {
  /// Executes an async network action optimistically.
  ///
  /// - [currentValue]: The current local state.
  /// - [optimisticValue]: The projected UI state to apply synchronously (0ms delay).
  /// - [onUpdate]: Callback invoked immediately with [optimisticValue].
  /// - [action]: The background network operation.
  /// - [onSuccess]: Optional callback executed when [action] completes successfully.
  /// - [onRollback]: Callback executed if [action] throws an error, restoring [currentValue].
  /// - [maxRetries]: Optional retry count before triggering rollback.
  static Future<T?> execute<T, S>({
    required S currentValue,
    required S optimisticValue,
    required ValueChanged<S> onUpdate,
    required Future<T> Function() action,
    ValueChanged<T>? onSuccess,
    required void Function(S previousValue, Object error) onRollback,
    int maxRetries = 1,
  }) async {
    // 1. Immediately apply optimistic UI state (0ms latency)
    onUpdate(optimisticValue);

    int attempts = 0;
    while (true) {
      try {
        attempts++;
        final result = await action();
        onSuccess?.call(result);
        return result;
      } catch (error) {
        debugPrint('Optimistic action attempt $attempts failed: $error');
        if (attempts <= maxRetries) {
          await Future.delayed(Duration(milliseconds: 500 * attempts));
          continue;
        }
        // 2. Roll back local UI state gracefully on failure
        onUpdate(currentValue);
        onRollback(currentValue, error);
        return null;
      }
    }
  }
}
