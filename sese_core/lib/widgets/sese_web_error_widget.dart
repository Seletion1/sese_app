import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Branded in-app error state widget (`SeseWebErrorWidget`).
///
/// Replaces raw Firebase Hosting "Site Not Found" placeholder pages, 404/503 HTTP
/// errors, or network connection failures with a clean, branded card matching
/// SESE design tokens.
class SeseWebErrorWidget extends StatelessWidget {
  final VoidCallback? onRetry;
  final VoidCallback? onGoBack;
  final VoidCallback? onOpenInBrowser;
  final String? title;
  final String? errorMessage;
  final bool isEmbedded;

  const SeseWebErrorWidget({
    super.key,
    this.onRetry,
    this.onGoBack,
    this.onOpenInBrowser,
    this.title,
    this.errorMessage,
    this.isEmbedded = false,
  });

  static const Color _seseGold = AppColors.seseGold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;

    final content = Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 440),
          padding: const EdgeInsets.all(24.0),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: _seseGold.withValues(alpha: 0.35),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Branded Icon
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _seseGold.withValues(alpha: 0.15),
                  border: Border.all(
                    color: _seseGold.withValues(alpha: 0.4),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: _seseGold.withValues(alpha: 0.2),
                      blurRadius: 12,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.cloud_off_rounded,
                  size: 38,
                  color: _seseGold,
                ),
              ),
              const SizedBox(height: 20),

              // Title
              Text(
                title ?? 'Web Service Unavailable',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  fontSize: 19,
                  letterSpacing: -0.3,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),

              // Reassuring user message
              Text(
                errorMessage ??
                    'We could not load this web page right now. Please check your network connection or try again later.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 14,
                  color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.8),
                  height: 1.45,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              // Action buttons
              if (onRetry != null) ...[
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    key: const Key('sese_web_error_retry_btn'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _seseGold,
                      foregroundColor: Colors.black,
                      elevation: 1,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    label: const Text(
                      'Retry',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],

              if (onGoBack != null) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: OutlinedButton.icon(
                    key: const Key('sese_web_error_back_btn'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.textTheme.bodyMedium?.color,
                      side: BorderSide(
                        color: theme.dividerColor.withValues(alpha: 0.5),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: onGoBack,
                    icon: const Icon(Icons.arrow_back_rounded, size: 18),
                    label: const Text(
                      'Go Back',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],

              if (onOpenInBrowser != null) ...[
                const SizedBox(height: 6),
                TextButton.icon(
                  key: const Key('sese_web_error_browser_btn'),
                  style: TextButton.styleFrom(
                    foregroundColor: _seseGold,
                  ),
                  onPressed: onOpenInBrowser,
                  icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                  label: const Text(
                    'Open in External Browser',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    if (isEmbedded) {
      return content;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Web Content'),
        leading: onGoBack != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: onGoBack,
              )
            : null,
      ),
      body: SafeArea(child: content),
    );
  }
}
