import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sese_core/sese_core.dart';

import '../payments/payment_service.dart';
import 'transaction_pin_prompt.dart';

/// Wallet-to-wallet transfer sheet.
///
/// Sends wallet value instantly to another SeSe user identified by their
/// registered phone number. The server resolves the recipient, validates
/// sufficiency, and moves the money transactionally — this sheet only
/// collects the inputs and surfaces the server's answer.
class P2pTransferSheet extends StatefulWidget {
  final AppUser user;

  /// Test seam.
  final P2pService? service;

  const P2pTransferSheet({
    super.key,
    required this.user,
    this.service,
  });

  /// Shows the sheet. Returns the recipient's display name on success,
  /// or null if dismissed.
  static Future<String?> show(
    BuildContext context, {
    required AppUser user,
    P2pService? service,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => P2pTransferSheet(user: user, service: service),
    );
  }

  @override
  State<P2pTransferSheet> createState() => _P2pTransferSheetState();
}class _P2pTransferSheetState extends State<P2pTransferSheet> {
  late final P2pService _service = widget.service ?? const P2pService();

  final _phoneCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _lookingUp = false;
  bool _submitting = false;
  int _availableKobo = 0;

  P2pRecipientResult? _lookupResult;
  String? _lookupError;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  int? get _amountKobo {
    final text = _amountCtrl.text.trim().replaceAll(',', '');
    if (text.isEmpty) return null;
    final naira = double.tryParse(text);
    if (naira == null || !naira.isFinite) return null;
    return (naira * 100).round();
  }

  Future<void> _performLookup() async {
    final phone = _phoneCtrl.text.trim();
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 10) {
      setState(() {
        _lookupError = 'Enter a valid registered phone number.';
        _lookupResult = null;
      });
      return;
    }

    setState(() {
      _lookingUp = true;
      _lookupError = null;
      _lookupResult = null;
    });

    try {
      final res = await _service.lookupRecipient(recipientPhone: phone);
      if (!mounted) return;
      setState(() {
        _lookingUp = false;
        _lookupResult = res;
      });
    } on P2pException catch (e) {
      if (!mounted) return;
      setState(() {
        _lookingUp = false;
        _lookupError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lookingUp = false;
        _lookupError = 'Could not lookup phone number. Please try again.';
      });
    }
  }

  Future<void> _submitTransfer() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_lookupResult == null || !_lookupResult!.canReceive) return;

    final kobo = _amountKobo;
    if (kobo == null) return;

    // Step 4: Confirmation dialog before atomic execution
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Transfer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Recipient: ${_lookupResult!.recipientName} (${_lookupResult!.accountType})'),
            const SizedBox(height: 6),
            Text('Amount: ${PaymentService.formatNaira(kobo / 100.0)}'),
            const SizedBox(height: 4),
            MultiCurrencyDisplay.fromKobo(
              amountKobo: kobo,
              targetCurrencyCode: 'USD',
              baseStyle: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            const Text(
              'This transfer will be processed atomically and credited instantly.',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Confirm & Send'),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    if (!mounted) return;

    // Collect the transaction PIN — it travels to the callable, which
    // verifies it server-side before moving anything. Skipping this sheet
    // cannot authorize a transfer: `transferWalletFunds` rejects PIN-less
    // calls on its own.
    final transactionPin = await TransactionPinPrompt.collectPin(
      context,
      uid: widget.user.uid,
    );
    if (transactionPin == null || transactionPin.isEmpty || !mounted) return;

    setState(() => _submitting = true);
    try {
      final name = await _service.transfer(
        recipientPhone: _phoneCtrl.text.trim(),
        amountKobo: kobo,
        transactionPin: transactionPin,
      );
      if (!mounted) return;
      Navigator.of(context).pop(name.isEmpty ? _lookupResult!.recipientName : name);
    } on P2pException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 16px side gutters so fields and the submit bar span edge-to-edge.
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 4,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Icon(Icons.send_to_mobile_outlined),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'P2P Wallet Transfer',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              StreamBuilder<int>(
                stream: PaymentService()
                    .walletBalanceKoboStream(widget.user.uid),
                builder: (context, snap) {
                  _availableKobo = snap.data ?? 0;
                  return Text(
                    'Available Balance: ${PaymentService.formatNaira(_availableKobo / 100.0)}',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  );
                },
              ),
              const SizedBox(height: 16),

              // Step 1: Recipient Phone Lookup
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      key: const Key('p2p_phone_field'),
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: "Step 1: Recipient Phone Number",
                        hintText: '08012345678',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (_) {
                        if (_lookupResult != null || _lookupError != null) {
                          setState(() {
                            _lookupResult = null;
                            _lookupError = null;
                          });
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: _lookingUp ? null : _performLookup,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    ),
                    child: _lookingUp
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Lookup'),
                  ),
                ],
              ),

              if (_lookupError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _lookupError!,
                  style: TextStyle(color: Colors.red.shade800, fontSize: 12),
                ),
              ],

              // Step 2: Verification Check Card
              if (_lookupResult != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _lookupResult!.canReceive
                        ? Colors.green.shade50
                        : Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _lookupResult!.canReceive
                          ? Colors.green.shade300
                          : Colors.orange.shade300,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            _lookupResult!.canReceive
                                ? Icons.verified
                                : Icons.warning_amber_rounded,
                            color: _lookupResult!.canReceive
                                ? Colors.green.shade800
                                : Colors.orange.shade800,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _lookupResult!.recipientName,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 15),
                              softWrap: true,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Chip(
                              label: Text(
                                _lookupResult!.accountType.toUpperCase(),
                                style: const TextStyle(
                                    fontSize: 10, fontWeight: FontWeight.bold),
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (!_lookupResult!.canReceive) ...[
                        Text(
                          _lookupResult!.reason,
                          style: TextStyle(
                            color: Colors.orange.shade900,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ] else ...[
                        Text(
                          'Verified ${_lookupResult!.accountType} account ready to receive transfer.',
                          style: TextStyle(
                            color: Colors.green.shade900,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],

              // Step 3: Enter Amount (Only enabled if lookup passed)
              if (_lookupResult != null && _lookupResult!.canReceive) ...[
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('p2p_amount_field'),
                  controller: _amountCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  decoration: InputDecoration(
                    labelText: 'Step 3: Enter Amount (₦)',
                    hintText: 'Max limit: ₦${_lookupResult!.maxP2pLimitNaira.toStringAsFixed(0)}',
                    prefixText: '₦ ',
                    border: const OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final kobo = _amountKobo;
                    if (kobo == null || kobo <= 0) {
                      return 'Enter an amount greater than zero.';
                    }
                    if (kobo > _availableKobo) {
                      return 'Amount exceeds your available balance.';
                    }
                    final maxKobo = (_lookupResult!.maxP2pLimitNaira * 100).round();
                    if (kobo > maxKobo) {
                      return 'Amount exceeds maximum P2P transfer limit (₦${_lookupResult!.maxP2pLimitNaira.toStringAsFixed(0)}).';
                    }
                    return null;
                  },
                  onChanged: (_) => setState(() {}),
                ),
                if (_amountKobo != null && _amountKobo! > 0) ...[
                  const SizedBox(height: 6),
                  MultiCurrencyDisplay.fromKobo(
                    amountKobo: _amountKobo!,
                    targetCurrencyCode: 'USD',
                    baseStyle: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const Key('p2p_submit_button'),
                  icon: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.send),
                  label: Text(_submitting ? 'Sending…' : 'Step 4: Confirm & Send'),
                  onPressed: _submitting ? null : _submitTransfer,
                ),
              ],

              const SizedBox(height: 12),
              const Text(
                'Instant & atomic. Wallet value is transferred immediately upon confirmation.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
