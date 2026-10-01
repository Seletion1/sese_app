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
  });

  @override
  State<SesePhoneInputField> createState() => _SesePhoneInputFieldState();
}

class _SesePhoneInputFieldState extends State<SesePhoneInputField> {
  late TextEditingController _internalController;
  late String _activeIsoCode;
  PhoneNumber _currentPhoneNumber = PhoneNumber();
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();
    _internalController = widget.controller ?? TextEditingController();

    // 1. Resolve initial country code (explicit prop -> detected country -> 'NG')
    _activeIsoCode = widget.initialCountryCode?.toUpperCase() ??
        CountryDetectionService.instance.currentCountryCode;

    // 2. Pre-populate initial value with sanitized digits if provided
    String initialDigits = '';
    if (widget.initialValue != null && widget.initialValue!.isNotEmpty) {
      final normalized = SesePhoneSanitizer.normalize(
        widget.initialValue!,
        defaultIsoCode: _activeIsoCode,
      );
      final dial = SesePhoneSanitizer.getDialCode(_activeIsoCode);
      if (normalized.startsWith(dial)) {
        initialDigits = normalized.substring(dial.length);
      } else {
        initialDigits = normalized;
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
    if (widget.controller == null) {
      _internalController.dispose();
    }
    super.dispose();
  }

  void _handleInputChanged(PhoneNumber number) {
    _currentPhoneNumber = number;
    _activeIsoCode = number.isoCode ?? _activeIsoCode;

    // Sanitize to strict E.164 (strips leading zero if user typed 080... with +234)
    final rawNumber = number.phoneNumber ?? '';
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

    final defaultDecoration = InputDecoration(
      labelText: widget.labelText,
      hintText: widget.hintText,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
