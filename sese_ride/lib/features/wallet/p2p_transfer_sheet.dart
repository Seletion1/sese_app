import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sese_core/sese_core.dart';

import '../payments/payment_service.dart';

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
}

class _P2pTransferSheetState extends State<P2pTransferSheet> {
  late final P2pService _service = widget.service ?? const P2pService();

  final _phoneCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _submitting = false;
  int _availableKobo = 0;

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

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final kobo = _amountKobo;
    if (kobo == null) return;

    setState(() => _submitting = true);
    try {
      final name = await _service.transfer(
        recipientPhone: _phoneCtrl.text.trim(),
        amountKobo: kobo,
      );
      if (!mounted) return;
      Navigator.of(context).pop(name.isEmpty ? 'recipient' : name);
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
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
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
                      'Send to SeSe User',
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
                    'Available: ${PaymentService.formatNaira(_availableKobo / 100.0)}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  );
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('p2p_phone_field'),
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: "Recipient's phone number",
                  hintText: '08012345678',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final digits =
                      (value ?? '').replaceAll(RegExp(r'\D'), '');
                  if (digits.length < 10) {
                    return 'Enter a valid phone number.';
                  }
                  return null;
                },
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('p2p_amount_field'),
                controller: _amountCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Amount (₦)',
                  prefixText: '₦ ',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final kobo = _amountKobo;
                  if (kobo == null || kobo <= 0) {
                    return 'Enter an amount greater than zero.';
                  }
                  if (kobo > _availableKobo) {
                    return 'Amount exceeds your available balance.';
                  }
                  return null;
                },
                onChanged: (_) => setState(() {}),
              ),
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
                label: Text(_submitting ? 'Sending…' : 'Send Now'),
                onPressed: _submitting ? null : _submit,
              ),
              const SizedBox(height: 8),
              const Text(
                'Instant and irreversible. The money lands in their SeSe '
                'wallet immediately, and you both get a transaction record.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Balance stream shared with the wallet screen's own display.
}
