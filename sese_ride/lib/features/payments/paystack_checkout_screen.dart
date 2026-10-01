import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'payment_service.dart';

/// Embedded Paystack checkout: card, transfer, and USSD all run inside an
/// in-app WebView — the system browser is never opened.
///
/// Flow: loads the server-issued [auth] authorization URL, watches
/// navigations for Paystack's `reference`/`trxref` callback params, then
/// verifies server-side and pops `true` (credited) or `false`.
/// A fallback "open in browser" action keeps [PaymentService.launchCheckout]
/// for WebView failures; verification stays manual in that path.
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

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loadingPage = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loadingPage = false);
          },
          onWebResourceError: (_) {
            if (mounted && !_verifying) {
              setState(() => _webViewFailed = true);
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
                    Text('Verifying payment…',
                        style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
          if (_error != null && !_verifying)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: Material(
                color: Colors.red.shade700,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
