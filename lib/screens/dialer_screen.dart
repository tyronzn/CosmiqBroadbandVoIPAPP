import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../services/sip_service.dart';
import '../theme/cosmiq_theme.dart';
import 'incall_screen.dart';

class DialerScreen extends StatefulWidget {
  const DialerScreen({super.key});

  @override
  State<DialerScreen> createState() => _DialerScreenState();
}

class _DialerScreenState extends State<DialerScreen> {
  String _dialedNumber = '';

  void _onKeyTap(String key) {
    HapticFeedback.lightImpact();
    setState(() => _dialedNumber += key);
  }

  void _onBackspace() {
    if (_dialedNumber.isNotEmpty) {
      HapticFeedback.lightImpact();
      setState(() =>
          _dialedNumber = _dialedNumber.substring(0, _dialedNumber.length - 1));
    }
  }

  void _onCall() {
    if (_dialedNumber.isEmpty) return;

    final sip = context.read<AppState>().sip;
    sip.makeCall(_dialedNumber);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InCallScreen(remoteNumber: _dialedNumber),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sip = context.watch<AppState>().sip;
    final extension = sip.registeredExtension ?? '';
    final isRegistered =
        sip.registrationState == SipRegistrationState.registered;

    return Scaffold(
      backgroundColor: CosmiqColors.white,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 16),

            // Dialed number display
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _dialedNumber.isEmpty ? ' ' : _dialedNumber,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 1,
                        color: CosmiqColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isRegistered
                                ? CosmiqColors.registeredGreen
                                : CosmiqColors.hangupRed,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Ext. $extension · ${isRegistered ? "Registered" : "Disconnected"}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: CosmiqColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
            ),

            const SizedBox(height: 8),

            // Keypad
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildKeyRow(['1', '2', '3'],
                        subs: ['', 'ABC', 'DEF']),
                    const SizedBox(height: 14),
                    _buildKeyRow(['4', '5', '6'],
                        subs: ['GHI', 'JKL', 'MNO']),
                    const SizedBox(height: 14),
                    _buildKeyRow(['7', '8', '9'],
                        subs: ['PQRS', 'TUV', 'WXYZ']),
                    const SizedBox(height: 14),
                    _buildKeyRow(['*', '0', '#'],
                        subs: ['', '+', '']),
                  ],
                ),
              ),
            ),

            // Call button + backspace
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Spacer to center call button
                  const SizedBox(width: 70),
                  // Call button
                  GestureDetector(
                    onTap: _onCall,
                    child: Container(
                      width: 70,
                      height: 70,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: CosmiqColors.callGreen,
                      ),
                      child: const Icon(
                        Icons.phone,
                        color: CosmiqColors.textPrimary,
                        size: 32,
                      ),
                    ),
                  ),
                  // Backspace
                  SizedBox(
                    width: 70,
                    child: _dialedNumber.isNotEmpty
                        ? IconButton(
                            onPressed: _onBackspace,
                            onLongPress: () =>
                                setState(() => _dialedNumber = ''),
                            icon: const Icon(
                              Icons.backspace_outlined,
                              color: CosmiqColors.textSecondary,
                              size: 24,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeyRow(List<String> keys, {required List<String> subs}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: List.generate(keys.length, (i) {
        return _DialKey(
          digit: keys[i],
          sub: subs[i],
          onTap: () => _onKeyTap(keys[i]),
        );
      }),
    );
  }
}

class _DialKey extends StatelessWidget {
  final String digit;
  final String sub;
  final VoidCallback onTap;

  const _DialKey({
    required this.digit,
    required this.sub,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 64,
        height: 64,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: CosmiqColors.backgroundSecondary,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              digit == '*' ? '∗' : digit,
              style: TextStyle(
                fontSize: digit == '*' ? 30 : 26,
                fontWeight: FontWeight.w400,
                color: CosmiqColors.textPrimary,
                height: 1,
              ),
            ),
            if (sub.isNotEmpty)
              Text(
                sub,
                style: const TextStyle(
                  fontSize: 9,
                  letterSpacing: 1.5,
                  color: CosmiqColors.textSecondary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
