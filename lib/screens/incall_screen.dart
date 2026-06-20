import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../services/sip_service.dart';
import '../theme/cosmiq_theme.dart';

class InCallScreen extends StatefulWidget {
  final String remoteNumber;
  final String? remoteName;

  const InCallScreen({
    super.key,
    required this.remoteNumber,
    this.remoteName,
  });

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> {
  Timer? _durationTimer;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final sip = context.read<AppState>().sip;
      if (sip.callState == SipCallState.confirmed && sip.callStartTime != null) {
        setState(() {
          _duration = DateTime.now().difference(sip.callStartTime!);
        });
      }
    });
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:$m:$s';
    }
    return '$m:$s';
  }

  String _callStateLabel(SipCallState state) {
    switch (state) {
      case SipCallState.calling:
        return 'Calling...';
      case SipCallState.ringing:
        return 'Ringing...';
      case SipCallState.confirmed:
        return _formatDuration(_duration);
      case SipCallState.held:
        return 'On Hold';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final sip = context.watch<AppState>().sip;
    final displayName = widget.remoteName ?? widget.remoteNumber;
    final initials = _getInitials(displayName);

    // Auto-pop when call ends
    if (sip.callState == SipCallState.none) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [CosmiqColors.inCallBg, CosmiqColors.inCallBgEnd],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 40),

                // Caller name + status
                Text(
                  displayName,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w400,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _callStateLabel(sip.callState),
                  style: TextStyle(
                    fontSize: 15,
                    color: Colors.white.withOpacity(0.6),
                  ),
                ),

                const SizedBox(height: 50),

                // Avatar circle
                Container(
                  width: 130,
                  height: 130,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: CosmiqColors.teal.withOpacity(0.18),
                    border: Border.all(
                      color: CosmiqColors.teal.withOpacity(0.4),
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      initials,
                      style: const TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.w300,
                        color: CosmiqColors.teal,
                      ),
                    ),
                  ),
                ),

                const Spacer(),

                // Call action buttons — 3x2 grid
                GridView.count(
                  shrinkWrap: true,
                  crossAxisCount: 3,
                  mainAxisSpacing: 22,
                  crossAxisSpacing: 22,
                  childAspectRatio: 0.9,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _CallAction(
                      icon: Icons.mic_off,
                      label: 'mute',
                      isActive: sip.isMuted,
                      onTap: sip.toggleMute,
                    ),
                    _CallAction(
                      icon: Icons.dialpad,
                      label: 'keypad',
                      onTap: () => _showDtmfPad(context, sip),
                    ),
                    _CallAction(
                      icon: Icons.volume_up,
                      label: 'speaker',
                      isActive: sip.isSpeaker,
                      onTap: sip.toggleSpeaker,
                    ),
                    _CallAction(
                      icon: Icons.person_add,
                      label: 'add call',
                      onTap: () {}, // Future: conference
                    ),
                    _CallAction(
                      icon: Icons.pause,
                      label: 'hold',
                      isActive: sip.isHeld,
                      onTap: sip.toggleHold,
                    ),
                    _CallAction(
                      icon: Icons.phone_forwarded,
                      label: 'transfer',
                      onTap: () => _showTransferDialog(context, sip),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // Hang up button
                GestureDetector(
                  onTap: () => sip.hangUp(),
                  child: Container(
                    width: 68,
                    height: 68,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: CosmiqColors.hangupRed,
                    ),
                    child: const Icon(
                      Icons.call_end,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                ),

                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _getInitials(String name) {
    final parts = name.replaceAll(RegExp(r'[^a-zA-Z\s]'), '').trim().split(' ');
    if (parts.length >= 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    if (parts.isNotEmpty && parts[0].isNotEmpty) {
      return parts[0][0].toUpperCase();
    }
    return '?';
  }

  void _showDtmfPad(BuildContext context, SipService sip) {
    showModalBottomSheet(
      context: context,
      backgroundColor: CosmiqColors.inCallBg,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
              ['*', '0', '#']
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: row
                      .map((d) => GestureDetector(
                            onTap: () => sip.sendDtmf(d),
                            child: Container(
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withOpacity(0.15),
                              ),
                              child: Center(
                                child: Text(
                                  d,
                                  style: const TextStyle(
                                    fontSize: 24,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ))
                      .toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showTransferDialog(BuildContext context, SipService sip) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Transfer Call'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            hintText: 'Enter extension or number',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                sip.transferCall(controller.text);
                Navigator.pop(context);
              }
            },
            child: const Text('Transfer'),
          ),
        ],
      ),
    );
  }
}

class _CallAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _CallAction({
    required this.icon,
    required this.label,
    this.isActive = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive
                  ? Colors.white
                  : Colors.white.withOpacity(0.15),
            ),
            child: Icon(
              icon,
              color: isActive ? CosmiqColors.inCallBg : Colors.white,
              size: 24,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withOpacity(0.8),
            ),
          ),
        ],
      ),
    );
  }
}
