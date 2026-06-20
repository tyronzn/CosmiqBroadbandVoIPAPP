import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/voicemail_message.dart';
import '../services/app_state.dart';
import '../theme/cosmiq_theme.dart';
import 'incall_screen.dart';

class VoicemailScreen extends StatelessWidget {
  const VoicemailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final voicemails = appState.voicemails;

    return Scaffold(
      backgroundColor: CosmiqColors.white,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                'Voicemail',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w500,
                  color: CosmiqColors.textPrimary,
                ),
              ),
            ),

            const Divider(height: 0.5, color: CosmiqColors.separator),

            // List
            Expanded(
              child: voicemails.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.voicemail,
                            size: 48,
                            color: CosmiqColors.textSecondary.withOpacity(0.4),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'No voicemails',
                            style: TextStyle(
                              fontSize: 15,
                              color: CosmiqColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      color: CosmiqColors.teal,
                      onRefresh: () => appState.refreshVoicemails(),
                      child: ListView.builder(
                        itemCount: voicemails.length,
                        itemBuilder: (context, index) {
                          return _VoicemailTile(
                            message: voicemails[index],
                            isExpanded: index == 0, // first one expanded
                            onCallBack: () =>
                                _callBack(context, voicemails[index]),
                            onDelete: () =>
                                _deleteVoicemail(context, voicemails[index]),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _callBack(BuildContext context, VoicemailMessage msg) {
    final sip = context.read<AppState>().sip;
    sip.makeCall(msg.callerNumber);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InCallScreen(
          remoteNumber: msg.callerNumber,
          remoteName: msg.callerName,
        ),
      ),
    );
  }

  Future<void> _deleteVoicemail(
      BuildContext context, VoicemailMessage msg) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Voicemail'),
        content: Text('Delete voicemail from ${msg.displayName}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete',
                style: TextStyle(color: CosmiqColors.hangupRed)),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await context.read<AppState>().billing.deleteVoicemail(msg.id);
      await context.read<AppState>().refreshVoicemails();
    }
  }
}

class _VoicemailTile extends StatelessWidget {
  final VoicemailMessage message;
  final bool isExpanded;
  final VoidCallback onCallBack;
  final VoidCallback onDelete;

  const _VoicemailTile({
    required this.message,
    this.isExpanded = false,
    required this.onCallBack,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: CosmiqColors.separator, width: 0.5),
        ),
      ),
      child: Opacity(
        opacity: isExpanded ? 1.0 : 0.55,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  message.displayName,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: isExpanded ? FontWeight.w500 : FontWeight.w400,
                    color: CosmiqColors.textPrimary,
                  ),
                ),
                Text(
                  _formatDate(message.timestamp),
                  style: const TextStyle(
                    fontSize: 12,
                    color: CosmiqColors.textSecondary,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 2),

            // Duration + transcribed label
            Text(
              '${message.durationFormatted}${message.transcript != null ? ' · transcribed' : ''}',
              style: const TextStyle(
                fontSize: 12,
                color: CosmiqColors.textSecondary,
              ),
            ),

            // Expanded content
            if (isExpanded) ...[
              // Transcript
              if (message.transcript != null) ...[
                const SizedBox(height: 8),
                Text(
                  '"${message.transcript}"',
                  style: const TextStyle(
                    fontSize: 13,
                    color: CosmiqColors.textTertiary,
                  ),
                ),
              ],

              const SizedBox(height: 10),

              // Playback bar (visual placeholder)
              Container(
                height: 24,
                decoration: BoxDecoration(
                  color: CosmiqColors.backgroundSecondary,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: 0.0, // 0% played
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: CosmiqColors.teal,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 8),

              // Action buttons
              Row(
                children: [
                  GestureDetector(
                    onTap: () {
                      // TODO: implement audio playback via just_audio
                    },
                    child: const Text(
                      '▶ play',
                      style: TextStyle(
                        fontSize: 13,
                        color: CosmiqColors.tealDark,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  GestureDetector(
                    onTap: onCallBack,
                    child: const Text(
                      '↗ call back',
                      style: TextStyle(
                        fontSize: 13,
                        color: CosmiqColors.tealDark,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  GestureDetector(
                    onTap: onDelete,
                    child: const Text(
                      '⌫ delete',
                      style: TextStyle(
                        fontSize: 13,
                        color: CosmiqColors.hangupRed,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inHours < 24) {
      return 'today, ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    if (diff.inHours < 48) return 'yesterday';

    final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return weekdays[dt.weekday - 1];
  }
}
