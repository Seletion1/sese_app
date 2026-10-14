import 'package:flutter/material.dart';
import '../financial/exchange_rate_service.dart';
import '../financial/exchange_rates.dart';

/// Dynamic multi-currency display widget.
///
/// Takes a base NGN amount (or kobo amount) and streams platform exchange rates
/// to display converted amounts dynamically for foreign or local users.
class MultiCurrencyDisplay extends StatelessWidget {
  /// Amount in base NGN (e.g. 1000.0)
  final double ngnAmount;

  /// Optional target currency code (e.g. 'USD', 'EUR', 'GBP', 'KES', 'GHS').
  /// Defaults to 'USD' when target is non-NGN.
  final String targetCurrencyCode;

  /// TextStyle for the base NGN text
  final TextStyle? baseStyle;

  /// TextStyle for the converted secondary currency text
  final TextStyle? convertedStyle;

  /// Whether to display in inline format: "₦1,000.00 (≈ $0.63 USD)" vs stacked
  final bool inline;

  /// Test seam: optional service stream override
  final ExchangeRateService? exchangeRateService;

  const MultiCurrencyDisplay({
    super.key,
    required this.ngnAmount,
    this.targetCurrencyCode = 'USD',
    this.baseStyle,
    this.convertedStyle,
    this.inline = true,
    this.exchangeRateService,
  });

  /// Factory constructor for kobo amounts.
  factory MultiCurrencyDisplay.fromKobo({
    Key? key,
    required int amountKobo,
    String targetCurrencyCode = 'USD',
    TextStyle? baseStyle,
    TextStyle? convertedStyle,
    bool inline = true,
    ExchangeRateService? exchangeRateService,
  }) {
    return MultiCurrencyDisplay(
      key: key,
      ngnAmount: amountKobo / 100.0,
      targetCurrencyCode: targetCurrencyCode,
      baseStyle: baseStyle,
      convertedStyle: convertedStyle,
      inline: inline,
      exchangeRateService: exchangeRateService,
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = exchangeRateService ?? const ExchangeRateService();
    final target = targetCurrencyCode.toUpperCase();

    return StreamBuilder<ExchangeRates>(
      stream: service.streamExchangeRates(),
      builder: (context, snapshot) {
        final rates = snapshot.data ?? const ExchangeRates();
        final baseFormatted = rates.formatNgnAmount(ngnAmount, 'NGN');

        if (target == 'NGN') {
          return Text(baseFormatted, style: baseStyle);
        }

        final convertedFormatted = rates.formatNgnAmount(
          ngnAmount,
          target,
          showCode: true,
        );

        if (inline) {
          return Text(
            '$baseFormatted (≈ $convertedFormatted)',
            style: baseStyle,
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(baseFormatted, style: baseStyle),
            const SizedBox(height: 2),
            Text(
              '≈ $convertedFormatted',
              style: convertedStyle ??
                  TextStyle(
                    fontSize: (baseStyle?.fontSize ?? 14) * 0.75,
                    color: Colors.grey.shade600,
                  ),
            ),
          ],
        );
      },
    );
  }
}
