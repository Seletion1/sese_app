import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sese_core/sese_core.dart';

import 'auth_screen.dart';

/// Role Selection Entry Gateway (`WelcomeRoleSelectionScreen`) for sese_ride.
///
/// Refactored initial onboarding gateway featuring:
/// 1. Continuous pulsing/breathing glowing SeSe brand logo at top center.
/// 2. Clear, uncluttered role selection cards for Rider/Customer and Driver/Delivery Partner.
/// 3. Direct account sign-in link for returning users.
/// 4. Integrated legal disclaimer footer with interactive Terms & Privacy viewer.
class WelcomeRoleSelectionScreen extends StatefulWidget {
  final AuthRepository? auth;

  const WelcomeRoleSelectionScreen({
    super.key,
    this.auth,
  });

  @override
  State<WelcomeRoleSelectionScreen> createState() =>
      _WelcomeRoleSelectionScreenState();
}

class _WelcomeRoleSelectionScreenState extends State<WelcomeRoleSelectionScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _logoAnimationController;

  static const Color _seseGold = AppColors.seseGold;

  @override
  void initState() {
    super.initState();
    _logoAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _logoAnimationController.dispose();
    super.dispose();
  }

  void _navigateToAuth({required UserRole role, required bool isSignUp}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AuthScreen(
          auth: widget.auth,
          initialRole: role,
          initialSignUpMode: isSignUp,
        ),
      ),
    );
  }

  DateTime? _lastBackPressTime;

  void _handlePopInvoked(bool didPop) {
    if (didPop) return;
    final now = DateTime.now();
    if (_lastBackPressTime == null ||
        now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
      _lastBackPressTime = now;
      ScaffoldMessenger.of(context).removeCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Press back again to exit'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) => _handlePopInvoked(didPop),
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                // 16px gutters: cards span edge-to-edge on phones instead of
                // sitting in a narrow 24px-inset column.
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 20.0),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 40.0,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                    const SizedBox(height: 12),

                    // ─── Header: Animated Glowing Logo + Headlines ──────────────
                    Column(
                      children: [
                        // Pulsing / Breathing Animated Glowing Logo
                        AnimatedBuilder(
                          animation: _logoAnimationController,
                          builder: (context, child) {
                            final t = _logoAnimationController.value;
                            return Container(
                              width: 120,
                              height: 120,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                                boxShadow: [
                                  BoxShadow(
                                    color: _seseGold.withValues(alpha: 0.35 + (t * 0.40)),
                                    blurRadius: 16.0 + (t * 24.0),
                                    spreadRadius: 2.0 + (t * 8.0),
                                  ),
                                  BoxShadow(
                                    color: _seseGold.withValues(alpha: 0.15 + (t * 0.25)),
                                    blurRadius: 30.0 + (t * 30.0),
                                    spreadRadius: 6.0 + (t * 12.0),
                                  ),
                                ],
                              ),
                              padding: const EdgeInsets.all(16),
                              child: const SeSeLogo(
                                size: 88,
                                variant: SeSeLogoVariant.ride,
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 28),
                        Text(
                          'Welcome to SeSe',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Choose how you want to use the app',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.textTheme.bodyMedium?.color
                                ?.withValues(alpha: 0.75),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),

                    const SizedBox(height: 32),

                    // ─── Role Action Cards ──────────────────────────────────────
                    Column(
                      children: [
                        _RoleSelectionCard(
                          key: const Key('role_card_customer'),
                          title: 'Rider / Customer',
                          subtitle: 'Book rides & send deliveries',
                          icon: Icons.person_outline_rounded,
                          onTap: () => _navigateToAuth(
                            role: UserRole.customer,
                            isSignUp: false,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _RoleSelectionCard(
                          key: const Key('role_card_driver'),
                          title: 'Driver / Delivery Partner',
                          subtitle: 'Get a vehicle and start earning with us',
                          icon: Icons.directions_car_filled_rounded,
                          onTap: () => _navigateToAuth(
                            role: UserRole.driver,
                            isSignUp: false,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 32),

                    // ─── Direct Sign In Link & Legal Disclaimer ─────────────────
                    Column(
                      children: [
                        // Direct Sign In for returning users
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Already have an account? ',
                              style: TextStyle(
                                fontSize: 14,
                                color: theme.textTheme.bodyMedium?.color
                                    ?.withValues(alpha: 0.75),
                              ),
                            ),
                            GestureDetector(
                              key: const Key('direct_sign_in_button'),
                              onTap: () => _navigateToAuth(
                                role: UserRole.customer,
                                isSignUp: false,
                              ),
                              child: const Text(
                                'Sign In',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: _seseGold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        // Legal Disclaimer Footer
                        const LegalAuthDisclaimer(),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
          ),
        ),
      ),
    );
  }
}

/// Custom styled Role Selection Action Card.
class _RoleSelectionCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  const _RoleSelectionCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  @override
  State<_RoleSelectionCard> createState() => _RoleSelectionCardState();
}

class _RoleSelectionCardState extends State<_RoleSelectionCard> {
  bool _isHovered = false;

  static const Color _seseGold = AppColors.seseGold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final cardBg = isDark
        ? const Color(0xFF1E1E1E)
        : theme.cardColor;

    // width: double.infinity forces the card to span the full gutter
    // width (Column(center) would otherwise let it shrink-wrap).
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _isHovered
              ? _seseGold
              : _seseGold.withValues(alpha: 0.35),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: _isHovered
                ? _seseGold.withValues(alpha: 0.2)
                : Colors.black.withValues(alpha: isDark ? 0.3 : 0.05),
            blurRadius: _isHovered ? 14 : 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onHighlightChanged: (highlighted) {
            setState(() => _isHovered = highlighted);
          },
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 20.0),
            child: Row(
              children: [
                // Icon Avatar
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _seseGold.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    widget.icon,
                    size: 28,
                    color: _seseGold,
                  ),
                ),
                const SizedBox(width: 16),

                // Title & Subtitle
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.subtitle,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.textTheme.bodyMedium?.color
                              ?.withValues(alpha: 0.7),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),

                // Trailing Arrow
                Icon(
                  Icons.arrow_forward_rounded,
                  color: _isHovered ? _seseGold : theme.iconTheme.color?.withValues(alpha: 0.5),
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
