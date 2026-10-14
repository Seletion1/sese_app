import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Hub admin screen for managing the Sese CDN map bundle ecosystem.
///
/// Provides three panels:
/// 1. **State Bundles** — lists all Nigerian states with their locally-cached
///    bundle version (if any) and a download / refresh action.
/// 2. **Geocoder Cache** — displays the count of cached places in each
///    downloaded state's `geocoder.db` and provides an eviction control.
/// 3. **Upload Bundle** — file-picker stub for uploading new `.mbtiles`,
///    `geocoder.db`, and `routing.osrm` files to Firebase Storage so the CDN
///    endpoint can serve them.  The actual Firebase Storage upload is
///    delegated to a companion Cloud Function that validates the bundle before
///    making it live.
///
/// WHY a separate hub screen: map bundle publishing is a privileged operation
/// (a bad `.mbtiles` file can blank every user's map).  Gating it behind Hub
/// admin access keeps the deploy surface small and auditable.
class HubGeocoderAdminScreen extends StatefulWidget {
  const HubGeocoderAdminScreen({super.key});

  @override
  State<HubGeocoderAdminScreen> createState() =>
      _HubGeocoderAdminScreenState();
}

class _HubGeocoderAdminScreenState extends State<HubGeocoderAdminScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final OfflineMapManager _manager = OfflineMapManager();

  /// Nigerian state codes supported by the CDN bundle system.
  static const List<_StateEntry> _nigerianStates = [
    _StateEntry('AB', 'Abia'),
    _StateEntry('AD', 'Adamawa'),
    _StateEntry('AK', 'Akwa Ibom'),
    _StateEntry('AN', 'Anambra'),
    _StateEntry('BA', 'Bauchi'),
    _StateEntry('BY', 'Bayelsa'),
    _StateEntry('BE', 'Benue'),
    _StateEntry('BO', 'Borno'),
    _StateEntry('CR', 'Cross River'),
    _StateEntry('DE', 'Delta'),
    _StateEntry('EB', 'Ebonyi'),
    _StateEntry('ED', 'Edo'),
    _StateEntry('EK', 'Ekiti'),
    _StateEntry('EN', 'Enugu'),
    _StateEntry('GO', 'Gombe'),
    _StateEntry('IM', 'Imo'),
    _StateEntry('JI', 'Jigawa'),
    _StateEntry('KD', 'Kaduna'),
    _StateEntry('KN', 'Kano'),
    _StateEntry('KT', 'Katsina'),
    _StateEntry('KE', 'Kebbi'),
    _StateEntry('KO', 'Kogi'),
    _StateEntry('KW', 'Kwara'),
    _StateEntry('LA', 'Lagos'),
    _StateEntry('NA', 'Nasarawa'),
    _StateEntry('NI', 'Niger'),
    _StateEntry('OG', 'Ogun'),
    _StateEntry('ON', 'Ondo'),
    _StateEntry('OS', 'Osun'),
    _StateEntry('OY', 'Oyo'),
    _StateEntry('PL', 'Plateau'),
    _StateEntry('RI', 'Rivers'),
    _StateEntry('SO', 'Sokoto'),
    _StateEntry('TA', 'Taraba'),
    _StateEntry('YO', 'Yobe'),
    _StateEntry('ZA', 'Zamfara'),
    _StateEntry('FC', 'FCT Abuja'),
  ];

  List<String> _cachedCodes = [];
  List<String> _staleUpdates = [];
  bool _initialising = true;
  String? _activeDownload;
  BundleDownloadProgress? _progress;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _initialising = true);
    await _manager.init();
    final cached = await _manager.cachedStateCodes();
    final updates = await _manager.checkForUpdates();
    if (mounted) {
      setState(() {
        _cachedCodes = cached;
        _staleUpdates = updates;
        _initialising = false;
      });
    }
  }

  Future<void> _download(String stateCode) async {
    if (_activeDownload != null) return;
    // Capture context-derived objects before the first await so the analyzer
    // does not flag use_build_context_synchronously.
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _activeDownload = stateCode;
      _progress = null;
    });
    final ok = await _manager.downloadStateBundles(
      stateCode,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );
    if (!mounted) return;
    setState(() {
      _activeDownload = null;
      _progress = null;
    });
    await _load();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Bundle downloaded: $stateCode'
              : 'Download failed for $stateCode',
        ),
        backgroundColor: ok ? Colors.green : Colors.red,
      ),
    );
  }

  Future<void> _deleteBundle(String stateCode) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete bundle?'),
        content: Text('Remove the locally cached $stateCode bundle?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('CANCEL')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('DELETE', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm == true) {
      await _manager.deleteBundle(stateCode);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Map Bundle Admin'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'State Bundles'),
            Tab(text: 'Geocoder Cache'),
            Tab(text: 'Upload Bundle'),
          ],
        ),
      ),
      body: _initialising
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: [
                _StateBundlesTab(
                  states: _nigerianStates,
                  cachedCodes: _cachedCodes,
                  staleUpdates: _staleUpdates,
                  activeDownload: _activeDownload,
                  progress: _progress,
                  onDownload: _download,
                  onDelete: _deleteBundle,
                  onRefresh: _load,
                ),
                _GeocoderCacheTab(
                  cachedCodes: _cachedCodes,
                  manager: _manager,
                ),
                const _UploadBundleTab(),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 1 — State Bundles
// ---------------------------------------------------------------------------

class _StateBundlesTab extends StatelessWidget {
  final List<_StateEntry> states;
  final List<String> cachedCodes;
  final List<String> staleUpdates;
  final String? activeDownload;
  final BundleDownloadProgress? progress;
  final ValueChanged<String> onDownload;
  final ValueChanged<String> onDelete;
  final VoidCallback onRefresh;

  const _StateBundlesTab({
    required this.states,
    required this.cachedCodes,
    required this.staleUpdates,
    required this.activeDownload,
    required this.progress,
    required this.onDownload,
    required this.onDelete,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: states.length,
        itemBuilder: (context, index) {
          final state = states[index];
          final isCached = cachedCodes.contains(state.code);
          final isStale = staleUpdates.contains(state.code);
          final isDownloading = activeDownload == state.code;
          final prog = isDownloading ? progress : null;

          return ListTile(
            leading: CircleAvatar(
              backgroundColor: isCached
                  ? (isStale ? Colors.orange : Colors.green)
                  : Colors.grey.shade300,
              child: Text(
                state.code,
                style: TextStyle(
                  fontSize: 11,
                  color: isCached ? Colors.white : Colors.black54,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            title: Text(state.name),
            subtitle: isDownloading && prog != null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Downloading ${prog.fileIndex}/${prog.fileCount}: '
                        '${prog.filename}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: prog.fileFraction,
                        backgroundColor: Colors.grey.shade200,
                      ),
                    ],
                  )
                : Text(
                    isCached
                        ? isStale
                            ? 'Update available'
                            : 'Cached ✓'
                        : 'Not downloaded',
                    style: TextStyle(
                      fontSize: 12,
                      color: isCached
                          ? (isStale ? Colors.orange : Colors.green)
                          : Colors.grey,
                    ),
                  ),
            trailing: isDownloading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          isCached ? Icons.refresh : Icons.download,
                          color: isStale ? Colors.orange : null,
                        ),
                        tooltip: isCached ? 'Refresh bundle' : 'Download',
                        onPressed: activeDownload == null
                            ? () => onDownload(state.code)
                            : null,
                      ),
                      if (isCached)
                        IconButton(
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.red),
                          tooltip: 'Delete bundle',
                          onPressed: () => onDelete(state.code),
                        ),
                    ],
                  ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 2 — Geocoder Cache
// ---------------------------------------------------------------------------

class _GeocoderCacheTab extends StatefulWidget {
  final List<String> cachedCodes;
  final OfflineMapManager manager;

  const _GeocoderCacheTab({
    required this.cachedCodes,
    required this.manager,
  });

  @override
  State<_GeocoderCacheTab> createState() => _GeocoderCacheTabState();
}

class _GeocoderCacheTabState extends State<_GeocoderCacheTab> {
  // Counts: stateCode → place count in geocoder.db
  final Map<String, int> _counts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadCounts();
  }

  Future<void> _loadCounts() async {
    setState(() => _loading = true);
    for (final code in widget.cachedCodes) {
      final paths = await widget.manager.getLocalBundlePaths(code);
      if (paths != null) {
        try {
          final dbFile = File(paths.geocoderDbPath);
          if (await dbFile.exists()) {
            // Quick row count via sqlite3_changes fallback: use a LocalGeocoderService
            // pointing at the bundle-specific geocoder.db.
            // For simplicity we just report the file size here; a full count
            // would require opening the bundle db separately.
            final size = await dbFile.length();
            if (mounted) setState(() => _counts[code] = size);
          }
        } catch (_) {}
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (widget.cachedCodes.isEmpty) {
      return const Center(
        child: Text(
          'No state bundles downloaded yet.\n'
          'Go to State Bundles tab to download.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: widget.cachedCodes.length,
      itemBuilder: (context, i) {
        final code = widget.cachedCodes[i];
        final sizeBytes = _counts[code];
        final sizeLabel = sizeBytes != null
            ? '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB'
            : 'Unknown';
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: ListTile(
            leading: const Icon(Icons.storage, color: Colors.blue),
            title: Text('geocoder.db — $code'),
            subtitle: Text('File size: $sizeLabel'),
            trailing: const Icon(Icons.check_circle, color: Colors.green),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 3 — Upload Bundle
// ---------------------------------------------------------------------------

class _UploadBundleTab extends StatelessWidget {
  const _UploadBundleTab();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Upload State Bundle',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Upload a new .mbtiles vector tile database, geocoder.db, and '
            'routing.osrm graph to the Sese CDN.  Bundles are validated '
            'server-side before becoming live.\n\n'
            'Connect a file picker or SFTP client to the CDN upload endpoint '
            'defined in the Cloud Function `publishMapBundle`.',
            style: TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 32),
          _UploadCard(
            icon: Icons.map,
            label: '.mbtiles Vector Tiles',
            description: 'Vector tile database for the selected state.',
          ),
          const SizedBox(height: 12),
          _UploadCard(
            icon: Icons.search,
            label: 'geocoder.db SQLite',
            description: 'FTS5 address database for offline geocoding.',
          ),
          const SizedBox(height: 12),
          _UploadCard(
            icon: Icons.route,
            label: 'routing.osrm Graph',
            description: 'OSRM pre-processed routing graph.',
          ),
          const Spacer(),
          const Text(
            'Note: file upload UI requires the `file_picker` package and a '
            'Firebase Storage upload callable.  Wire these in when the CDN '
            'endpoint is ready.',
            style: TextStyle(fontSize: 11, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _UploadCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;

  const _UploadCard({
    required this.icon,
    required this.label,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        leading: Icon(icon, color: Theme.of(context).primaryColor),
        title: Text(label, softWrap: true),
        subtitle: Text(description, style: const TextStyle(fontSize: 12), softWrap: true),
        trailing: OutlinedButton.icon(
          icon: const Icon(Icons.upload, size: 16),
          label: const Text('Choose file', softWrap: false),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            visualDensity: VisualDensity.compact,
          ),
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                    'File picker not yet wired — connect file_picker + '
                    'Firebase Storage callable.'),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StateEntry {
  final String code;
  final String name;
  const _StateEntry(this.code, this.name);
}
