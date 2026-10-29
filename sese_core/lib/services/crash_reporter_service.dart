import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../widgets/global_error_widget.dart';

/// Enterprise silent crash reporting and error recovery service (`CrashReporterService`).
///
/// Hooks into global Flutter error handlers (`FlutterError.onError`,
/// `PlatformDispatcher.instance.onError`, `ErrorWidget.builder`).
/// Captures full stack traces, device context, and user IDs in the background,
/// silently pushing crash reports directly to Firestore collection `crash_reports`
/// for The Hub developer queue — while presenting a clean, reassuring UI to the user.
class CrashReporterService {
  static String _appName = 'sese_app';
  static String _appVersion = '1.0.0';
  static FirebaseFirestore? _customFirestore;

  static String get appName => _appName;
  static String get appVersion => _appVersion;

  /// Initializes global error handlers for [appName] and [appVersion].
  static void initialize({
    required String appName,
    String? appVersion,
    FirebaseFirestore? firestore,
  }) {
    _appName = appName;
    if (appVersion != null && appVersion.isNotEmpty) {
      _appVersion = appVersion;
    }
    if (firestore != null) {
      _customFirestore = firestore;
    }

    // 1. Flutter framework runtime error handler
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      if (kDebugMode) {
        debugPrint('CrashReporterService caught Flutter error in debug mode:');
        originalOnError?.call(details);
      }
      unawaited(recordCrash(
        details.exception,
        details.stack,
        context: 'FlutterError.onError',
      ));
    };

    // 2. Platform dispatcher async / isolate error handler
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      final errStr = error.toString();
      if (errStr.contains('The client has already been terminated') ||
          errStr.contains('!_debugLocked') ||
          errStr.contains('permission-denied') ||
          errStr.contains('PERMISSION_DENIED')) {
        return true; // Ignore transient framework/hot-restart/permission errors
      }
      if (kDebugMode) {
        debugPrint('CrashReporterService caught async platform error: $error');
      }
      unawaited(recordCrash(
        error,
        stack,
        context: 'PlatformDispatcher.onError',
      ));
      return true; // Mark as handled
    };

    // 3. Widget build failure handler
    ErrorWidget.builder = buildErrorWidget;
  }

  /// Builds a clean, reassuring user-facing error widget and logs crash details.
  static Widget buildErrorWidget(FlutterErrorDetails details) {
    final errStr = details.exceptionAsString();
    if (!errStr.contains('!_debugLocked')) {
      debugPrint('CrashReporterService.buildErrorWidget: $errStr');
    }
    unawaited(recordCrash(
      details.exception,
      details.stack,
      context: 'ErrorWidget.builder',
    ));

    return const GlobalErrorWidget();
  }

  /// Silently records a crash report and pushes it to Firestore collection `crash_reports`.
  /// Never throws or crashes the app if logging fails.
  static Future<void> recordCrash(
    Object exception,
    StackTrace? stackTrace, {
    String context = 'unhandled',
    Map<String, dynamic>? extraDetails,
    bool fatal = false,
  }) async {
    try {
      final db = _customFirestore ?? FirebaseFirestore.instance;

      String userId = 'anonymous';
      try {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null && user.uid.isNotEmpty) {
          userId = user.uid;
        }
      } catch (_) {}

      final errorStr = exception.toString();
      if (errorStr.contains('The client has already been terminated') ||
          errorStr.contains('!_debugLocked') ||
          errorStr.contains('permission-denied') ||
          errorStr.contains('PERMISSION_DENIED')) {
        // Filter out transient lifecycle/hot-restart/permission logs to avoid log loops.
        return;
      }
      final sanitizedError = errorStr.length > 500
          ? '${errorStr.substring(0, 500)}... [truncated]'
          : errorStr;

      final stackStr = stackTrace?.toString() ?? '';
      final sanitizedStack = stackStr.length > 4000
          ? '${stackStr.substring(0, 4000)}... [truncated]'
          : stackStr;

      final payload = <String, dynamic>{
        'appName': _appName,
        'appVersion': _appVersion,
        'error': sanitizedError,
        'stackTrace': sanitizedStack,
        'context': context,
        'userId': userId,
        'platform': defaultTargetPlatform.name,
        'status': 'QUEUED',
        'fatal': fatal,
        'timestamp': FieldValue.serverTimestamp(),
        'createdAtIso': DateTime.now().toIso8601String(),
        'extra': ?extraDetails,
      };

      await db
          .collection('crash_reports')
          .add(payload)
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      // Fail silent: crash reporting must NEVER trigger a secondary crash or noisy console logs.
      final err = e.toString();
      if (!err.contains('permission-denied') &&
          !err.contains('PERMISSION_DENIED') &&
          !err.contains('TimeoutException')) {
        debugPrint('CrashReporterService.recordCrash silent error: $e');
      }
    }
  }
}
