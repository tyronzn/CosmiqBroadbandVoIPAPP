import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../theme/cosmiq_theme.dart';
import 'login_screen.dart';
import 'main_shell.dart';

/// Splash screen — shown on launch.
/// White background with Cosmiq Broadband logo.
/// Tries auto-login, then navigates to Login or MainShell.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeIn,
    );
    _fadeController.forward();
    _initAndNavigate();
  }

  Future<void> _initAndNavigate() async {
    // Show splash for at least 1.5 seconds
    await Future.delayed(const Duration(milliseconds: 1500));

    if (!mounted) return;

    final appState = context.read<AppState>();
    final autoLoginSuccess = await appState.tryAutoLogin();

    if (!mounted) return;

    // Navigate to appropriate screen
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) =>
            autoLoginSuccess ? const MainShell() : const LoginScreen(),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CosmiqColors.white,
      body: FadeTransition(
        opacity: _fadeAnimation,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo — replace with actual asset once added
              Image.asset(
                'assets/images/cosmiq_logo_full.png',
                width: 220,
                errorBuilder: (_, __, ___) => const _FallbackLogo(),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fallback logo widget if the PNG asset isn't found.
class _FallbackLogo extends StatelessWidget {
  const _FallbackLogo();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: CosmiqColors.teal,
            borderRadius: BorderRadius.circular(22),
          ),
          child: const Icon(Icons.phone, color: Colors.white, size: 48),
        ),
        const SizedBox(height: 18),
        const Text(
          'Cosmiq',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w500,
            color: CosmiqColors.textPrimary,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 2),
        const Text(
          'Broadband · Voice',
          style: TextStyle(
            fontSize: 13,
            color: CosmiqColors.textSecondary,
          ),
        ),
      ],
    );
  }
}
