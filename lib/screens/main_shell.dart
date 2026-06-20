import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../services/sip_service.dart';
import '../theme/cosmiq_theme.dart';
import 'dialer_screen.dart';
import 'history_screen.dart';
import 'voicemail_screen.dart';
import 'settings_screen.dart';
import 'incall_screen.dart';

/// Main app shell with bottom navigation.
/// Contains four tabs: Keypad, Recents, Voicemail, Settings.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  final _screens = const [
    DialerScreen(),
    HistoryScreen(),
    VoicemailScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    // Listen for incoming calls to auto-navigate to in-call screen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final sip = context.read<AppState>().sip;
      sip.addListener(_onSipStateChanged);
    });
  }

  void _onSipStateChanged() {
    final sip = context.read<AppState>().sip;

    // Auto-navigate to in-call screen on incoming call
    if (sip.callState == SipCallState.ringing) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => InCallScreen(
            remoteNumber: sip.remoteIdentity,
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    try {
      context.read<AppState>().sip.removeListener(_onSipStateChanged);
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: CosmiqColors.separator, width: 0.5),
          ),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) => setState(() => _currentIndex = index),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.dialpad),
              label: 'Keypad',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.history),
              label: 'Recents',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.voicemail),
              label: 'Voicemail',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}
