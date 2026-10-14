import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/image_compression_service.dart';

/// Full preview card for ID and Photo verification uploads.
///
/// Features:
/// - 40x40 rounded thumbnail preview of the captured photo or document.
/// - Truncated file name (e.g. `id_front_934.jpg`) and file size label.
/// - Explicit "Retake" / "Replace Document" action buttons.
class DocumentUploadCard extends StatelessWidget {
  final String label;
  final XFile? file;
  final IconData placeholderIcon;
  final VoidCallback onPick;
  final VoidCallback onRetake;
  final bool isCameraOnly;
  final bool disabled;
  final String? helpText;

  const DocumentUploadCard({
    super.key,
    required this.label,
    required this.file,
    required this.placeholderIcon,
    required this.onPick,
    required this.onRetake,
    this.isCameraOnly = false,
    this.disabled = false,
    this.helpText,
  });

  String _formatFileSize(int bytes) {
    return ImageCompressionService.formatBytes(bytes);
  }

  String _truncateFileName(String name) {
    if (name.length <= 20) return name;
    final extIndex = name.lastIndexOf('.');
    if (extIndex != -1 && extIndex > name.length - 6) {
      final ext = name.substring(extIndex);
      final start = name.substring(0, 14);
      return '$start...$ext';
    }
    return '${name.substring(0, 17)}...';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (file == null) {
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: disabled ? null : onPick,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(placeholderIcon, color: theme.colorScheme.primary),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        helpText ??
                            (isCameraOnly
                                ? 'Tap to capture via camera'
                                : 'Tap to upload or take photo'),
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.add_photo_alternate_outlined,
                    color: theme.colorScheme.primary, size: 22),
              ],
            ),
          ),
        ),
      );
    }

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            // 40x40 rounded thumbnail preview
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 40,
                height: 40,
                child: kIsWeb
                    ? Image.network(
                        file!.path,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          color: Colors.grey.shade200,
                          child: const Icon(Icons.description, size: 20),
                        ),
                      )
                    : Image.file(
                        File(file!.path),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          color: Colors.grey.shade200,
                          child: const Icon(Icons.description, size: 20),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _truncateFileName(file!.name),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.check_circle, color: Colors.green, size: 16),
                    ],
                  ),
                  const SizedBox(height: 2),
                  FutureBuilder<int>(
                    future: file!.length(),
                    builder: (context, snapshot) {
                      final sizeStr = snapshot.hasData
                          ? _formatFileSize(snapshot.data!)
                          : '';
                      return Text(
                        '$label ${sizeStr.isNotEmpty ? '• $sizeStr' : ''}',
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        softWrap: true,
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: TextButton.icon(
                icon: Icon(
                  isCameraOnly ? Icons.camera_alt_outlined : Icons.replay,
                  size: 16,
                ),
                label: Text(
                  isCameraOnly ? 'Retake' : 'Change File',
                  style: const TextStyle(fontSize: 12),
                  softWrap: false,
                  overflow: TextOverflow.visible,
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: disabled ? null : onRetake,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
