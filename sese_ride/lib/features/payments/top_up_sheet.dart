import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import 'payment_service.dart';
import 'paystack_checkout_screen.dart';

/// Wallet top-up bottom sheet for any signed-in user.
///
/// Flow: enter amount → backend initializes the Paystack transaction →
/// embedded in-app checkout (card, transfer, USSD without leaving the app)
/// auto-verifies on the Paystack callback and pops `true` when credited.
/// If the embedded page cannot run, it falls back to the browser + manual
/// "I've Paid — Verify" (also auto-verified once when the app resumes).
/// The wallet balance stream updates on success; the sheet reports the
/// outcome by popping `true` (credited) or `false`.
class TopUpSheet extends StatefulWidget {
  final PaymentService service;
  final AppUser user;

  const TopUpSheet({super.key, required this.service, required this.user});

  @override
  State<TopUpSheet> createState() => _TopUpSheetState();
}

class _TopUpSheetState extends State<TopUpSheet> with WidgetsBindingObserver {
  final _amountCtrl = TextEditingController();
  double? _selectedQuick;
  bool _busy = false;
  String? _error;
  FinancialConfig _config = const FinancialConfig();
  bool _configLoaded = false;

  /// Set once the checkout page is open: a single auto-verify on resume.
  PaymentAuthorization? _pending;
  bool _autoVerified = false;

  static const _quickAmounts = [500.0, 1000.0, 2000.0, 5000.0, 10000.0];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    const FinancialConfigService().getConfig().then((c) {
      if (!mounted) return;
      setState(() {
        _config = c;
        _configLoaded = true;
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _amountCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _pending != null &&
        !_autoVerified &&
        !_busy &&
        mounted) {
      _autoVerified = true;
      _verify(pending: _pending!);
    }
  }

  double? get _amount {
    if (_selectedQuick != null) return _selectedQuick;
    return double.tryParse(_amountCtrl.text.replaceAll(',', '').trim());
  }

  Future<void> _start() async {
    final amount = _amount;
    final min = _config.minTopUpAmount;
    if (amount == null || amount < min) {
      setState(() => _error =
          'Minimum top-up amount is ₦${min.toStringAsFixed(0)}.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = await widget.service.initializeTopUp(
        amountNaira: amount,
        email: widget.user.email,
      );
      if (!mounted) return;
      // Embedded checkout first (card/transfer/USSD inside the app).
      final credited = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) =>
              PaystackCheckoutScreen(service: widget.service, auth: auth),
        ),
      );
      if (!mounted) return;
      if (credited == true) {
        Navigator.of(context).pop(true);
        return;
      }
      if (credited == null) {
        // User closed the embedded checkout without paying.
        setState(() => _busy = false);
        return;
      }
      // Embedded page failed — the screen already opened the browser
      // fallback, so keep the manual "I've Paid — Verify" path below.
      final launched =
          await widget.service.launchCheckout(auth.authorizationUrl);
      if (!mounted) return;
      if (!launched) {
        setState(() {
          _busy = false;
          _error = 'Could not open the checkout page. Try again.';
        });
        return;
      }
      setState(() {
        _pending = auth;
        _autoVerified = false;
        _busy = false;
      });
    } on PaymentException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.userMessage;
      });
    }
  }

  Future<void> _verify({required PaymentAuthorization pending}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.verifyTopUp(pending.reference);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Payment verified — wallet updated.')),
      );
    } on PaymentException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.userMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    final min = _config.minTopUpAmount;
    final canProceed = !_busy &&
        _amount != null &&
        _amount! >= min;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.account_balance_wallet_outlined),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Top Up Wallet',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed:
                      _busy ? null : () => Navigator.of(context).pop(false),
                ),
              ],
            ),
            if (pending == null) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final q in _quickAmounts)
                    ChoiceChip(
                      side: BorderSide.none,
                      label: Text('₦${q.toStringAsFixed(0)}'),
                      selected: _selectedQuick == q,
                      onSelected: _busy
                          ? null
                          : (v) => setState(() {
                                _selectedQuick = v ? q : null;
                                _error = null;
                              }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _amountCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Amount (₦)',
                  hintText: 'Min ₦100',
                  prefixText: '₦ ',
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  errorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedErrorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                enabled: !_busy,
                onChanged: (_) => setState(() {
                  _selectedQuick = null;
                  _error = null;
                }),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: TextStyle(
                        color: Colors.red.shade800, fontSize: 12)),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.lock_outline),
                label: Text(_busy ? 'Contacting Paystack…' : 'Pay Securely'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50)),
                onPressed: _busy ? null : _start,
              ),
              const SizedBox(height: 8),
              const Text(
                'Secured by Paystack. Card, transfer, USSD accepted.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ] else ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Checkout is open in your browser. Complete the payment '
                  'there, return here, then verify below.',
                  style: TextStyle(fontSize: 13),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: TextStyle(
                        color: Colors.red.shade800, fontSize: 12)),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.verified_outlined),
                label:
                    Text(_busy ? 'Verifying…' : 'I’ve Paid — Verify'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50)),
                onPressed: _busy ? null : () => _verify(pending: pending),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _pending = null;
                          _error = null;
                        }),
                child: const Text('Change amount'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Opens the top-up flow. Returns true when the wallet was credited.
Future<bool> showTopUpSheet(BuildContext context, PaymentService service,
    AppUser user) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => TopUpSheet(service: service, user: user),
  );
  return result == true;
}
