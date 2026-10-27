import 'package:flutter/material.dart';
import '../models/country_catalog.dart';
import '../services/country_detection_service.dart';

/// Full-width edge-to-edge country picker sheet launcher.
abstract final class CountryPickerSheet {
  static Future<SeseCountryInfo?> show(
    BuildContext context, {
    SeseCountryInfo? initial,
    String? initialCountryCode,
  }) {
    final resolveInitial = initial ??
        (initialCountryCode != null
            ? SeseCountryCatalog.findByCode(initialCountryCode)
            : null);
    final width = MediaQuery.of(context).size.width;
    return showModalBottomSheet<SeseCountryInfo>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      isDismissible: true,
      enableDrag: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      constraints: BoxConstraints(
        minWidth: width,
        maxWidth: width,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _CountrySearchSheet(initial: resolveInitial),
    );
  }
}

/// Reusable Country Selector with Search for SeSe applications.
///
/// Renders every entry as `[Flag] [Country Name] ([Dial Code])` (e.g.
/// 🇳🇬 Nigeria (+234)) and opens a searchable edge-to-edge bottom sheet
/// (matches on name, dial code, or ISO code). Persists manual user selection
/// locally via [CountryDetectionService.saveManualCountry].
class SeseCountryDropdownFormField extends StatefulWidget {
  final String? initialValue;
  final ValueChanged<SeseCountryInfo?>? onChanged;
  final String labelText;
  final bool isExpanded;
  final bool enabled;
  final InputDecoration? decoration;
  final Key? fieldKey;

  const SeseCountryDropdownFormField({
    super.key,
    this.fieldKey,
    this.initialValue,
    this.onChanged,
    this.labelText = 'Country',
    this.isExpanded = true,
    this.enabled = true,
    this.decoration,
  });

  @override
  State<SeseCountryDropdownFormField> createState() =>
      _SeseCountryDropdownFormFieldState();
}

class _SeseCountryDropdownFormFieldState
    extends State<SeseCountryDropdownFormField> {
  SeseCountryInfo? _selected;

  @override
  void initState() {
    super.initState();
    _selected = _resolve(widget.initialValue);
  }

  @override
  void didUpdateWidget(covariant SeseCountryDropdownFormField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue) {
      _selected = _resolve(widget.initialValue);
    }
  }

  static SeseCountryInfo? _resolve(String? raw) {
    if (raw == null || raw.isEmpty) {
      return SeseCountryCatalog.findByCode(
              CountryDetectionService.instance.currentCountryCode) ??
          SeseCountryCatalog.allCountries.first;
    }
    return SeseCountryCatalog.findByCode(raw) ??
        SeseCountryCatalog.allCountries.cast<SeseCountryInfo?>().firstWhere(
              (c) => c?.countryName.toLowerCase() == raw.toLowerCase(),
              orElse: () => SeseCountryCatalog.allCountries.first,
            );
  }

  Future<void> _openPicker() async {
    if (!widget.enabled) return;
    final picked = await CountryPickerSheet.show(
      context,
      initial: _selected,
    );
    if (picked != null && mounted) {
      setState(() => _selected = picked);
      // Persist manual country override across sessions
      // ignore: discarded_futures
      CountryDetectionService.instance.saveManualCountry(picked.countryCode);
      widget.onChanged?.call(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sel = _selected;
    return InkWell(
      key: widget.fieldKey,
      onTap: widget.enabled ? _openPicker : null,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: widget.decoration ??
            InputDecoration(
              labelText: widget.labelText,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
        child: Row(
          children: [
            if (sel != null) ...[
              Text(sel.flagEmoji, style: const TextStyle(fontSize: 20)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${sel.countryName} (${sel.dialCode})',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ] else
              const Expanded(child: Text('Select country')),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}

/// Full-width edge-to-edge bottom sheet: search field + filtered country list.
class _CountrySearchSheet extends StatefulWidget {
  final SeseCountryInfo? initial;

  const _CountrySearchSheet({required this.initial});

  @override
  State<_CountrySearchSheet> createState() => _CountrySearchSheetState();
}

class _CountrySearchSheetState extends State<_CountrySearchSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rawQ = _query.trim().toLowerCase();
    final cleanQ = rawQ.replaceAll('+', '').trim();

    final matches = rawQ.isEmpty
        ? SeseCountryCatalog.allCountries
        : SeseCountryCatalog.allCountries.where((c) {
            final name = c.countryName.toLowerCase();
            final code = c.countryCode.toLowerCase();
            final dial = c.dialCode.toLowerCase().replaceAll('+', '').trim();
            return name.contains(rawQ) ||
                code == rawQ ||
                dial.contains(cleanQ) ||
                c.dialCode.toLowerCase().contains(rawQ);
          }).toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Row(
                children: [
                  const Text(
                    'Select Country',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                key: const Key('country_search_field'),
                controller: _searchCtrl,
                autofocus: false,
                decoration: InputDecoration(
                  labelText: 'Search country, ISO code, or dial code',
                  hintText: 'e.g. Nigeria, NG, +234, Benin, +229',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        )
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: matches.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No countries match that search.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    )
                  : ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: matches.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 16, endIndent: 16),
                      itemBuilder: (context, i) {
                        final c = matches[i];
                        final isSel =
                            widget.initial?.countryCode == c.countryCode;
                        return ListTile(
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                          leading: Text(
                            c.flagEmoji,
                            style: const TextStyle(fontSize: 26),
                          ),
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  c.countryName,
                                  style: TextStyle(
                                    fontWeight: isSel ? FontWeight.bold : FontWeight.w500,
                                    fontSize: 15,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.grey.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  c.countryCode,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                c.dialCode,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  color: isSel
                                      ? Theme.of(context).colorScheme.primary
                                      : (Theme.of(context).brightness == Brightness.dark
                                          ? Colors.grey.shade300
                                          : Colors.grey.shade700),
                                ),
                              ),
                              if (isSel) ...[
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.check_circle,
                                  color: Theme.of(context).colorScheme.primary,
                                  size: 20,
                                ),
                              ],
                            ],
                          ),
                          onTap: () {
                            // ignore: discarded_futures
                            CountryDetectionService.instance.saveManualCountry(c.countryCode);
                            Navigator.pop(context, c);
                          },
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
