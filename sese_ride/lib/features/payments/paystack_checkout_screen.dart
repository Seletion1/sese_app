import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'payment_service.dart';

/// Embedded Paystack checkout: card, transfer, and USSD all run inside an
/// in-app WebView — the system browser is never opened unless explicitly requested.
///
/// Flow: loads the server-issued [auth] authorization URL, watches
/// navigations for Paystack's `reference`/`trxref` callback params, then
/// verifies server-side and pops `true` (credited) or `false`.
/// Equipped with [SeseWebErrorDetector] to catch 404, 503, or default Firebase
/// Hosting placeholder pages ("Site Not Found") and display [SeseWebErrorWidget].
class PaystackCheckoutScreen extends StatefulWidget {
  final PaymentService service;
  final PaymentAuthorization auth;

  const PaystackCheckoutScreen({
    super.key,
    required this.service,
    required this.auth,
  });

  @override
  State<PaystackCheckoutScreen> createState() => _PaystackCheckoutScreenState();
}

class _PaystackCheckoutScreenState extends State<PaystackCheckoutScreen> {
  late final WebViewController _controller;
  bool _loadingPage = true;
  bool _verifying = false;
  bool _webViewFailed = false;
  String? _error;
  String? _webViewErrorDetails;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                _loadingPage = true;
                _webViewFailed = false;
                _webViewErrorDetails = null;
              });
            }
          },
          onPageFinished: (url) async {
            if (!mounted) return;
            setState(() => _loadingPage = false);

            // Evaluate title and body to catch raw Firebase Hosting "Site Not Found" pages
            try {
              final title = await _controller.getTitle();
              final bodyText = await _controller.runJavaScriptReturningResult(
                "document.body ? document.body.innerText : ''",
              );

              if (SeseWebErrorDetector.isFirebaseHostingPlaceholder(
                bodyText.toString(),
                title,
              )) {
                debugPrint('PaystackCheckout: Intercepted Firebase Hosting placeholder ($url)');
                if (mounted && !_verifying) {
                  setState(() {
                    _webViewFailed = true;
                    _webViewErrorDetails = SeseWebErrorDetector.getCleanUserErrorMessage(
                      isFirebasePlaceholder: true,
                    );
                  });
                }
              }
            } catch (e) {
              debugPrint('PaystackCheckout: JS evaluation note: $e');
            }
          },
          onHttpError: (HttpResponseError err) {
            final statusCode = err.response?.statusCode;
            debugPrint('PaystackCheckout: HTTP status error: $statusCode');
            if (mounted && !_verifying && statusCode != null && SeseWebErrorDetector.isErrorStatusCode(statusCode)) {
              setState(() {
                _webViewFailed = true;
                _webViewErrorDetails = SeseWebErrorDetector.getCleanUserErrorMessage(
                  statusCode: statusCode,
                );
              });
            }
          },
          onWebResourceError: (err) {
            debugPrint(
              'PaystackCheckout: web resource error '
              'code=${err.errorCode} type=${err.errorType} '
              'url=${err.url} desc=${err.description}',
            );
            if (mounted && !_verifying && err.isForMainFrame == true) {
              setState(() {
                _webViewFailed = true;
                _webViewErrorDetails = SeseWebErrorDetector.getCleanUserErrorMessage(
                  originalError: err.description.isNotEmpty ? err.description : null,
                );
              });
            }
          },
          onNavigationRequest: (request) {
            final ref = _callbackReference(request.url);
            if (ref != null && !_verifying) {
              _verifyAndClose(ref);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.auth.authorizationUrl));
  }

  /// Paystack redirects to the dashboard callback URL with the transaction
  /// reference as `reference` (or legacy `trxref`) once card/transfer/USSD
  /// completes. Only accept it when it matches our initialized reference —
  /// anything else keeps navigating inside the WebView.
  String? _callbackReference(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final ref = uri.queryParameters['reference'] ??
        uri.queryParameters['trxref'] ??
        uri.queryParameters['Reference'];
    if (ref == null || ref.isEmpty) return null;
    if (ref == widget.auth.reference) return ref;
    return null;
  }

  Future<void> _verifyAndClose(String reference) async {
    if (_verifying) return;
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      await widget.service.verifyTopUp(reference);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Payment verified — wallet updated.')),
      );
    } on PaymentException catch (e) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _error = e.userMessage;
      });
    }
  }

  /// WebView unusable: pop `false` so the caller runs the single
  /// browser-fallback launch + manual verification path.
  Future<void> _openInBrowser() async {
    if (!mounted) return;
    Navigator.of(context).pop(false);
  }

  Future<void> _retry() async {
    if (!mounted) return;
    setState(() {
      _webViewFailed = false;
      _webViewErrorDetails = null;
      _loadingPage = true;
    });
    try {
      await _controller.loadRequest(Uri.parse(widget.auth.authorizationUrl));
    } catch (e) {
      debugPrint('PaystackCheckout: reload failed: $e');
      if (mounted) {
        setState(() {
          _webViewFailed = true;
          _webViewErrorDetails = 'Could not load the checkout page.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Secure Checkout'),
        actions: [
          TextButton(
            onPressed: _verifying ? null : _openInBrowser,
            child: const Text('Browser'),
          ),
        ],
      ),
      body: Stack(
        children: [
          if (!_webViewFailed)
            WebViewWidget(key: const Key('paystack_webview'), controller: _controller),
          if (_loadingPage && !_webViewFailed)
            const Center(child: CircularProgressIndicator()),
          if (_verifying)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 12),
                    Text('Verifying payment…', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
          if (_webViewFailed && !_verifying)
            SeseWebErrorWidget(
              isEmbedded: true,
              title: 'Checkout Unavailable',
              errorMessage: _webViewErrorDetails ??
                  'The secure checkout page could not be loaded right now.',
              onRetry: _retry,
              onGoBack: () => Navigator.of(context).pop(false),
              onOpenInBrowser: _openInBrowser,
            ),
          if (_error != null && !_verifying && !_webViewFailed)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: Material(
                color: Colors.red.shade700,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
