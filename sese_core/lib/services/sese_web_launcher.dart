import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_theme.dart';
import 'sese_web_error_detector.dart';

/// Secure helper for opening external web links and checking endpoint health (`SeseWebLauncher`).
///
/// Prevents raw Firebase Hosting "Site Not Found" or deployment error pages from
/// launching in external browsers by verifying HTTP endpoint status beforehand.
abstract final class SeseWebLauncher {
  /// Performs an HTTP pre-flight check on an HTTP/HTTPS URL.
  /// Returns `true` if the URL is accessible and not a Firebase Hosting error page.
  static Future<bool> checkUrlHealth(Uri url, {Duration timeout = const Duration(seconds: 4)}) async {
    if (!url.hasScheme || (url.scheme != 'http' && url.scheme != 'https')) {
      return true; // Non-HTTP URIs (tel:, sms:, geo:) are handled by OS
    }

    try {
      // First attempt a fast HEAD request
      final headResp = await http.head(url).timeout(timeout);
      if (headResp.statusCode >= 400) {
        return false;
      }

      // If status is 200, perform quick GET check for HTML body signature if content is HTML
      final contentType = headResp.headers['content-type'] ?? '';
      if (contentType.contains('text/html')) {
        final getResp = await http.get(url).timeout(timeout);
        if (SeseWebErrorDetector.isErrorStatusCode(getResp.statusCode) ||
            SeseWebErrorDetector.isFirebaseHostingPlaceholder(getResp.body, null)) {
          return false;
        }
      }

      return true;
    } catch (e) {
      debugPrint('SeseWebLauncher.checkUrlHealth failed for $url: $e');
      return false;
    }
  }

  /// Safely launches a URL after verifying its health.
  /// If the URL returns 404, 503, or a Firebase Hosting placeholder, presents a branded
  /// error dialog instead of redirecting the user to a raw error page.
  static Future<bool> launchUrlWithGuard(
    BuildContext context,
    Uri url, {
    LaunchMode mode = LaunchMode.externalApplication,
    bool performPreflightCheck = true,
  }) async {
    if (!url.hasScheme) {
      _showErrorDialog(context, 'Invalid web address.');
      return false;
    }

    if (performPreflightCheck && (url.scheme == 'http' || url.scheme == 'https')) {
      final isHealthy = await checkUrlHealth(url);
      if (!isHealthy && context.mounted) {
        _showErrorDialog(
          context,
          'The requested web destination is currently unavailable or under maintenance.',
        );
        return false;
      }
    }

    try {
      if (await canLaunchUrl(url)) {
        return await launchUrl(url, mode: mode);
      } else {
        if (context.mounted) {
          _showErrorDialog(context, 'No application available to handle this link.');
        }
        return false;
      }
    } catch (e) {
      debugPrint('SeseWebLauncher launchUrl exception: $e');
      if (context.mounted) {
        _showErrorDialog(
          context,
          'Unable to open this link. Please check your connection and try again.',
        );
      }
      return false;
    }
  }

  static void _showErrorDialog(BuildContext context, String message) {
    final theme = Theme.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.cloud_off_rounded, color: AppColors.seseGold),
            const SizedBox(width: 10),
            const Text('Link Unavailable'),
          ],
        ),
        content: Text(
          message,
          style: theme.textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
