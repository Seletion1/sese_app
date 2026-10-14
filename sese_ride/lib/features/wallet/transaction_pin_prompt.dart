import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sese_core/sese_core.dart';

/// Just-In-Time Transaction PIN collection modal.
///
/// Zero-trust contract: this prompt NEVER verifies the PIN itself and never
/// touches stored PIN material. It only COLLECTS the digits and hands them
/// back so the caller can pass them to a money callable's `transactionPin`
/// field — the server compares against the salted hash and enforces the
/// attempt lockout there. A hostile client skipping this sheet gains
/// nothing: the callable rejects a missing/wrong PIN independently.
///
/// - No PIN on record → setup sheet (enter twice), created server-side via
///   `setTransactionPin`, then the fresh PIN is returned.
/// - PIN exists → verify sheet (pre-flight server check for immediate
///   wrong-PIN feedback), then the entered PIN is returned. The money
///   callable re-verifies it — this pre-check authorizes nothing.
///
/// Returns the PIN string, or null when dismissed/aborted.
abstract final class TransactionPinPrompt {
  static Future<String?> collectPin(
    BuildContext context, {
    required String uid,
    TransactionPinService? service,
  }) async {
    final svc = service ?? const TransactionPinService();
    bool hasPin = false;
    try {
      hasPin = await svc.hasPin(uid);
    } catch (_) {
      // Fail-closed to verify mode: the server arbitrates anyway.
    }

    if (!context.mounted) return null;
    return await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => hasPin
          ? _CollectPinSheet(service: svc)
          : _SetupPinSheet(uid: uid, service: svc),
    );
  }
}

class _SetupPinSheet extends StatefulWidget {
  final String uid;
  final TransactionPinService service;

  const _SetupPinSheet({required this.uid, required this.service});

  @override
  State<_SetupPinSheet> createState() => _SetupPinSheetState();
}

class _SetupPinSheetState extends State<_SetupPinSheet> {
  final _pinCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _pinCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _pinCtrl.text.trim();
    final confirm = _confirmCtrl.text.trim();

    if (pin.length != 4) {
      setState(() => _error = 'PIN must be exactly 4 digits.');
      return;
    }
    if (pin != confirm) {
      setState(() => _error = 'PINs do not match.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      // Server-created (hashed + vaulted). The returned digits go straight
      // to the awaiting money callable — never stored on device.
      await widget.service.setPin(newPin: pin);
      if (mounted) Navigator.of(context).pop(pin);
    } on TransactionPinException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        20,
        24,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Icon(Icons.shield_outlined, color: AppColors.seseGold, size: 40),
          const SizedBox(height: 12),
          const Text(
            'Create Transaction PIN',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'Set a 4-digit security PIN to protect and authorize your '
            'wallet transfers and withdrawals.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          TextField(
            key: const Key('jit_setup_pin_field'),
            controller: _pinCtrl,
            keyboardType: TextInputType.number,
            maxLength: 4,
            obscureText: true,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: '4-Digit PIN',
              border: OutlineInputBorder(),
              counterText: '',
              prefixIcon: Icon(Icons.lock_outline),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('jit_setup_confirm_field'),
            controller: _confirmCtrl,
            keyboardType: TextInputType.number,
            maxLength: 4,
            obscureText: true,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Confirm 4-Digit PIN',
              border: OutlineInputBorder(),
              counterText: '',
              prefixIcon: Icon(Icons.lock_outline),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('jit_setup_save_button'),
            onPressed: _saving ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.seseGold,
              foregroundColor: Colors.black,
              minimumSize: const Size(double.infinity, 50),
            ),
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                  )
                : const Text('Save PIN & Authorize'),
          ),
        ],
      ),
    );
  }
}

/// Pre-flight PIN entry: verifies server-side for immediate feedback, then
/// returns the digits for the awaiting money callable (which re-verifies).
class _CollectPinSheet extends StatefulWidget {
  final TransactionPinService service;

  const _CollectPinSheet({required this.service});

  @override
  State<_CollectPinSheet> createState() => _CollectPinSheetState();
}

class _CollectPinSheetState extends State<_CollectPinSheet> {
  final _pinCtrl = TextEditingController();
  bool _checking = false;
  String? _error;

  @override
  void dispose() {
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final entered = _pinCtrl.text.trim();
    if (entered.length != 4) {
      setState(() => _error = 'Enter your 4-digit PIN.');
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      await widget.service.verifyPin(entered);
      if (mounted) Navigator.of(context).pop(entered);
    } on TransactionPinException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _pinCtrl.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        20,
        24,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Icon(Icons.lock_clock_outlined, color: AppColors.seseGold, size: 40),
          const SizedBox(height: 12),
          const Text(
            'Enter Transaction PIN',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'Enter your 4-digit security PIN to authorize this transaction.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          TextField(
            key: const Key('jit_verify_pin_field'),
            controller: _pinCtrl,
            keyboardType: TextInputType.number,
            maxLength: 4,
            obscureText: true,
            autofocus: true,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: '4-Digit PIN',
              border: OutlineInputBorder(),
              counterText: '',
              prefixIcon: Icon(Icons.lock_outline),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('jit_verify_submit_button'),
            onPressed: _checking ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.seseGold,
              foregroundColor: Colors.black,
              minimumSize: const Size(double.infinity, 50),
            ),
            child: _checking
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                  )
                : const Text('Authorize Transaction'),
          ),
        ],
      ),
    );
  }
}
