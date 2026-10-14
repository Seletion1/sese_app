import 'package:flutter/material.dart';
import '../legal/legal_document_content.dart';
import '../services/legal_consent_service.dart';
import 'legal_document_viewer.dart';

/// Mandatory Non-Dismissible Consent Dialog for Updated Legal Terms.
class MandatoryLegalAcceptanceDialog extends StatefulWidget {
  final String userId;
  final String userRole;
  final LegalTermsConfig remoteConfig;
  final LegalConsentService consentService;

  const MandatoryLegalAcceptanceDialog({
    super.key,
    required this.userId,
    required this.userRole,
    required this.remoteConfig,
    this.consentService = const LegalConsentService(),
  });

  /// Evaluates whether legal terms re-acceptance is required and shows the modal if needed.
  static Future<void> checkAndShow(
    BuildContext context, {
    required String userId,
    required String userRole,
  }) async {
    const service = LegalConsentService();
    final config = await service.fetchRemoteLegalTerms();
    if (!context.mounted) return;

    final needs = await service.needsReacceptance(
      userId: userId,
      remoteConfig: config,
    );
    if (!needs || !context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: MandatoryLegalAcceptanceDialog(
          userId: userId,
          userRole: userRole,
          remoteConfig: config,
          consentService: service,
        ),
      ),
    );
  }

  @override
  State<MandatoryLegalAcceptanceDialog> createState() =>
      _MandatoryLegalAcceptanceDialogState();
}

class _MandatoryLegalAcceptanceDialogState
    extends State<MandatoryLegalAcceptanceDialog> {
  bool _submitting = false;

  Future<void> _accept() async {
    setState(() => _submitting = true);
    try {
      await widget.consentService.recordAcceptance(
        userId: widget.userId,
        role: widget.userRole,
        termsVersion: widget.remoteConfig.termsVersion,
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.gavel, color: theme.primaryColor, size: 28),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Terms of Service Updated',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "We've updated our Terms of Service & Privacy Policy to better serve you. Please review and accept to continue using SESE.",
              style: TextStyle(fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 18, color: Colors.grey),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Version ${widget.remoteConfig.termsVersion} • Effective Immediately',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      actions: [
        TextButton(
          key: const Key('review_terms_btn'),
          onPressed: _submitting
              ? null
              : () => LegalDocumentViewer.show(context, LegalDocType.terms),
          child: const Text('Review Terms'),
        ),
        ElevatedButton(
          key: const Key('accept_terms_btn'),
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.primaryColor,
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: _submitting ? null : _accept,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text(
                  'Accept & Continue',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
        ),
      ],
    );
  }
}
