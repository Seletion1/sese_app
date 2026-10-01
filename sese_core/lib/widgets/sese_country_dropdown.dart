import 'package:flutter/material.dart';
import '../models/country_catalog.dart';

/// Reusable Country Selector withSearch for SeSe applications.
///
/// Renders every entry as `[Flag] [Country Name] ([Dial Code])` (e.g.
/// 🇳🇬 Nigeria (+234)) and opens a searchable bottom sheet (matches on name,
/// dial code, or ISO code) instead of a blind dropdown — the catalog holds
/// the full world list, which no human scrolls.
///
/// Drop-in API matches the old `DropdownButtonFormField` version
/// (`initialValue` accepts an ISO code or a country name; `onChanged`
/// emits the full [SeseCountryInfo]), so existing call sites migrate
/// without logic changes.
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
      return SeseCountryCatalog.allCountries.first;
    }
    return SeseCountryCatalog.findByCode(raw) ??
        SeseCountryCatalog.allCountries.cast<SeseCountryInfo?>().firstWhere(
              (c) =>
                  c?.countryName.toLowerCase() == raw.toLowerCase(),
              orElse: () => SeseCountryCatalog.allCountries.first,
            );
  }

  Future<void> _openPicker() async {
    if (!widget.enabled) return;
    final picked = await showModalBottomSheet<SeseCountryInfo>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _CountrySearchSheet(initial: _selected),
    );
    if (picked != null && mounted) {
      setState(() => _selected = picked);
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
            ),
        child: Row(
          children: [
            if (sel != null) ...[
              Text(sel.flagEmoji, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${sel.countryName} (${sel.dialCode})',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
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

/// Bottom sheet: search field + filtered country list.
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
    final q = _query.trim().toLowerCase();
    final matches = q.isEmpty
        ? SeseCountryCatalog.allCountries
        : SeseCountryCatalog.allCountries.where((c) {
            return c.countryName.toLowerCase().contains(q) ||
                c.dialCode.toLowerCase().contains(q) ||
                c.countryCode.toLowerCase() == q;
          }).toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                key: const Key('country_search_field'),
                controller: _searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Search country or dial code',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: matches.isEmpty
                  ? const Center(
                      child: Text('No countries match that search.'))
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: matches.length,
                      itemBuilder: (context, i) {
                        final c = matches[i];
                        final isSel =
                            widget.initial?.countryCode == c.countryCode;
                        return ListTile(
                          leading: Text(c.flagEmoji,
                              style: const TextStyle(fontSize: 20)),
                          title: Text(c.countryName),
                          subtitle: Text(c.dialCode),
                          trailing: isSel
                              ? Icon(Icons.check_circle,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary)
                              : null,
                          onTap: () => Navigator.pop(context, c),
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
