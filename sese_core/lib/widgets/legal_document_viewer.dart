import 'package:flutter/material.dart';
import '../legal/legal_document_content.dart';

/// Reusable Legal Content Viewing Widget / Screen / Modal for SESE Ecosystem.
class LegalDocumentViewer extends StatelessWidget {
  final LegalDocType type;
  final String? customUrl;

  const LegalDocumentViewer({
    super.key,
    required this.type,
    this.customUrl,
  });

  /// Opens the Legal Document modal sheet or full screen viewer.
  static Future<void> show(BuildContext context, LegalDocType type) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.9,
        child: LegalDocumentViewer(type: type),
      ),
    );
  }

  /// Helper shortcut for Terms of Use.
  static Future<void> showTerms(BuildContext context) =>
      show(context, LegalDocType.terms);

  /// Helper shortcut for Privacy Policy.
  static Future<void> showPrivacy(BuildContext context) =>
      show(context, LegalDocType.privacy);

  @override
  Widget build(BuildContext context) {
    final title = LegalDocumentContent.titleFor(type);
    final text = LegalDocumentContent.contentFor(type);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        centerTitle: true,
        leading: IconButton(
          key: const Key('legal_viewer_close_btn'),
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        elevation: 0.5,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.primaryColor.withAlpha(20),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.primaryColor.withAlpha(60),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      type == LegalDocType.terms
                          ? Icons.description_outlined
                          : Icons.privacy_tip_outlined,
                      color: theme.primaryColor,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Official SESE Technology LTD Compliance Document',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: theme.primaryColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SelectableText(
                text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.6,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
