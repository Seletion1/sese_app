import 'package:flutter/material.dart';
import 'package:intl_phone_number_input/intl_phone_number_input.dart';

import '../models/country_catalog.dart';
import '../services/country_detection_service.dart';
import '../services/phone_sanitizer.dart';
import 'sese_country_dropdown.dart';

/// Robust, unified phone input widget for SeSe applications.
///
/// Features:
/// 1. Complete input freedom: Accepts any valid format (`08161561592`,
///    `+2348161561592`, `8161561592`, `+22997123456`) without restrictive
///    formatters fighting or blocking user typing.
/// 2. Automatic country detection via [CountryDetectionService] (GPS coordinates ->
///    device timezone -> locale check -> Nigeria default).
/// 3. Responsive, full-width edge-to-edge country picker with search bar via [CountryPickerSheet].
/// 4. Persistent manual override stored across app launches in SharedPreferences.
/// 5. Live E.164 normalization & leading zero sanitization via [SesePhoneSanitizer],
///    ensuring zero duplicate country codes appear on driver screens.
class SesePhoneInputField extends StatefulWidget {
  final TextEditingController? controller;
  final String? initialValue;
  final String? initialCountryCode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<PhoneNumber>? onPhoneNumberChanged;
  final ValueChanged<bool>? onValidated;
  final FormFieldValidator<String>? validator;
  final String labelText;
  final String hintText;
  final bool enabled;
  final bool autofocus;
  final FocusNode? focusNode;
  final AutovalidateMode autoValidateMode;
  final PhoneInputSelectorType selectorType;
  final InputDecoration? decoration;
  final Widget? suffixIcon;
  final VoidCallback? onPickContact;

  const SesePhoneInputField({
    super.key,
    this.controller,
    this.initialValue,
    this.initialCountryCode,
    this.onChanged,
    this.onPhoneNumberChanged,
    this.onValidated,
    this.validator,
    this.labelText = 'Phone Number',
    this.hintText = '801 234 5678',
    this.enabled = true,
    this.autofocus = false,
    this.focusNode,
    this.autoValidateMode = AutovalidateMode.disabled,
    this.selectorType = PhoneInputSelectorType.BOTTOM_SHEET,
    this.decoration,
    this.suffixIcon,
    this.onPickContact,
  });

  @override
  State<SesePhoneInputField> createState() => _SesePhoneInputFieldState();
}

class _SesePhoneInputFieldState extends State<SesePhoneInputField> {
  late TextEditingController _internalController;
  late String _activeIsoCode;
  bool _isDisposed = false;
  bool _isFormattingInternal = false;

  @override
  void initState() {
    super.initState();
    _internalController = widget.controller ?? TextEditingController();
    _internalController.addListener(_handleControllerChanged);

    // 1. Resolve initial country code (explicit prop -> detected country -> 'NG')
    _activeIsoCode = widget.initialCountryCode?.toUpperCase() ??
        CountryDetectionService.instance.currentCountryCode;

    // 2. Pre-populate initial value with sanitized digits if provided
    if (widget.initialValue != null && widget.initialValue!.isNotEmpty) {
      final parsed = SesePhoneSanitizer.parse(
        widget.initialValue!,
        defaultIsoCode: _activeIsoCode,
      );
      _activeIsoCode = parsed.isoCode;
      if (_internalController.text.isEmpty) {
        _internalController.text = parsed.nationalNumber.isNotEmpty
            ? parsed.nationalNumber
            : widget.initialValue!;
      }
    } else if (_internalController.text.trim().isNotEmpty) {
      final pre = SesePhoneSanitizer.parse(
        _internalController.text,
        defaultIsoCode: _activeIsoCode,
      );
      if (pre.hasExplicitCountryPrefix) {
        _activeIsoCode = pre.isoCode;
        _isFormattingInternal = true;
        _internalController.value = TextEditingValue(
          text: pre.nationalNumber,
          selection: TextSelection.collapsed(offset: pre.nationalNumber.length),
        );
        _isFormattingInternal = false;
      }
    }

    // Trigger initial detection in background if not already cached
    CountryDetectionService.instance.detectCountryCode().then((code) {
      if (!_isDisposed && widget.initialCountryCode == null && mounted) {
        if (_activeIsoCode != code && _internalController.text.isEmpty) {
          setState(() {
            _activeIsoCode = code;
          });
        }
      }
    });
  }

  @override
  void didUpdateWidget(covariant SesePhoneInputField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != null && widget.controller != oldWidget.controller) {
      _internalController.removeListener(_handleControllerChanged);
      _internalController = widget.controller!;
      _internalController.addListener(_handleControllerChanged);
    }
    if (widget.initialCountryCode != null &&
        widget.initialCountryCode != oldWidget.initialCountryCode) {
      _activeIsoCode = widget.initialCountryCode!.toUpperCase();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _internalController.removeListener(_handleControllerChanged);
    if (widget.controller == null) {
      _internalController.dispose();
    }
    super.dispose();
  }

  void _handleControllerChanged() {
    if (_isFormattingInternal) return;
    final rawText = _internalController.text;
    if (rawText.isEmpty) {
      widget.onChanged?.call('');
      widget.onValidated?.call(true);
      return;
    }

    // If user pasted/typed a number with explicit '+' or dial code, adapt country
    final parsed = SesePhoneSanitizer.parse(rawText, defaultIsoCode: _activeIsoCode);
    if (parsed.hasExplicitCountryPrefix && parsed.isoCode != _activeIsoCode) {
      _activeIsoCode = parsed.isoCode;
      if (mounted) setState(() {});
    }

    _notifyCurrentValue();
  }

  void _notifyCurrentValue() {
    final rawText = _internalController.text.trim();
    final normalized = rawText.isEmpty
        ? ''
        : SesePhoneSanitizer.normalize(
            rawText,
            defaultIsoCode: _activeIsoCode,
          );

    widget.onChanged?.call(normalized);

    final country = SeseCountryCatalog.findByCode(_activeIsoCode);
    final dial = country?.dialCode ?? SesePhoneSanitizer.getDialCode(_activeIsoCode);
    widget.onPhoneNumberChanged?.call(
      PhoneNumber(
        phoneNumber: normalized,
        isoCode: _activeIsoCode,
        dialCode: dial,
      ),
    );

    widget.onValidated?.call(
      rawText.isEmpty || SesePhoneSanitizer.isValidE164(normalized),
    );
  }

  Future<void> _openCountryPicker() async {
    if (!widget.enabled) return;
    final picked = await CountryPickerSheet.show(
      context,
      initialCountryCode: _activeIsoCode,
    );

    if (picked != null && mounted) {
      setState(() {
        _activeIsoCode = picked.countryCode;
      });
      // Persist manual user selection
      await CountryDetectionService.instance.saveManualCountry(picked.countryCode);
      _notifyCurrentValue();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final country = SeseCountryCatalog.findByCode(_activeIsoCode) ??
        SeseCountryCatalog.findByCode('NG') ??
        SeseCountryInfo(
          countryCode: _activeIsoCode,
          countryName: 'Nigeria',
          flagEmoji: CountryDetectionService.countryCodeToEmoji(_activeIsoCode),
          dialCode: SesePhoneSanitizer.getDialCode(_activeIsoCode),
          currencyCode: 'NGN',
          currencySymbol: '₦',
        );

    final effectiveSuffixIcon = widget.onPickContact != null
        ? IconButton(
            key: const Key('pick_contact_button'),
            icon: Icon(
              Icons.contacts_rounded,
              color: theme.primaryColor,
            ),
            tooltip: 'Select from contacts',
            onPressed: widget.enabled ? widget.onPickContact : null,
          )
        : widget.suffixIcon;

    final prefixSelector = Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('country_picker_prefix_button'),
        onTap: widget.enabled ? _openCountryPicker : null,
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                country.flagEmoji,
                style: const TextStyle(fontSize: 20),
              ),
              const SizedBox(width: 4),
              Text(
                country.dialCode,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.arrow_drop_down,
                size: 18,
                color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
              ),
              const SizedBox(width: 4),
              Container(
                width: 1,
                height: 20,
                color: theme.dividerColor.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );

    final inputDec = (widget.decoration ?? const InputDecoration()).copyWith(
      labelText: widget.labelText,
      hintText: widget.hintText,
      prefixIcon: prefixSelector,
      prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
      suffixIcon: effectiveSuffixIcon,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );

    return TextFormField(
      key: const Key('sese_phone_input_field'),
      controller: _internalController,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      keyboardType: TextInputType.phone,
      autovalidateMode: widget.autoValidateMode,
      style: TextStyle(
        fontSize: 15,
        color: isDark ? Colors.white : Colors.black87,
      ),
      decoration: inputDec,
      validator: (val) {
        if (widget.validator != null) {
          return widget.validator!(val);
        }
        // Non-intrusive default: allow typing freely, empty is always valid
        if (val == null || val.trim().isEmpty) return null;
        final digits = val.replaceAll(RegExp(r'\D'), '');
        if (digits.length < 6) {
          return 'Please enter a complete phone number';
        }
        return null;
      },
    );
  }
}
