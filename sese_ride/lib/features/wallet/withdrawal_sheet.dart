import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sese_core/sese_core.dart';

import '../payments/payment_service.dart';
import 'transaction_pin_prompt.dart';

/// Direct Paystack withdrawal sheet.
///
/// Replaces the old "Request via Support" modal. The user picks an amount,
/// bank, and account; the account holder name is resolved and confirmed; the
/// request goes to `processWalletWithdrawal`, which is the only component that
/// debits the wallet.
///
/// Money rule: nothing here computes a payable amount. [availableKobo] is a
/// server-owned balance, and the server re-validates every amount it receives.
class WithdrawalSheet extends StatefulWidget {
  final AppUser user;

  /// Test seam.
  final WithdrawalService? service;

  /// Posted when a request is accepted, for the caller to show a confirmation.
  final void Function(PayoutRequest request)? onSubmitted;

  const WithdrawalSheet({
    super.key,
    required this.user,
    this.service,
    this.onSubmitted,
  });

  /// Shows the sheet. Returns the accepted request, or null if dismissed.
  static Future<PayoutRequest?> show(
    BuildContext context, {
    required AppUser user,
    WithdrawalService? service,
  }) {
    return showModalBottomSheet<PayoutRequest>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => WithdrawalSheet(user: user, service: service),
    );
  }

  @override
  State<WithdrawalSheet> createState() => _WithdrawalSheetState();
}

/// Alias for [WithdrawalSheet] matching alternate prompt nomenclature.
typedef WithdrawalBottomSheet = WithdrawalSheet;

class _WithdrawalSheetState extends State<WithdrawalSheet> {
  late final WithdrawalService _service =
      widget.service ?? const WithdrawalService();

  final _amountCtrl = TextEditingController();
  final _accountCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  List<BankInfo> _banks = BankService.defaultNigerianBanks;
  bool _loadingBanks = false;
  String? _bankCode;
  String? _bankName;

  /// Holder name resolved by the server for the entered account.
  String? _resolvedName;
  bool _verifying = false;
  String? _accountError;

  bool _submitting = false;
  int _availableKobo = 0;

  @override
  void initState() {
    super.initState();
    _loadBanks();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _accountCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBanks() async {
    final banks = await _service.fetchBanks();
    if (!mounted) return;
    setState(() {
      _banks = banks;
      _loadingBanks = false;
    });
  }

  /// Debounce guard so a 10-digit paste does not fire ten Paystack lookups.
  String? _lastVerifiedAccount;
  Future<void> _maybeVerifyAccount(String value) async {
    final account = value.trim();
    setState(() {
      _accountError = null;
      _resolvedName = null;
    });
    if (account.length != 10 || _bankCode == null) return;
    if (_lastVerifiedAccount == '$account|$_bankCode') return;
    _lastVerifiedAccount = '$account|$_bankCode';

    setState(() => _verifying = true);
    final name = await _service.resolveAccountName(
      bankCode: _bankCode!,
      accountNumber: account,
    );
    if (!mounted) return;
    setState(() {
      _verifying = false;
      if (name == null) {
        _resolvedName = null;
        _accountError = 'Could not verify that account. Check the number.';
      } else {
        _resolvedName = name;
      }
    });
  }

  int? get _amountKobo {
    final text = _amountCtrl.text.trim().replaceAll(',', '');
    if (text.isEmpty) return null;
    final naira = double.tryParse(text);
    if (naira == null || !naira.isFinite) return null;
    return (naira * 100).round();
  }

  bool get _canSubmit {
    final kobo = _amountKobo;
    final nameValid = _resolvedName != null &&
        (widget.user.fullName.trim().isEmpty ||
            namesLooselyMatch(widget.user.fullName, _resolvedName!));
    return !_submitting &&
        !_verifying &&
        kobo != null &&
        kobo > 0 &&
        kobo <= _availableKobo &&
        _bankCode != null &&
        _accountCtrl.text.trim().length == 10 &&
        nameValid;
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final kobo = _amountKobo;
    if (kobo == null) return;

    // Collect the transaction PIN — verified server-side inside
    // `processWalletWithdrawal` before any debit. See the P2P sheet.
    final transactionPin = await TransactionPinPrompt.collectPin(
      context,
      uid: widget.user.uid,
    );
    if (transactionPin == null || transactionPin.isEmpty || !mounted) return;

    setState(() => _submitting = true);
    try {
      final request = await _service.requestWithdrawal(
        uid: widget.user.uid,
        amountKobo: kobo,
        bankCode: _bankCode!,
        accountNumber: _accountCtrl.text.trim(),
        transactionPin: transactionPin,
      );
      if (!mounted) return;
      Navigator.of(context).pop(request);
      widget.onSubmitted?.call(request);
    } on WithdrawalException catch (e) {
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
        // Lift the form above the soft keyboard.
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
                  Icon(Icons.account_balance_outlined),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Withdraw / Payout',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              StreamBuilder<int>(
                stream: _service.availableKoboStream(widget.user.uid),
                builder: (context, snap) {
                  _availableKobo = snap.data ?? 0;
                  return Text(
                    'Available: ${PaymentService.formatNaira(_availableKobo / 100.0)}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  );
                },
              ),
              if (_availableKobo <= 0)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Insufficient balance for withdrawal.',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('withdrawal_amount_field'),
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
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('withdrawal_bank_field'),
                initialValue: _bankCode,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Select Bank',
                  border: OutlineInputBorder(),
                ),
                items: _banks.isEmpty && !_loadingBanks
                    ? const []
                    : _banks
                        .map((b) => DropdownMenuItem(
                              value: b.code,
                              child: Text(b.name,
                                  overflow: TextOverflow.ellipsis),
                            ))
                        .toList(),
                onChanged: _loadingBanks
                    ? null
                    : (code) {
                        setState(() {
                          _bankCode = code;
                          _bankName = _banks
                              .where((b) => b.code == code)
                              .map((b) => b.name)
                              .firstOrNull;
                          // Account verification is bank-specific.
                          _resolvedName = null;
                          _lastVerifiedAccount = null;
                        });
                        _maybeVerifyAccount(_accountCtrl.text);
                      },
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('withdrawal_account_field'),
                controller: _accountCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(10),
                ],
                decoration: InputDecoration(
                  labelText: 'Account Number',
                  border: const OutlineInputBorder(),
                  suffixIcon: _verifying
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : (_resolvedName != null
                          ? const Icon(Icons.check_circle, color: Colors.green)
                          : null),
                ),
                validator: (value) {
                  if (value == null || value.trim().length != 10) {
                    return 'Enter your 10-digit account number.';
                  }
                  if (_bankCode == null) return 'Select your bank first.';
                  if (_resolvedName == null) {
                    return _accountError ?? 'Verify your account to continue.';
                  }
                  return null;
                },
                onChanged: (v) {
                  setState(() {});
                  _maybeVerifyAccount(v);
                },
              ),
              if (_resolvedName != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.verified_user,
                        size: 16, color: Colors.green),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                      _bankName == null
                          ? 'Account name: $_resolvedName'
                          : '$_bankName — account name: $_resolvedName',
                      key: const Key('withdrawal_resolved_name'),
                      style:
                          const TextStyle(fontSize: 13, color: Colors.green),
                    ),
                    ),
                  ],
                ),
                // Advisory only: the server re-verifies this. It surfaces an
                // obvious mistake early without pretending to be a gate.
                if (!namesLooselyMatch(widget.user.fullName, _resolvedName!))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'This name differs from your profile '
                      '(${widget.user.fullName}). Withdrawals can only be made '
                      'to an account in your own name.',
                      key: const Key('withdrawal_name_mismatch_warning'),
                      style: const TextStyle(
                          fontSize: 12, color: Colors.orange),
                    ),
                  ),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('withdrawal_submit_button'),
                icon: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send),
                label: Text(
                    _submitting ? 'Processing…' : 'Request Withdrawal'),
                onPressed: _canSubmit ? _submit : null,
              ),
              const SizedBox(height: 8),
              const Text(
                'Funds are sent to your bank account. Your balance is reduced '
                'immediately and refunded automatically if the transfer fails.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
