import 'package:flutter/material.dart';
import '../models/country_states_map.dart';

/// A dynamic [DropdownButtonFormField] that lists states, provinces, or
/// administrative regions for a given country.
///
/// Pass the ISO 3166-1 alpha-2 [countryCode] (e.g. `'NG'`) to populate the
/// dropdown. When [countryCode] is `null`, empty, or not found in
/// [kCountryToStatesMap], the field is **disabled** and shows the
/// `'Select country first'` hint.
///
/// Example:
/// ```dart
/// SeseStateDropdownFormField(
///   countryCode: _selectedCountryCode,
///   value: _selectedState,
///   onChanged: (state) => setState(() => _selectedState = state),
/// )
/// ```
class SeseStateDropdownFormField extends StatelessWidget {
  /// ISO 3166-1 alpha-2 country code (e.g. `'NG'`, `'KE'`, `'US'`).
  final String? countryCode;

  /// Currently selected state/region value.
  final String? value;

  /// Called when the user picks a state. Receives `null` when the selection
  /// is cleared or the dropdown is disabled.
  final ValueChanged<String?>? onChanged;

  /// Label shown inside the dropdown's [InputDecoration].
  final String labelText;

  /// Optional custom decoration; defaults to a standard outlined field.
  final InputDecoration? decoration;

  /// Validator function for [Form] integration.
  final String? Function(String?)? validator;

  const SeseStateDropdownFormField({
    super.key,
    this.countryCode,
    this.value,
    this.onChanged,
    this.labelText = 'State / Region',
    this.decoration,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    final states = statesForCountry(countryCode);
    final hasStates = states.isNotEmpty;

    // When the current value is no longer in the state list (e.g. country
    // changed), treat the effective selection as null to avoid an assertion.
    final effectiveValue =
        (value != null && states.contains(value)) ? value : null;

    return DropdownButtonFormField<String>(
      // Flutter >=3.33 deprecates `value` in favour of `initialValue`.
      // Key by country+selection so a parent-controlled `value` change
      // (e.g. country switch clearing state) rebuilds with the new initial.
      key: ValueKey('${countryCode?.toUpperCase()}|$effectiveValue'),
      isExpanded: true,
      initialValue: effectiveValue,
      decoration: decoration ??
          InputDecoration(
            labelText: labelText,
            hintText: hasStates ? 'Select state / region' : 'Select country first',
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            // Visually dim the field when no country is chosen.
            fillColor: hasStates
                ? null
                : Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.04),
            filled: !hasStates,
          ),
      items: hasStates
          ? states
              .map((s) => DropdownMenuItem<String>(value: s, child: Text(s)))
              .toList()
          : null,
      onChanged: hasStates ? onChanged : null,
      validator: validator,
      hint: Text(
        hasStates ? 'Select state / region' : 'Select country first',
        style: TextStyle(
          color: Theme.of(context).hintColor,
          fontSize: 14,
        ),
      ),
    );
  }
}
