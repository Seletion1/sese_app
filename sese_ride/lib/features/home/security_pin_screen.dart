import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sese_core/sese_core.dart';

/// Security PIN management screen.
///
/// Customers and Drivers share this screen (both profile surfaces navigate
/// here), so one rewire covers both modes.
///
/// Zero-trust contract: the PIN is NEVER read, compared, or written
/// client-side. [_load] only asks the server whether a PIN exists (vault
/// marker); [_save] calls `setTransactionPin`, which verifies the old PIN
/// against the salted server hash before replacing it. The legacy plaintext
/// `users/{uid}.securityPin` field is never referenced — the server migrates
/// and deletes it on first PIN use.
///
/// Dedicated to sensitive financial operations such as wallet transfers and
/// payouts. Fully independent from the Firebase Auth account password:
/// different storage (Firestore vault vs Auth), different verifiers —
/// changing one can never overwrite or affect the other.
class SecurityPinScreen extends StatefulWidget {
  final String uid;

  const SecurityPinScreen({super.key, required this.uid});

  @override
  State<SecurityPinScreen> createState() => _SecurityPinScreenState();
}

class _SecurityPinScreenState extends State<SecurityPinScreen> {
  final _oldPin = TextEditingController();
  final _newPin = TextEditingController();
  final _confirmPin = TextEditingController();
  final _pinService = const TransactionPinService();

  bool _hasExistingPin = false;
  bool _loading = true;
  bool _saving = false;

  bool _obscureOld = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _oldPin.dispose();
    _newPin.dispose();
    _confirmPin.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      _hasExistingPin = await _pinService.hasPin(widget.uid);
    } catch (_) {
      // Degrade gracefully in tests or offline — the server arbitrates.
      _hasExistingPin = false;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final oldPin = _oldPin.text.trim();
    final pin = _newPin.text.trim();
    final confirm = _confirmPin.text.trim();

    if (_hasExistingPin && oldPin.isEmpty) {
      setState(() => _error = 'Please enter your current old PIN.');
      return;
    }
    if (_hasExistingPin && oldPin == pin) {
      setState(() => _error = 'New PIN must be different from your old PIN.');
      return;
    }

    if (pin.length != 4) {
      setState(() => _error = 'New PIN must be exactly 4 digits.');
      return;
    }
    if (pin != confirm) {
      setState(() => _error = 'New PINs do not match.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      // Server-verified change: the old PIN is checked against the salted
      // hash (wrong PIN and lockout surface here as user-safe errors), then
      // the new hash replaces it. Never touches the Auth password.
      await _pinService.setPin(
        currentPin: _hasExistingPin ? oldPin : null,
        newPin: pin,
      );

      if (mounted) {
        setState(() => _hasExistingPin = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Security PIN updated successfully.'),
          ),
        );
        _oldPin.clear();
        _newPin.clear();
        _confirmPin.clear();
      }
    } on TransactionPinException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not update PIN: $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SeseAppBar(title: 'Security PIN'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                32 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              children: [
                // ── Status indicator ─────────────────────────────────────
                Card(
                  child: SettingsTile(
                    leading: Icon(
                      _hasExistingPin
                          ? Icons.lock
                          : Icons.lock_open_outlined,
                      color: _hasExistingPin ? Colors.green : Colors.orange,
                    ),
                    title: _hasExistingPin ? 'PIN Set' : 'No PIN Set',
                    titleStyle: const TextStyle(fontWeight: FontWeight.bold),
                    infoDescription: _hasExistingPin
                        ? 'Your account is protected by a 4-digit security PIN for wallet transfers & withdrawals.'
                        : 'Create a 4-digit PIN to secure your wallet transfers and withdrawals.',
                    trailing: null,
                  ),
                ),
                const SizedBox(height: 24),

                // ── Old PIN (only when updating existing PIN) ─────────────
                if (_hasExistingPin) ...[
                  Text(
                    'Enter Old PIN',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('security_pin_old_field'),
                    controller: _oldPin,
                    obscureText: _obscureOld,
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      hintText: 'Current 4-digit PIN',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.lock_clock_outlined),
                      counterText: '',
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureOld
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () =>
                            setState(() => _obscureOld = !_obscureOld),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // ── New PIN ──────────────────────────────────────────────
                Text(
                  _hasExistingPin ? 'Enter New PIN' : 'Create PIN',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('security_pin_new_field'),
                  controller: _newPin,
                  obscureText: _obscureNew,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    hintText: '4-digit PIN',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock_outline),
                    counterText: '',
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureNew
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () =>
                          setState(() => _obscureNew = !_obscureNew),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── Confirm PIN ──────────────────────────────────────────
                Text(
                  _hasExistingPin ? 'Confirm New PIN' : 'Confirm PIN',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('security_pin_confirm_field'),
                  controller: _confirmPin,
                  obscureText: _obscureConfirm,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    hintText: 'Repeat 4-digit PIN',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock_outline),
                    counterText: '',
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureConfirm
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () =>
                          setState(() => _obscureConfirm = !_obscureConfirm),
                    ),
                  ),
                ),

                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],

                const SizedBox(height: 32),

                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('security_pin_save_button'),
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(
                      _hasExistingPin ? 'Update PIN' : 'Set PIN',
                    ),
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.seseGold,
                      foregroundColor: Colors.black,
                      minimumSize: const Size(double.infinity, 50),
                    ),
                  ),
                ),

                const SizedBox(height: 16),
                Text(
                  'Your 4-digit PIN is strictly dedicated to authorizing sensitive '
                  'financial operations (P2P transfers & withdrawals). '
                  'Keep it confidential and never share it.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
    );
  }
}
