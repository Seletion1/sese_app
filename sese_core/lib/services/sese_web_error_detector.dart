
/// Centralized utility for detecting web resource errors, HTTP error status codes,
/// and Firebase Hosting "Site Not Found" / deployment error placeholder pages.
abstract final class SeseWebErrorDetector {
  /// Signatures present in default Firebase Hosting placeholder pages ("Site Not Found").
  static const List<String> _firebaseHostingSignatures = [
    'site not found',
    'why am i seeing this?',
    'there are a few potential reasons',
    "you haven't deployed an app yet",
    'you may have deployed an empty directory',
    "we haven't finished setting it up yet",
    'how can i deploy my first app?',
    'hosting documentation',
    'firebase hosting',
  ];

  /// Checks if an HTTP status code indicates a failure (4xx or 5xx status code).
  static bool isErrorStatusCode(int statusCode) {
    return statusCode >= 400;
  }

  /// Checks if raw HTML content or page title matches Firebase Hosting's default
  /// "Site Not Found" or deployment placeholder error page.
  static bool isFirebaseHostingPlaceholder(String? htmlBody, String? pageTitle) {
    final title = (pageTitle ?? '').trim().toLowerCase();
    final body = (htmlBody ?? '').trim().toLowerCase();

    // Direct title checks
    if (title.contains('site not found') ||
        title.contains('404 not found') ||
        title.contains('503 service unavailable') ||
        title.contains('firebase hosting')) {
      return true;
    }

    // Match signature keywords inside body or title
    int matchCount = 0;
    for (final sig in _firebaseHostingSignatures) {
      if (body.contains(sig) || title.contains(sig)) {
        matchCount++;
        // If "site not found" or "you haven't deployed an app yet" matches, trigger immediately
        if (sig == 'site not found' || sig == "you haven't deployed an app yet") {
          return true;
        }
      }
    }

    // Require at least 2 signature hits if it's generic text
    return matchCount >= 2;
  }

  /// Evaluates an error and returns a clean, reassuring user-facing string.
  /// Guarantees raw Firebase setup instructions or stack traces are never exposed.
  static String getCleanUserErrorMessage({
    int? statusCode,
    String? originalError,
    bool isFirebasePlaceholder = false,
  }) {
    if (isFirebasePlaceholder) {
      return 'The requested web service is currently unavailable. Please try again later.';
    }

    if (statusCode != null) {
      if (statusCode == 404) {
        return 'The web page could not be found (404). Please try again or go back.';
      } else if (statusCode == 503 || statusCode == 502 || statusCode == 500) {
        return 'The service is temporarily down for maintenance (HTTP $statusCode). Please try again soon.';
      } else if (statusCode >= 400 && statusCode < 500) {
        return 'Unable to access the web resource (HTTP $statusCode).';
      } else if (statusCode >= 500) {
        return 'A server error occurred (HTTP $statusCode). Please try again later.';
      }
    }

    if (originalError != null && originalError.isNotEmpty) {
      final lower = originalError.toLowerCase();
      if (lower.contains('net::err_internet_disconnected') ||
          lower.contains('no internet') ||
          lower.contains('network_failed') ||
          lower.contains('host_lookup_failed')) {
        return 'No internet connection. Please check your network and try again.';
      }
      if (lower.contains('timed_out') || lower.contains('timeout')) {
        return 'The connection timed out. Please check your network and retry.';
      }
    }

    return 'Unable to load web resource. Please try again or go back.';
  }
}
