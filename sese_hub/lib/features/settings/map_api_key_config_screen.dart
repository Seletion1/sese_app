import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Dedicated screen allowing administrators to configure, validate, and persist
/// dynamic Map API keys and access tokens stored in Firestore under document
/// `system_config/api_keys`.
///
/// Features:
/// - Dynamic Provider Selection: Google Maps (`google`) vs Mapbox (`mapbox`).
/// - Google Maps Platform Credentials:
///   - Android API Key (`google_maps.android_key`)
///   - iOS API Key (`google_maps.ios_key`)
///   - Web API Key (`google_maps.web_key`)
/// - Mapbox Platform Credentials:
///   - Android Access Token (`mapbox.android_token`)
///   - iOS Access Token (`mapbox.ios_token`)
///   - Web Access Token (`mapbox.web_token`)
/// - Validation Safeguards: Blocks saving empty credentials accidentally.
/// - Security: Obscures secrets by default with an eye-icon toggle.
class MapApiKeyConfigScreen extends StatefulWidget {
  final ApiKeysService? apiKeysService;

  const MapApiKeyConfigScreen({super.key, this.apiKeysService});

  @override
  State<MapApiKeyConfigScreen> createState() => _MapApiKeyConfigScreenState();
}

class _MapApiKeyConfigScreenState extends State<MapApiKeyConfigScreen> {
  late final ApiKeysService _service;

  late final TextEditingController _googleAndroidCtrl;
  late final TextEditingController _googleIosCtrl;
  late final TextEditingController _googleWebCtrl;

  late final TextEditingController _mapboxAndroidCtrl;
  late final TextEditingController _mapboxIosCtrl;
  late final TextEditingController _mapboxWebCtrl;

  String _activeProvider = 'google';
  bool _obscureGoogleKeys = true;
  bool _obscureMapboxTokens = true;
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _service = widget.apiKeysService ?? const ApiKeysService();
    _googleAndroidCtrl = TextEditingController();
    _googleIosCtrl = TextEditingController();
    _googleWebCtrl = TextEditingController();

    _mapboxAndroidCtrl = TextEditingController();
    _mapboxIosCtrl = TextEditingController();
    _mapboxWebCtrl = TextEditingController();

    _loadConfiguration();
  }

  @override
  void dispose() {
    _googleAndroidCtrl.dispose();
    _googleIosCtrl.dispose();
    _googleWebCtrl.dispose();
    _mapboxAndroidCtrl.dispose();
    _mapboxIosCtrl.dispose();
    _mapboxWebCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadConfiguration() async {
    try {
      final config = await _service.fetchApiKeys();
      if (!mounted) return;

      setState(() {
        _activeProvider = config.normalizedProvider;
        _googleAndroidCtrl.text = config.googleAndroidKey;
        _googleIosCtrl.text = config.googleIosKey;
        _googleWebCtrl.text = config.googleWebKey;

        _mapboxAndroidCtrl.text = config.mapboxAndroidToken;
        _mapboxIosCtrl.text = config.mapboxIosToken;
        _mapboxWebCtrl.text = config.mapboxWebToken;

        _isLoading = false;
      });
    } catch (e) {
      debugPrint('MapApiKeyConfigScreen: error loading api_keys: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _saveConfiguration() async {
    final gAndroid = _googleAndroidCtrl.text.trim();
    final gIos = _googleIosCtrl.text.trim();
    final gWeb = _googleWebCtrl.text.trim();

    final mAndroid = _mapboxAndroidCtrl.text.trim();
    final mIos = _mapboxIosCtrl.text.trim();
    final mWeb = _mapboxWebCtrl.text.trim();

    // ── Validation: Guard against saving completely empty configuration ───────
    final allGoogleEmpty = gAndroid.isEmpty && gIos.isEmpty && gWeb.isEmpty;
    final allMapboxEmpty = mAndroid.isEmpty && mIos.isEmpty && mWeb.isEmpty;

    if (allGoogleEmpty && allMapboxEmpty) {
      _showWarningSnackBar(
        'Cannot save empty configuration. Please provide at least one valid API key or token.',
      );
      return;
    }

    // Guard against active provider having zero configured credentials
    if (_activeProvider == 'google' && allGoogleEmpty) {
      _showWarningSnackBar(
        'Google Maps is active, but all Google API keys are empty. Provide at least one key before saving.',
      );
      return;
    }

    if (_activeProvider == 'mapbox' && allMapboxEmpty) {
      _showWarningSnackBar(
        'Mapbox is active, but all Mapbox access tokens are empty. Provide at least one token before saving.',
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final updatedConfig = ApiKeysConfig(
        activeMapProvider: _activeProvider,
        googleAndroidKey: gAndroid,
        googleIosKey: gIos,
        googleWebKey: gWeb,
        mapboxAndroidToken: mAndroid,
        mapboxIosToken: mIos,
        mapboxWebToken: mWeb,
      );

      await _service.saveApiKeys(updatedConfig);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: const [
              Icon(Icons.check_circle_rounded, color: Colors.white),
              SizedBox(width: 10),
              Expanded(
                child: Text('Map & API Key configuration saved successfully!'),
              ),
            ],
          ),
          backgroundColor: Colors.green.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      debugPrint('MapApiKeyConfigScreen: save failed: $e');
      if (!mounted) return;
      _showWarningSnackBar('Failed to save configuration: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showWarningSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Map & API Key Management'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              key: const Key('map_api_keys_save_button'),
              icon: _isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save_rounded, size: 18),
              label: Text(_isSaving ? 'Saving...' : 'Save Configuration'),
              onPressed: _isSaving || _isLoading ? null : _saveConfiguration,
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              children: [
                // ── Informational Header Banner ──────────────────────────────
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: scheme.primary.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.map_rounded, color: scheme.primary, size: 30),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Dynamic Map Provider & API Key Credentials',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Persisted in system_config/api_keys. Customer and Driver apps dynamically fetch and inject these credentials on launch with automatic environment fallback.',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // ── Section 1: Active Map Provider Selection ─────────────────
                const _SectionLabel('Active Map Provider'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Choose the primary rendering engine across client applications:',
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _ProviderRadioOption(
                                title: 'Google Maps',
                                subtitle: 'Native GMS Maps SDK',
                                value: 'google',
                                groupValue: _activeProvider,
                                icon: Icons.public_rounded,
                                iconColor: Colors.blue,
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() => _activeProvider = val);
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _ProviderRadioOption(
                                title: 'Mapbox',
                                subtitle: 'Vector & Raster Tiles',
                                value: 'mapbox',
                                groupValue: _activeProvider,
                                icon: Icons.layers_rounded,
                                iconColor: Colors.deepPurple,
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() => _activeProvider = val);
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // ── Section 2: Google Maps API Keys ──────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: _SectionLabel('Google Maps Platform Keys'),
                    ),
                    TextButton.icon(
                      icon: Icon(
                        _obscureGoogleKeys
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        size: 16,
                      ),
                      label: Text(_obscureGoogleKeys ? 'Show Keys' : 'Hide Keys'),
                      onPressed: () => setState(
                        () => _obscureGoogleKeys = !_obscureGoogleKeys,
                      ),
                    ),
                  ],
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _CredentialField(
                          key: const Key('input_google_maps_android_key'),
                          controller: _googleAndroidCtrl,
                          labelText: 'Android API Key',
                          helperText:
                              'Stored in google_maps.android_key (used by Android Maps SDK)',
                          icon: Icons.android_rounded,
                          obscureText: _obscureGoogleKeys,
                        ),
                        const SizedBox(height: 16),
                        _CredentialField(
                          key: const Key('input_google_maps_ios_key'),
                          controller: _googleIosCtrl,
                          labelText: 'iOS API Key',
                          helperText:
                              'Stored in google_maps.ios_key (passed to GMSServices.provideAPIKey)',
                          icon: Icons.apple_rounded,
                          obscureText: _obscureGoogleKeys,
                        ),
                        const SizedBox(height: 16),
                        _CredentialField(
                          key: const Key('input_google_maps_web_key'),
                          controller: _googleWebCtrl,
                          labelText: 'Web API Key',
                          helperText:
                              'Stored in google_maps.web_key (used by Web Maps JavaScript API)',
                          icon: Icons.language_rounded,
                          obscureText: _obscureGoogleKeys,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // ── Section 3: Mapbox Access Tokens ──────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: _SectionLabel('Mapbox Access Tokens'),
                    ),
                    TextButton.icon(
                      icon: Icon(
                        _obscureMapboxTokens
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        size: 16,
                      ),
                      label: Text(
                        _obscureMapboxTokens ? 'Show Tokens' : 'Hide Tokens',
                      ),
                      onPressed: () => setState(
                        () => _obscureMapboxTokens = !_obscureMapboxTokens,
                      ),
                    ),
                  ],
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _CredentialField(
                          key: const Key('input_mapbox_android_token'),
                          controller: _mapboxAndroidCtrl,
                          labelText: 'Android Access Token',
                          helperText:
                              'Stored in mapbox.android_token (pk.eyJ1...)',
                          icon: Icons.android_rounded,
                          obscureText: _obscureMapboxTokens,
                        ),
                        const SizedBox(height: 16),
                        _CredentialField(
                          key: const Key('input_mapbox_ios_token'),
                          controller: _mapboxIosCtrl,
                          labelText: 'iOS Access Token',
                          helperText:
                              'Stored in mapbox.ios_token (pk.eyJ1...)',
                          icon: Icons.apple_rounded,
                          obscureText: _obscureMapboxTokens,
                        ),
                        const SizedBox(height: 16),
                        _CredentialField(
                          key: const Key('input_mapbox_web_token'),
                          controller: _mapboxWebCtrl,
                          labelText: 'Web Access Token',
                          helperText:
                              'Stored in mapbox.web_token (pk.eyJ1...)',
                          icon: Icons.language_rounded,
                          obscureText: _obscureMapboxTokens,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 32),

                // ── Bottom Action Button ─────────────────────────────────────
                Center(
                  child: SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: FilledButton.icon(
                      key: const Key('map_api_keys_bottom_save_button'),
                      icon: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check_circle_outline_rounded),
                      label: Text(
                        _isSaving
                            ? 'Saving Configuration...'
                            : 'Save Configuration',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed:
                          _isSaving || _isLoading ? null : _saveConfiguration,
                    ),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }
}

// ── Private Reusable UI Widgets ──────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String title;

  const _SectionLabel(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _ProviderRadioOption extends StatelessWidget {
  final String title;
  final String subtitle;
  final String value;
  final String groupValue;
  final IconData icon;
  final Color iconColor;
  final ValueChanged<String?> onChanged;

  const _ProviderRadioOption({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.groupValue,
    required this.icon,
    required this.iconColor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = value == groupValue;
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: () => onChanged(value),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? scheme.primary : scheme.outlineVariant,
            width: isSelected ? 2 : 1,
          ),
          color: isSelected
              ? scheme.primaryContainer.withValues(alpha: 0.25)
              : Colors.transparent,
        ),
        child: Row(
          children: [
            Radio<String>(
              value: value,
              groupValue: groupValue,
              onChanged: onChanged,
            ),
            Icon(icon, color: iconColor, size: 24),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CredentialField extends StatelessWidget {
  final TextEditingController controller;
  final String labelText;
  final String helperText;
  final IconData icon;
  final bool obscureText;

  const _CredentialField({
    super.key,
    required this.controller,
    required this.labelText,
    required this.helperText,
    required this.icon,
    required this.obscureText,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      decoration: InputDecoration(
        labelText: labelText,
        helperText: helperText,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}
