import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth, FirebaseAuthException;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sese_core/sese_core.dart';

/// Secure Account Deletion Dialog with Hard Financial & Security Guardrails.
///
/// Guardrails checked in Firestore:
/// 1. `walletBalance > 0`: Rejected (must withdraw or spend funds first).
/// 2. `pendingPayouts == true`: Rejected (must wait for pending payouts to settle).
/// 3. Ongoing active rides / deliveries: Rejected.
/// 4. Explicit re-authentication: Password prompt for email users or Google sign-in.
///
/// Execution Pipeline:
/// - Soft-delete & 30-day archival in Firestore
/// - Revocation of session tokens
/// - Purging of Firebase Auth credentials
/// - Wiping of local SharedPreferences cache
/// - Route back to initial Welcome Auth Screen
class DeleteAccountDialog extends StatefulWidget {
  final AppUser user;
  final AuthRepository auth;

  const DeleteAccountDialog({
    super.key,
    required this.user,
    required this.auth,
  });

  static Future<void> show(BuildContext context, {
    required AppUser user,
    required AuthRepository auth,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DeleteAccountDialog(user: user, auth: auth),
    );
  }

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  final _passwordController = TextEditingController();
  bool _checkingGuardrails = true;
  String? _guardrailError;
  bool _isProcessing = false;
  String? _actionError;
  bool _confirmedRisk = false;

  bool get _isGoogleUser {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return false;
    return currentUser.providerData.any((p) => p.providerId == 'google.com');
  }

  @override
  void initState() {
    super.initState();
    _runFinancialGuardrailsCheck();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _runFinancialGuardrailsCheck() async {
    setState(() {
      _checkingGuardrails = true;
      _guardrailError = null;
    });

    final uid = widget.user.uid;
    try {
      final db = FirebaseFirestore.instance;

      // 1. Check Wallet Balance & Pending Payouts
      final walletSnap = await db.collection('wallets').doc(uid).get();
      if (walletSnap.exists && walletSnap.data() != null) {
        final data = walletSnap.data()!;
        final balance = (data['balance'] as num?)?.toDouble() ?? 0.0;
        if (balance > 0) {
          final naira = balance > 1000 ? (balance / 100.0) : balance;
          setState(() {
            _guardrailError =
                'Account deletion blocked: You have a remaining wallet balance of ₦${naira.toStringAsFixed(2)}. Please withdraw or exhaust your balance before deleting your account.';
            _checkingGuardrails = false;
          });
          return;
        }

        if (data['pendingPayouts'] == true || data['hasPendingPayout'] == true) {
          setState(() {
            _guardrailError =
                'Account deletion blocked: You have pending payouts in progress. Please wait for payouts to settle before deleting your account.';
            _checkingGuardrails = false;
          });
          return;
        }
      }

      // 2. Check pending driver payouts
      final payoutsSnap = await db
          .collection('driver_payouts')
          .where('driverId', isEqualTo: uid)
          .where('status', isEqualTo: 'pending')
          .limit(1)
          .get();

      if (payoutsSnap.docs.isNotEmpty) {
        setState(() {
          _guardrailError =
              'Account deletion blocked: You have pending payouts awaiting processing.';
          _checkingGuardrails = false;
        });
        return;
      }

      // 3. Check active trips (as customer or driver)
      const liveStatuses = [
        'SEARCHING_DRIVER',
        'WAITING_FOR_ACCEPTANCE',
        'MARKETPLACE_OPEN',
        'DRIVER_ACCEPTED',
        'DRIVER_ARRIVING',
        'DRIVER_ARRIVED',
        'IN_PROGRESS',
        'accepted',
        'arrived',
        'in_transit',
      ];

      final customerTrips = await db
          .collection('trips')
          .where('customerId', isEqualTo: uid)
          .where('status', whereIn: liveStatuses)
          .limit(1)
          .get();

      if (customerTrips.docs.isNotEmpty) {
        setState(() {
          _guardrailError =
              'Account deletion blocked: You have active rides or deliveries in progress.';
          _checkingGuardrails = false;
        });
        return;
      }

      final driverTrips = await db
          .collection('trips')
          // Assignee lives nested at `driver.driverId` — a top-level
          // `driverId` filter never matches trip documents.
          .where('driver.driverId', isEqualTo: uid)
          .where('status', whereIn: liveStatuses)
          .limit(1)
          .get();

      if (driverTrips.docs.isNotEmpty) {
        setState(() {
          _guardrailError =
              'Account deletion blocked: You have an active trip in progress as a driver.';
          _checkingGuardrails = false;
        });
        return;
      }

      setState(() => _checkingGuardrails = false);
    } catch (e) {
      debugPrint('DeleteAccountDialog guardrail check error: $e');
      setState(() => _checkingGuardrails = false);
    }
  }

  Future<void> _executeAccountDeletion() async {
    if (!_isGoogleUser && _passwordController.text.trim().isEmpty) {
      setState(() => _actionError = 'Please enter your password to confirm identity.');
      return;
    }

    setState(() {
      _isProcessing = true;
      _actionError = null;
    });

    try {
      // 1. Invoke backend Cloud Function if available
      try {
        await FirebaseFunctions.instance.httpsCallable('deleteAccount').call();
      } catch (e) {
        debugPrint('Cloud Function deleteAccount fallback to client auth delete: $e');
      }

      // 2. Perform client deletion and re-auth via AuthRepository
      await widget.auth.deleteAccount(
        password: _isGoogleUser ? null : _passwordController.text.trim(),
      );

      // 3. Wipe local cached preferences
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.clear();
      } catch (_) {}

      if (!mounted) return;

      // 4. Dismiss the dialog — the _AuthGate StreamBuilder observes the
      //    null auth state produced by the internal signOut() call inside
      //    deleteAccount() and automatically replaces the root widget tree
      //    with LoginPage. A direct pushAndRemoveUntil here races with that
      //    replacement and produces a duplicate LoginPage or a
      //    "deactivated ancestor" FlutterError on both Android and iOS.
      Navigator.of(context).pop();
    } on FirebaseAuthException catch (e) {
      String message = 'Deletion failed: ${e.message ?? e.code}';
      if (e.code == 'wrong-password') {
        message = 'Incorrect password. Re-authentication failed.';
      } else if (e.code == 'requires-recent-login') {
        message = 'Please sign in again before deleting your account.';
      }
      setState(() {
        _isProcessing = false;
        _actionError = message;
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _actionError = 'Failed to delete account: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
          SizedBox(width: 8),
          Text(
            'Delete Account',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
      content: _checkingGuardrails
          ? const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Verifying financial guardrails & active trips...'),
              ],
            )
          : _guardrailError != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.error_outline, color: Colors.red.shade700),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _guardrailError!,
                              style: TextStyle(
                                color: Colors.red.shade900,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'For your security, accounts cannot be deleted until all financial settlements and active rides are finalized.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                )
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'This action is irreversible. Your account will be immediately deactivated and scheduled for 30-day regulatory compliance archival.',
                        style: TextStyle(fontSize: 13, color: Colors.black87),
                      ),
                      const SizedBox(height: 16),
                      if (_actionError != null)
                        Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _actionError!,
                            style: TextStyle(color: Colors.red.shade800, fontSize: 12),
                          ),
                        ),
                      if (!_isGoogleUser) ...[
                        const Text(
                          'Enter your password to verify ownership:',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _passwordController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Password',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ] else ...[
                        const Text(
                          'You will be prompted to re-authenticate with your Google account.',
                          style: TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                        const SizedBox(height: 12),
                      ],
                      CheckboxListTile(
                        value: _confirmedRisk,
                        onChanged: _isProcessing
                            ? null
                            : (val) => setState(() => _confirmedRisk = val ?? false),
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'I understand that my account, profile, and credentials will be permanently erased.',
                          style: TextStyle(fontSize: 12),
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                    ],
                  ),
                ),
      actions: [
        TextButton(
          onPressed: _isProcessing ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (_guardrailError == null && !_checkingGuardrails)
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
            ),
            onPressed: (_isProcessing || !_confirmedRisk)
                ? null
                : _executeAccountDeletion,
            child: _isProcessing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Delete Permanently'),
          ),
      ],
    );
  }
}
