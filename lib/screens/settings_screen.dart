import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../services/sip_service.dart';
import '../theme/cosmiq_theme.dart';
import '../models/server_config.dart';
import '../services/connection_settings.dart';
import 'connection_screen.dart';
import 'diagnostics_screen.dart';
import 'login_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final account = appState.accountInfo;
    final sip = appState.sip;

    return Scaffold(
      backgroundColor: CosmiqColors.backgroundSecondary,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                'Settings',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w500,
                  color: CosmiqColors.textPrimary,
                ),
              ),
            ),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  // Profile card
                  _GroupCard(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: CosmiqColors.teal,
                              ),
                              child: Center(
                                child: Text(
                                  account?.initials ?? '?',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                    color: CosmiqColors.textPrimary,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    account?.displayName ?? account?.username ?? 'User',
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  Text(
                                    'Ext. ${account?.extension ?? sip.registeredExtension ?? ''}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: CosmiqColors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),

                  // Registration status
                  _SectionHeader('Status'),
                  _GroupCard(
                    children: [
                      _SettingsRow(
                        label: 'SIP Registration',
                        value: _registrationLabel(sip.registrationState),
                        valueColor: sip.registrationState ==
                                SipRegistrationState.registered
                            ? CosmiqColors.teal
                            : CosmiqColors.hangupRed,
                        isLast: sip.lastError == null,
                      ),
                      // Show the actual reason rather than leaving a bare
                      // "Failed" for the user to guess at.
                      if (sip.lastError != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: Text(
                            sip.lastError!,
                            style: const TextStyle(
                              fontSize: 12,
                              height: 1.35,
                              color: CosmiqColors.hangupRed,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),

                  // The WebRTC gateway address is provider-specific and often
                  // needs correcting in the field, so it's editable here.
                  _SectionHeader('Connection'),
                  _GroupCard(
                    children: [
                      _SettingsRow(
                        label: 'WebRTC gateway',
                        value:
                            ConnectionSettings.isOverridden ? 'Custom' : 'Default',
                        showChevron: true,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const ConnectionScreen(),
                          ),
                        ),
                      ),
                      _SettingsRow(
                        label: 'Diagnostics',
                        value: 'Connection log',
                        showChevron: true,
                        isLast: true,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const DiagnosticsScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),

                  // Account section
                  _SectionHeader('Account'),
                  _GroupCard(
                    children: [
                      _SettingsRow(
                        label: 'Balance',
                        value: account?.formattedBalance ?? '—',
                      ),
                      _SettingsRow(
                        label: 'Plan',
                        value: account?.plan ?? '—',
                        showChevron: true,
                      ),
                      _SettingsRow(
                        label: 'Caller ID',
                        value: account?.callerId ?? '—',
                        showChevron: true,
                        isLast: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),

                  // Calls section
                  _SectionHeader('Calls'),
                  _GroupCard(
                    children: [
                      _SettingsRow(
                        label: 'Call forwarding',
                        value: account?.callForwardingEnabled == true
                            ? (account?.callForwardingNumber ?? 'On')
                            : 'Off',
                        showChevron: true,
                        onTap: () => _showForwardingDialog(context, appState),
                      ),
                      _SettingsRow(
                        label: 'Do not disturb',
                        value: account?.dndEnabled == true ? 'On' : 'Off',
                        showChevron: true,
                        onTap: () => _toggleDnd(context, appState),
                      ),
                      // WebRTC negotiates the codec itself, so a picker here
                      // would imply a choice this engine doesn't actually have.
                      _SettingsRow(
                        label: 'Audio codec',
                        value: 'Opus (automatic)',
                        isLast: true,
                        onTap: () => _showCodecInfo(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),

                  // About section
                  _SectionHeader('About'),
                  _GroupCard(
                    children: [
                      _SettingsRow(
                        label: 'App version',
                        value: ServerConfig.appVersion,
                        isLast: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),

                  // Sign out
                  _GroupCard(
                    children: [
                      InkWell(
                        onTap: () => _confirmSignOut(context, appState),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: Text(
                            'Sign Out',
                            style: TextStyle(
                              fontSize: 15,
                              color: CosmiqColors.hangupRed,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _registrationLabel(SipRegistrationState state) {
    switch (state) {
      case SipRegistrationState.registered:
        return 'Registered';
      case SipRegistrationState.registering:
        return 'Registering...';
      case SipRegistrationState.failed:
        return 'Failed';
      case SipRegistrationState.unregistered:
        return 'Unregistered';
    }
  }

  void _showForwardingDialog(BuildContext context, AppState appState) {
    final controller = TextEditingController(
      text: appState.accountInfo?.callForwardingNumber ?? '',
    );
    final isEnabled = appState.accountInfo?.callForwardingEnabled ?? false;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Call Forwarding'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              title: const Text('Enable'),
              value: isEnabled,
              onChanged: (val) {
                appState.billing.setCallForwarding(enabled: val);
                Navigator.pop(context);
              },
              activeColor: CosmiqColors.teal,
            ),
            TextField(
              controller: controller,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                hintText: 'Forward to number',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              appState.billing.setCallForwarding(
                enabled: true,
                forwardNumber: controller.text,
              );
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _toggleDnd(BuildContext context, AppState appState) {
    final current = appState.accountInfo?.dndEnabled ?? false;
    appState.billing.setDnd(!current);
  }

  void _showCodecInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Audio codec'),
        content: const Text(
          'Calls use WebRTC, which negotiates the best codec with the server '
          'automatically — normally Opus. There is nothing to choose here.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _confirmSignOut(BuildContext context, AppState appState) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await appState.logout();
              if (context.mounted) {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (_) => false,
                );
              }
            },
            child: const Text(
              'Sign Out',
              style: TextStyle(color: CosmiqColors.hangupRed),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helper widgets for iOS-style grouped settings
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          color: CosmiqColors.textSecondary,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final List<Widget> children;
  const _GroupCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final String label;
  final String value;
  final bool showChevron;
  final bool isLast;
  final Color? valueColor;
  final VoidCallback? onTap;

  const _SettingsRow({
    required this.label,
    required this.value,
    this.showChevron = false,
    this.isLast = false,
    this.valueColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: isLast
            ? null
            : const BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: CosmiqColors.separator,
                    width: 0.5,
                  ),
                ),
              ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 15),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 15,
                    color: valueColor ?? CosmiqColors.textSecondary,
                  ),
                ),
                if (showChevron) ...[
                  const SizedBox(width: 2),
                  const Text(
                    ' ›',
                    style: TextStyle(
                      fontSize: 15,
                      color: CosmiqColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
