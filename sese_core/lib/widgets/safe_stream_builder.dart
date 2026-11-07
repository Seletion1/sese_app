import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'sese_shimmer.dart';

/// A production-grade, crash-resilient [StreamBuilder] wrapper that protects
/// against Firestore permission-denied errors, security rule propagation delays,
/// and unhandled nulls.
///
/// Features:
/// 1. Intercepts [FirebaseException] with `permission-denied` or `unauthenticated`
///    and renders a graceful, reassuring state instead of blowing up the widget tree.
/// 2. Supports instant cache hydration via [initialData].
/// 3. Automatically displays a skeleton placeholder ([SeseListSkeleton]) during
///    initial load when [loadingWidget] is omitted.
/// 4. Exposes [FirestoreStreamBuilder] alias for immediate drop-in replacement.
class SafeStreamBuilder<T> extends StatelessWidget {
  /// The asynchronous stream to subscribe to.
  final Stream<T>? stream;

  /// Optional initial cached data to hydrate immediately on frame 1.
  final T? initialData;

  /// Widget builder invoked when valid, non-null data is received.
  final Widget Function(BuildContext context, T data) builder;

  /// Custom loading widget displayed before data arrives.
  /// Defaults to [SeseListSkeleton] if not provided.
  final Widget? loadingWidget;

  /// Custom fallback widget displayed specifically when Firestore rejects
  /// the read with `permission-denied` (e.g. during security rule deployment lags).
  final Widget? permissionDeniedWidget;

  /// Custom error builder for any non-permission-denied exceptions.
  final Widget Function(BuildContext context, Object error, StackTrace? stackTrace)? errorBuilder;

  /// Message displayed when permission-denied occurs and no custom widget is provided.
  final String syncingMessage;

  const SafeStreamBuilder({
    super.key,
    required this.stream,
    required this.builder,
    this.initialData,
    this.loadingWidget,
    this.permissionDeniedWidget,
    this.errorBuilder,
    this.syncingMessage = 'Syncing system configurations...',
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<T>(
      stream: stream,
      initialData: initialData,
      builder: (context, snapshot) {
        // ── 1. Error boundary ────────────────────────────────────────────────
        if (snapshot.hasError) {
          final error = snapshot.error;
          final isPermissionDenied = _isPermissionDenied(error);

          if (kDebugMode) {
            debugPrint('SafeStreamBuilder caught error: $error (isPermissionDenied: $isPermissionDenied)');
          }

          if (isPermissionDenied) {
            return permissionDeniedWidget ?? _buildDefaultSyncingFallback(context);
          }

          if (errorBuilder != null) {
            return errorBuilder!(context, error ?? 'Unknown error', snapshot.stackTrace);
          }

          return _buildDefaultSyncingFallback(context);
        }

        // ── 2. Loading state ─────────────────────────────────────────────────
        if (!snapshot.hasData) {
          return loadingWidget ??
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: SeseListSkeleton(itemCount: 3),
              );
        }

        // ── 3. Data render ───────────────────────────────────────────────────
        final data = snapshot.data;
        if (data == null) {
          return loadingWidget ?? const SizedBox.shrink();
        }

        try {
          return builder(context, data);
        } catch (e, st) {
          if (kDebugMode) {
            debugPrint('SafeStreamBuilder inner build error: $e\n$st');
          }
          return errorBuilder != null
              ? errorBuilder!(context, e, st)
              : _buildDefaultSyncingFallback(context);
        }
      },
    );
  }

  /// Evaluates whether an error represents a Firebase permission or auth rejection.
  static bool _isPermissionDenied(Object? error) {
    if (error == null) return false;
    if (error is FirebaseException) {
      final code = error.code.toLowerCase().trim();
      return code == 'permission-denied' ||
          code == 'permission_denied' ||
          code == 'unauthenticated' ||
          code == 'forbidden';
    }
    final str = error.toString().toLowerCase();
    return str.contains('permission-denied') ||
        str.contains('permission_denied') ||
        str.contains('missing or insufficient permissions') ||
        str.contains('unauthenticated');
  }

  Widget _buildDefaultSyncingFallback(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.0,
                valueColor: AlwaysStoppedAnimation<Color>(
                  theme.primaryColor.withValues(alpha: 0.7),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              syncingMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Convenience alias for Firestore streams.
typedef FirestoreStreamBuilder<T> = SafeStreamBuilder<T>;
