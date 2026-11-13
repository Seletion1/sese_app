import 'package:flutter_test/flutter_test.dart';
import 'package:sese_core/sese_core.dart';

void main() {
  group('Wallet Balance Validation & Hub Threshold Tests', () {
    test('WalletCalculationEngine.isEligibleToGoOnline verifies balance >= min threshold', () {
      // ₦5,000.00 vs ₦1.00 threshold -> pass
      expect(
        WalletCalculationEngine.isEligibleToGoOnline(
          walletBalanceNaira: 5000.0,
          minBalanceNaira: 1.0,
        ),
        isTrue,
      );

      // Exact ₦1.00 vs ₦1.00 threshold -> pass
      expect(
        WalletCalculationEngine.isEligibleToGoOnline(
          walletBalanceNaira: 1.0,
          minBalanceNaira: 1.0,
        ),
        isTrue,
      );

      // ₦0.50 vs ₦1.00 threshold -> fail
      expect(
        WalletCalculationEngine.isEligibleToGoOnline(
          walletBalanceNaira: 0.5,
          minBalanceNaira: 1.0,
        ),
        isFalse,
      );

      // ₦0.00 vs ₦1.00 threshold -> fail
      expect(
        WalletCalculationEngine.isEligibleToGoOnline(
          walletBalanceNaira: 0.0,
          minBalanceNaira: 1.0,
        ),
        isFalse,
      );

      // Negative balance vs ₦1.00 threshold -> fail
      expect(
        WalletCalculationEngine.isEligibleToGoOnline(
          walletBalanceNaira: -500.0,
          minBalanceNaira: 1.0,
        ),
        isFalse,
      );
    });

    test('FinancialConfig defaults minWalletBalanceToOnline to ₦1.00', () {
      const config = FinancialConfig();
      expect(config.minWalletBalanceToOnline, 1.0);
    });

    test('FinancialConfig parses custom Hub minWalletBalanceToOnline correctly', () {
      final config = FinancialConfig.fromMap(const {
        'minWalletBalanceToOnline': 500.0,
      });
      expect(config.minWalletBalanceToOnline, 500.0);

      // Custom Hub threshold comparison
      expect(
        WalletCalculationEngine.isEligibleToGoOnline(
          walletBalanceNaira: 5000.0,
          minBalanceNaira: config.minWalletBalanceToOnline,
        ),
        isTrue,
      );
      expect(
        WalletCalculationEngine.isEligibleToGoOnline(
          walletBalanceNaira: 100.0,
          minBalanceNaira: config.minWalletBalanceToOnline,
        ),
        isFalse,
      );
    });
  });
}
