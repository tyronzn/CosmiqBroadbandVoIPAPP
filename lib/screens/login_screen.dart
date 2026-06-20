import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../theme/cosmiq_theme.dart';
import 'main_shell.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    if (username.isEmpty || password.isEmpty) return;

    FocusScope.of(context).unfocus();

    final appState = context.read<AppState>();
    final success = await appState.login(username, password);

    if (success && mounted) {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const MainShell(),
          transitionsBuilder: (_, animation, __, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          transitionDuration: const Duration(milliseconds: 300),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CosmiqColors.backgroundSecondary,
      body: SafeArea(
        child: Consumer<AppState>(
          builder: (context, appState, _) {
            return LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: IntrinsicHeight(
                      child: Column(
                        children: [
                          const SizedBox(height: 60),

                          // Logo
                          Image.asset(
                            'assets/images/cosmiq_logo_full.png',
                            width: 170,
                            errorBuilder: (_, __, ___) => Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                color: CosmiqColors.teal,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Icon(
                                Icons.phone,
                                color: Colors.white,
                                size: 30,
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),

                          // Title
                          const Text(
                            'Sign in',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w500,
                              color: CosmiqColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Use your Cosmiq account',
                            style: TextStyle(
                              fontSize: 13,
                              color: CosmiqColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 28),

                          // Input fields — iOS grouped style
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              children: [
                                // Username
                                TextField(
                                  controller: _usernameController,
                                  focusNode: _usernameFocus,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  keyboardType: TextInputType.number,
                                  textInputAction: TextInputAction.next,
                                  onSubmitted: (_) => _passwordFocus.requestFocus(),
                                  decoration: const InputDecoration(
                                    labelText: 'EXTENSION',
                                    hintText: 'Enter your extension number',
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    labelStyle: TextStyle(
                                      fontSize: 11,
                                      color: CosmiqColors.textSecondary,
                                      letterSpacing: 0.4,
                                    ),
                                  ),
                                  style: const TextStyle(fontSize: 15),
                                ),

                                // Separator
                                const Divider(
                                  height: 0.5,
                                  thickness: 0.5,
                                  indent: 16,
                                  color: CosmiqColors.separator,
                                ),

                                // Password
                                TextField(
                                  controller: _passwordController,
                                  focusNode: _passwordFocus,
                                  obscureText: _obscurePassword,
                                  textInputAction: TextInputAction.go,
                                  onSubmitted: (_) => _handleLogin(),
                                  decoration: InputDecoration(
                                    labelText: 'PASSWORD',
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    labelStyle: const TextStyle(
                                      fontSize: 11,
                                      color: CosmiqColors.textSecondary,
                                      letterSpacing: 0.4,
                                    ),
                                    suffixIcon: IconButton(
                                      icon: Icon(
                                        _obscurePassword
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                        size: 20,
                                        color: CosmiqColors.textSecondary,
                                      ),
                                      onPressed: () => setState(() =>
                                          _obscurePassword = !_obscurePassword),
                                    ),
                                  ),
                                  style: const TextStyle(fontSize: 15),
                                ),
                              ],
                            ),
                          ),

                          // Error message
                          if (appState.loginError != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                appState.loginError!,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: CosmiqColors.hangupRed,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),

                          const Spacer(),

                          // Sign In button
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: appState.isLoading ? null : _handleLogin,
                              child: appState.isLoading
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: CosmiqColors.textPrimary,
                                      ),
                                    )
                                  : const Text('Sign In'),
                            ),
                          ),
                          const SizedBox(height: 32),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
