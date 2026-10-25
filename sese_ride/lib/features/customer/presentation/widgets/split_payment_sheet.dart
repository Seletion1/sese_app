import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Result from [SplitPaymentSheet] containing the confirmed split amounts.
class SplitPaymentResult {
  final double senderAmount;
  final double receiverAmount;

  const SplitPaymentResult({
    required this.senderAmount,
    required this.receiverAmount,
  });
}

/// Interactive modal bottom sheet for configuring split payment portions.
///
/// Displays the total trip fare, fetches and checks the sender's current wallet
/// balance, allows entering a custom contribution amount with real-time
/// balance calculation (Total Fare - Sender Amount = Receiver Balance),
/// and validates bounds before returning [SplitPaymentResult].
class SplitPaymentSheet extends StatefulWidget {
  final double totalFare;
  final String userId;
  final double? initialSenderAmount;

  const SplitPaymentSheet({
    super.key,
    required this.totalFare,
    required this.userId,
    this.initialSenderAmount,
  });

  /// Displays the interactive split payment sheet modal.
  static Future<SplitPaymentResult?> show({
    required BuildContext context,
    required double totalFare,
    required String userId,
    double? initialSenderAmount,
  }) {
    return showModalBottomSheet<SplitPaymentResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SplitPaymentSheet(
        totalFare: totalFare,
        userId: userId,
        initialSenderAmount: initialSenderAmount,
      ),
    );
  }

  @override
  State<SplitPaymentSheet> createState() => _SplitPaymentSheetState();
}

class _SplitPaymentSheetState extends State<SplitPaymentSheet> {
  late final TextEditingController _controller;
  double? _walletBalance;
  bool _loadingWallet = true;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    final defaultAmount = widget.initialSenderAmount ?? (widget.totalFare / 2);
    _controller = TextEditingController(
      text: defaultAmount > 0 ? defaultAmount.toStringAsFixed(0) : '',
    );
    _fetchWalletBalance();
    _validate();
  }

  Future<void> _fetchWalletBalance() async {
    if (widget.userId.isEmpty) {
      if (mounted) setState(() => _loadingWallet = false);
      return;
    }
    try {
      final wallet = await const SeseCoinService().fetchWallet(widget.userId);
      if (mounted) {
        setState(() {
          _walletBalance = wallet.mainWalletBalance;
          _loadingWallet = false;
        });
        _validate();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingWallet = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double get _enteredSenderAmount {
    final clean = _controller.text.replaceAll(',', '').trim();
    return double.tryParse(clean) ?? 0.0;
  }

  double get _calculatedReceiverBalance {
    final sender = _enteredSenderAmount;
    final remaining = widget.totalFare - sender;
    return remaining > 0 ? remaining : 0.0;
  }

  void _validate() {
    final amount = _enteredSenderAmount;
    if (amount <= 0) {
      _validationError = 'Enter an amount greater than ₦0.';
    } else if (amount >= widget.totalFare) {
      _validationError =
          'Sender amount cannot equal or exceed total fare. (Choose "Sender Pays" to pay full fare).';
    } else if (_walletBalance != null && amount > _walletBalance!) {
      _validationError =
          'Insufficient wallet balance (₦${_walletBalance!.toStringAsFixed(0)} available). Please enter a lower amount or top up.';
    } else {
      _validationError = null;
    }
  }

  void _setPreset(double ratio) {
    final val = (widget.totalFare * ratio).roundToDouble();
    _controller.text = val.toStringAsFixed(0);
    setState(() {
      _validate();
    });
  }

  void _onConfirm() {
    setState(() => _validate());
    if (_validationError != null) return;

    final sender = _enteredSenderAmount;
    final receiver = widget.totalFare - sender;
    Navigator.of(context).pop(
      SplitPaymentResult(
        senderAmount: sender,
        receiverAmount: receiver,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fareStr = '₦${widget.totalFare.toStringAsFixed(0)}';
    final receiverStr = '₦${_calculatedReceiverBalance.toStringAsFixed(0)}';
    final senderStr = '₦${_enteredSenderAmount.toStringAsFixed(0)}';
    final isValid = _validationError == null && _enteredSenderAmount > 0;

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Title & description
            Row(
              children: [
                Icon(Icons.call_split_rounded, color: cs.primary, size: 24),
                const SizedBox(width: 10),
                const Text(
                  'Split Payment Calculation',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Enter your contribution as the sender. The receiver will pay the remaining balance.',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),

            // Total Fare Display Card
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'TOTAL TRIP FARE',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                      color: Colors.black54,
                    ),
                  ),
                  Text(
                    fareStr,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: cs.primary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Sender Wallet Balance Indicator
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.account_balance_wallet_outlined,
                    size: 18,
                    color: _walletBalance != null && _walletBalance! > 0
                        ? Colors.green.shade700
                        : Colors.orange.shade800,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _loadingWallet
                        ? const Text('Checking wallet balance...',
                            style: TextStyle(fontSize: 12))
                        : Text(
                            _walletBalance != null
                                ? 'Your Wallet Balance: ₦${_walletBalance!.toStringAsFixed(0)}'
                                : 'Wallet check unavailable',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Quick Percentage Presets
            Row(
              children: [
                const Text('Quick split:',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('25%'),
                  selected: false,
                  onSelected: (_) => _setPreset(0.25),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  label: const Text('50% (Half)'),
                  selected: false,
                  onSelected: (_) => _setPreset(0.50),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  label: const Text('75%'),
                  selected: false,
                  onSelected: (_) => _setPreset(0.75),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Custom Amount Input Field
            TextFormField(
              controller: _controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Sender Contribution Amount',
                prefixText: '₦ ',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                errorText: _validationError,
                helperText: 'Deducted directly from your wallet balance.',
              ),
              onChanged: (_) {
                setState(() {
                  _validate();
                });
              },
            ),
            const SizedBox(height: 16),

            // Live Breakdown Confirmation Preview
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Sender Share (You):',
                        style: TextStyle(fontSize: 13),
                      ),
                      Text(
                        senderStr,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Receiver Balance (Drop-off):',
                        style: TextStyle(fontSize: 13),
                      ),
                      Text(
                        receiverStr,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Colors.orange.shade800,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Actions
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: isValid ? _onConfirm : null,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Confirm Split'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
