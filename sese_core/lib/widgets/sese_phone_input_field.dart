import 'package:flutter/material.dart';
import 'package:intl_phone_number_input/intl_phone_number_input.dart';

import '../services/country_detection_service.dart';
import '../services/phone_sanitizer.dart';

/// Robust, unified phone input widget for SeSe applications.
///
/// Features:
/// 1. Built-in ISO 3166-1 country dataset from [intl_phone_number_input] with zero hardcoded manual lists.
/// 2. Automatic startup country detection via [CountryDetectionService] (SIM/Locale -> Timezone -> Nigeria default).
/// 3. Country picker dropdown with flag emojis and international dial codes allowing manual override.
/// 4. Live E.164 normalization & leading zero sanitization via [SesePhoneSanitizer].
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
    this.selectorType = PhoneInputSelectorType.DROPDOWN,
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
  PhoneNumber _currentPhoneNumber = PhoneNumber();
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
    String initialDigits = '';
    if (widget.initialValue != null && widget.initialValue!.isNotEmpty) {
      final parsed = SesePhoneSanitizer.parse(
        widget.initialValue!,
        defaultIsoCode: _activeIsoCode,
      );
      _activeIsoCode = parsed.isoCode;
      initialDigits = parsed.nationalNumber;
    } else if (_internalController.text.trim().isNotEmpty) {
      // 2b. Externally-owned controller pre-fill guard (double-prefix fix).
      // When the parent owns the controller and seeds it with an already-
      // international number (e.g. dispatch pre-fills `user.phoneNumber`
      // which is stored E.164 as `+234801...`), the raw text still carries
      // the country prefix while the selector ALSO renders +234 — showing
      // `+234 +23481...`. Strip to national digits now so the box holds
      // only the subscriber number; [_handleControllerChanged] keeps all
      // later keystrokes/pastes clean. Local numbers (no prefix) pass
      // through untouched.
      final pre = SesePhoneSanitizer.parse(
        _internalController.text,
        defaultIsoCode: _activeIsoCode,
      );
      if (pre.hasExplicitCountryPrefix) {
        _activeIsoCode = pre.isoCode;
        initialDigits = pre.nationalNumber;
        _isFormattingInternal = true;
        _internalController.value = TextEditingValue(
          text: pre.nationalNumber,
          selection:
              TextSelection.collapsed(offset: pre.nationalNumber.length),
        );
        _isFormattingInternal = false;
      }
    }

    _currentPhoneNumber = PhoneNumber(
      isoCode: _activeIsoCode,
      phoneNumber: initialDigits,
    );

    // Trigger initial detection in background if not already cached
    CountryDetectionService.instance.detectCountryCode().then((code) {
      if (!_isDisposed && widget.initialCountryCode == null && mounted) {
        if (_activeIsoCode != code) {
          setState(() {
            _activeIsoCode = code;
            _currentPhoneNumber = PhoneNumber(
              isoCode: code,
              phoneNumber: _internalController.text,
            );
          });
        }
      }
    });
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
    if (rawText.isEmpty) return;

    final parsed = SesePhoneSanitizer.parse(rawText, defaultIsoCode: _activeIsoCode);
    if (parsed.hasExplicitCountryPrefix) {
      _isFormattingInternal = true;
      final cleanDigits = parsed.nationalNumber;
      final newIso = parsed.isoCode;

      if (newIso != _activeIsoCode || rawText.contains(parsed.dialCode)) {
        _activeIsoCode = newIso;
        _currentPhoneNumber = PhoneNumber(
          isoCode: _activeIsoCode,
          phoneNumber: cleanDigits,
        );

        _internalController.value = TextEditingValue(
          text: cleanDigits,
          selection: TextSelection.collapsed(offset: cleanDigits.length),
        );

        if (mounted) {
          setState(() {});
        }
      }
      _isFormattingInternal = false;
    }
  }

  void _handleInputChanged(PhoneNumber number) {
    _currentPhoneNumber = number;
    _activeIsoCode = number.isoCode ?? _activeIsoCode;

    // Sanitize to strict E.164 (strips leading zero if user typed 080... with +234)
    final rawNumber = number.phoneNumber ?? _internalController.text;
    final normalized = SesePhoneSanitizer.normalize(
      rawNumber,
      defaultIsoCode: _activeIsoCode,
    );

    widget.onChanged?.call(normalized);
    widget.onPhoneNumberChanged?.call(number);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final effectiveSuffixIcon = widget.onPickContact != null
        ? IconButton(
            key: const Key('pick_contact_button'),
            icon: Icon(
              Icons.contacts_rounded,
              color: theme.primaryColor,
            ),
            tooltip: 'Select from contacts',
            onPressed: widget.onPickContact,
          )
        : widget.suffixIcon;

    final defaultDecoration = (widget.decoration ?? const InputDecoration()).copyWith(
      labelText: widget.labelText,
      hintText: widget.hintText,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      suffixIcon: effectiveSuffixIcon,
    );

    return InternationalPhoneNumberInput(
      key: const Key('sese_phone_input_field'),
      textFieldController: _internalController,
      focusNode: widget.focusNode,
      autoFocus: widget.autofocus,
      isEnabled: widget.enabled,
      autoValidateMode: widget.autoValidateMode,
      initialValue: _currentPhoneNumber,
      onInputChanged: _handleInputChanged,
      onInputValidated: widget.onValidated,
      validator: widget.validator ??
          (val) {
            if (val == null || val.trim().isEmpty) {
              return 'Please enter a valid phone number';
            }
            final normalized = SesePhoneSanitizer.normalize(
              val,
              defaultIsoCode: _activeIsoCode,
            );
            if (!SesePhoneSanitizer.isValidE164(normalized)) {
              return 'Invalid international phone number';
            }
            return null;
          },
      selectorConfig: SelectorConfig(
        selectorType: widget.selectorType,
        setSelectorButtonAsPrefixIcon: true,
        leadingPadding: 12,
        useEmoji: true,
      ),
      searchBoxDecoration: InputDecoration(
        labelText: 'Search country name or dial code',
        hintText: 'e.g. Nigeria, +234, Canada, +1',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      selectorTextStyle: TextStyle(
        color: theme.textTheme.bodyMedium?.color ?? Colors.black87,
        fontWeight: FontWeight.w600,
        fontSize: 14,
      ),
      textStyle: TextStyle(
        color: theme.textTheme.bodyMedium?.color ?? Colors.black87,
        fontSize: 15,
      ),
      inputDecoration: widget.decoration ?? defaultDecoration,
      formatInput: true,
      keyboardType: const TextInputType.numberWithOptions(
        signed: true,
        decimal: false,
      ),
    );
  }
}
