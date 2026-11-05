import 'package:flutter/material.dart';

/// Interactive high-resolution viewer for reviewing verification documents.
class _DocumentPreviewDialog extends StatelessWidget {
  final String title;
  final String imageUrl;

  const _DocumentPreviewDialog({
    required this.title,
    required this.imageUrl,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      backgroundColor: isDark ? const Color(0xFF1E1E28) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header with title and close icon
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: 'Close',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Zoomable image canvas with bounded memory decoding
          Flexible(
            child: Container(
              color: isDark ? Colors.black26 : const Color(0xFFF8F9FA),
              constraints: const BoxConstraints(maxHeight: 520),
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4.0,
                child: Center(
                  child: Image.network(
                    imageUrl,
                    cacheWidth: 1280,
                    fit: BoxFit.contain,
                    loadingBuilder: (ctx, child, progress) {
                      if (progress == null) return child;
                      final total = progress.expectedTotalBytes;
                      final loaded = progress.cumulativeBytesLoaded;
                      final pct = total != null && total > 0 ? (loaded / total) : null;
                      return Padding(
                        padding: const EdgeInsets.all(48),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(value: pct),
                            const SizedBox(height: 12),
                            const Text('Loading document...', style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      );
                    },
                    errorBuilder: (ctx, err, stack) => Padding(
                      padding: const EdgeInsets.all(40),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.broken_image_outlined, size: 48, color: Colors.grey),
                          const SizedBox(height: 8),
                          const Text(
                            'Failed to load document image.',
                            style: TextStyle(fontSize: 13, color: Colors.grey),
                          ),
                          const SizedBox(height: 12),
                          FilledButton.tonal(
                            onPressed: () => (ctx as Element).markNeedsBuild(),
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Divider(height: 1),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SelectableText(
              imageUrl,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ),

          // Bottom action toolbar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A bandwidth-efficient, memory-bounded thumbnail widget for document previews in SeSe Hub.
///
/// Features:
/// - Downsamples decoded bitmap to [thumbnailWidth] x [thumbnailHeight] in native memory.
/// - Minimizes RAM consumption when rendering queues of driver KYC & vehicle inspection documents.
/// - Tapping the thumbnail launches an interactive, pinch-to-zoom modal with high-res details.
class CachedDocumentThumbnail extends StatelessWidget {
  final String imageUrl;
  final String title;
  final double width;
  final double height;
  final double borderRadius;
  final IconData fallbackIcon;
  final BoxFit fit;

  const CachedDocumentThumbnail({
    super.key,
    required this.imageUrl,
    required this.title,
    this.width = 56,
    this.height = 56,
    this.borderRadius = 8,
    this.fallbackIcon = Icons.description_outlined,
    this.fit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context) {
    if (imageUrl.trim().isEmpty) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: Icon(fallbackIcon, size: width * 0.45, color: Colors.grey),
      );
    }

    final cacheW = (width * 2).toInt();
    final cacheH = (height * 2).toInt();

    return InkWell(
      onTap: () {
        showDialog<void>(
          context: context,
          builder: (ctx) => _DocumentPreviewDialog(
            title: title,
            imageUrl: imageUrl,
          ),
        );
      },
      borderRadius: BorderRadius.circular(borderRadius),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: SizedBox(
          width: width,
          height: height,
          child: Image.network(
            imageUrl,
            width: width,
            height: height,
            cacheWidth: cacheW,
            cacheHeight: cacheH,
            fit: fit,
            loadingBuilder: (ctx, child, progress) {
              if (progress == null) return child;
              return Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            },
            errorBuilder: (ctx, err, stack) => Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Icon(fallbackIcon, size: width * 0.45, color: Colors.grey),
            ),
          ),
        ),
      ),
    );
  }
}

/// An ActionChip with a dynamic cached document thumbnail avatar.
///
/// Replaces generic static document icons with live visual thumbnails in Hub approval tables.
class CachedDocumentThumbnailChip extends StatelessWidget {
  final String imageUrl;
  final String label;
  final String? title;
  final IconData fallbackIcon;
  final VoidCallback? onCustomTap;

  const CachedDocumentThumbnailChip({
    super.key,
    required this.imageUrl,
    required this.label,
    this.title,
    this.fallbackIcon = Icons.badge_outlined,
    this.onCustomTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasUrl = imageUrl.trim().isNotEmpty;

    Widget avatarWidget;
    if (hasUrl) {
      avatarWidget = ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.network(
          imageUrl,
          width: 20,
          height: 20,
          cacheWidth: 64,
          cacheHeight: 64,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Icon(fallbackIcon, size: 16),
          loadingBuilder: (_, child, progress) =>
              progress == null ? child : const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)),
        ),
      );
    } else {
      avatarWidget = Icon(fallbackIcon, size: 16, color: Colors.grey);
    }

    return ActionChip(
      avatar: avatarWidget,
      label: Text(label),
      onPressed: hasUrl
          ? () {
              if (onCustomTap != null) {
                onCustomTap!();
              } else {
                showDialog<void>(
                  context: context,
                  builder: (ctx) => _DocumentPreviewDialog(
                    title: title ?? label,
                    imageUrl: imageUrl,
                  ),
                );
              }
            }
          : null,
    );
  }
}
