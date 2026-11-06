import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/sese_web_error_detector.dart';
import 'sese_web_error_widget.dart';

/// Production-grade protected WebView widget (`SeseWebViewWidget`).
///
/// Wraps `webview_flutter`'s [WebViewWidget] with automated HTTP error interceptors,
/// network error listeners, and DOM signature inspectors to ensure raw Firebase
/// Hosting "Site Not Found" or deployment error pages never render.
class SeseWebViewWidget extends StatefulWidget {
  final String initialUrl;
  final String? appBarTitle;
  final Set<String>? allowedDomains;
  final NavigationDecision Function(NavigationRequest request)? onNavigationRequest;
  final void Function(String url)? onPageFinished;
  final VoidCallback? onGoBack;
  final VoidCallback? onOpenInExternalBrowser;

  const SeseWebViewWidget({
    super.key,
    required this.initialUrl,
    this.appBarTitle,
    this.allowedDomains,
    this.onNavigationRequest,
    this.onPageFinished,
    this.onGoBack,
    this.onOpenInExternalBrowser,
  });

  @override
  State<SeseWebViewWidget> createState() => _SeseWebViewWidgetState();
}

class _SeseWebViewWidgetState extends State<SeseWebViewWidget> {
  late final WebViewController _controller;
  bool _isLoading = true;
  bool _hasError = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  void _initController() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                _isLoading = true;
                _hasError = false;
                _errorMessage = null;
              });
            }
          },
          onPageFinished: (url) async {
            if (!mounted) return;
            setState(() => _isLoading = false);

            // Run JS DOM signature check to catch Firebase Hosting "Site Not Found" pages
            try {
              final title = await _controller.getTitle();
              final bodyText = await _controller.runJavaScriptReturningResult(
                "document.body ? document.body.innerText : ''",
              );

              final bodyString = bodyText.toString();
              if (SeseWebErrorDetector.isFirebaseHostingPlaceholder(bodyString, title)) {
                debugPrint(
                  'SeseWebViewWidget: Intercepted Firebase Hosting placeholder page ($url)',
                );
                if (mounted) {
                  setState(() {
                    _hasError = true;
                    _errorMessage = SeseWebErrorDetector.getCleanUserErrorMessage(
                      isFirebasePlaceholder: true,
                    );
                  });
                }
                return;
              }
            } catch (e) {
              debugPrint('SeseWebViewWidget: JS title/body evaluation note: $e');
            }

            widget.onPageFinished?.call(url);
          },
          onHttpError: (HttpResponseError error) {
            final statusCode = error.response?.statusCode;
            debugPrint('SeseWebViewWidget: HTTP error statusCode=$statusCode');
            if (statusCode != null && SeseWebErrorDetector.isErrorStatusCode(statusCode)) {
              if (mounted) {
                setState(() {
                  _hasError = true;
                  _errorMessage = SeseWebErrorDetector.getCleanUserErrorMessage(
                    statusCode: statusCode,
                  );
                });
              }
            }
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint(
              'SeseWebViewWidget: WebResourceError code=${error.errorCode} '
              'desc=${error.description} isMainFrame=${error.isForMainFrame}',
            );
            if (mounted && error.isForMainFrame == true) {
              setState(() {
                _hasError = true;
                _errorMessage = SeseWebErrorDetector.getCleanUserErrorMessage(
                  originalError: error.description,
                );
              });
            }
          },
          onNavigationRequest: (request) {
            if (widget.onNavigationRequest != null) {
              final decision = widget.onNavigationRequest!(request);
              if (decision == NavigationDecision.prevent) {
                return NavigationDecision.prevent;
              }
            }
            if (!_isHostAllowed(request.url)) {
              debugPrint('SeseWebViewWidget: Blocked navigation to unpermitted host: ${request.url}');
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );

    _loadUrl();
  }

  static const Set<String> _defaultAllowedDomains = {
    'paystack.co',
    'paystack.com',
    'firebaseapp.com',
    'web.app',
    'sese.app',
    'sese.com',
    'sese.ng',
    'google.com',
    'accounts.google.com',
    'mycover.ai',
    'octamile.com',
  };

  bool _isHostAllowed(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority) return false;
    // Enforce HTTPS for remote webview loads to prevent plain-text intercept/injection.
    if (uri.scheme != 'https' && uri.host != 'localhost' && uri.host != '127.0.0.1') return false;
    final host = uri.host.toLowerCase();
    final allowed = widget.allowedDomains ?? _defaultAllowedDomains;
    return allowed.any((domain) => host == domain || host.endsWith('.$domain'));
  }

  Future<void> _loadUrl() async {
    final uri = Uri.tryParse(widget.initialUrl);
    if (uri == null || !uri.hasScheme || !_isHostAllowed(widget.initialUrl)) {
      if (mounted) {
        setState(() {
          _hasError = true;
          _isLoading = false;
          _errorMessage = uri != null && !_isHostAllowed(widget.initialUrl)
              ? 'Access denied: domain (${uri.host}) is not permitted.'
              : 'Invalid web address (URL).';
        });
      }
      return;
    }

    try {
      await _controller.loadRequest(uri);
    } catch (e) {
      debugPrint('SeseWebViewWidget load error: $e');
      if (mounted) {
        setState(() {
          _hasError = true;
          _isLoading = false;
          _errorMessage = SeseWebErrorDetector.getCleanUserErrorMessage(
            originalError: e.toString(),
          );
        });
      }
    }
  }

  void _retry() {
    setState(() {
      _hasError = false;
      _isLoading = true;
      _errorMessage = null;
    });
    _loadUrl();
  }

  void _handleGoBack() {
    if (widget.onGoBack != null) {
      widget.onGoBack!();
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.appBarTitle != null
          ? AppBar(
              title: Text(widget.appBarTitle!),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _handleGoBack,
              ),
            )
          : null,
      body: Stack(
        children: [
          if (!_hasError)
            WebViewWidget(
              key: const Key('sese_guarded_webview'),
              controller: _controller,
            ),
          if (_isLoading && !_hasError)
            const Center(
              child: CircularProgressIndicator(),
            ),
          if (_hasError)
            SeseWebErrorWidget(
              isEmbedded: true,
              errorMessage: _errorMessage,
              onRetry: _retry,
              onGoBack: _handleGoBack,
              onOpenInBrowser: widget.onOpenInExternalBrowser,
            ),
        ],
      ),
    );
  }
}
