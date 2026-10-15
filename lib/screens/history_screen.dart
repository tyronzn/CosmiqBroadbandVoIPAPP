import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/call_record.dart';
import '../services/app_state.dart';
import '../theme/cosmiq_theme.dart';
import 'incall_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  bool _showMissedOnly = false;

  Future<void> _confirmClear(BuildContext context, AppState appState) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear Recents'),
        content: const Text('Remove all call history from this device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear',
                style: TextStyle(color: CosmiqColors.hangupRed)),
          ),
        ],
      ),
    );
    if (confirmed == true) await appState.clearCallHistory();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final allRecords = appState.callHistory;
    final records = _showMissedOnly
        ? allRecords.where((r) => r.status == CallStatus.missed).toList()
        : allRecords;

    return Scaffold(
      backgroundColor: CosmiqColors.white,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Recents',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w500,
                      color: CosmiqColors.textPrimary,
                    ),
                  ),
                  Row(
                    children: [
                      if (allRecords.isNotEmpty)
                        GestureDetector(
                          onTap: () => _confirmClear(context, appState),
                          child: const Text(
                            'Clear',
                            style: TextStyle(
                              fontSize: 14,
                              color: CosmiqColors.hangupRed,
                            ),
                          ),
                        ),
                      const SizedBox(width: 16),
                      GestureDetector(
                        onTap: () => appState.refreshCallHistory(),
                        child: const Text(
                          'Refresh',
                          style: TextStyle(
                            fontSize: 14,
                            color: CosmiqColors.tealDark,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Filter tabs
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  _FilterPill(
                    label: 'All',
                    isSelected: !_showMissedOnly,
                    onTap: () => setState(() => _showMissedOnly = false),
                  ),
                  const SizedBox(width: 4),
                  _FilterPill(
                    label: 'Missed',
                    isSelected: _showMissedOnly,
                    onTap: () => setState(() => _showMissedOnly = true),
                  ),
                ],
              ),
            ),

            // Divider
            const Divider(height: 0.5, color: CosmiqColors.separator),

            // List
            Expanded(
              child: records.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.history,
                            size: 48,
                            color: CosmiqColors.textSecondary.withOpacity(0.4),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'No recent calls',
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
                      onRefresh: () => appState.refreshCallHistory(),
                      child: ListView.builder(
                        itemCount: records.length,
                        itemBuilder: (context, index) {
                          return _CallRecordTile(
                            record: records[index],
                            onTap: () => _callBack(records[index]),
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

  void _callBack(CallRecord record) {
    final sip = context.read<AppState>().sip;
    sip.makeCall(record.remoteNumber);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InCallScreen(
          remoteNumber: record.remoteNumber,
          remoteName: record.remoteName,
        ),
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _FilterPill({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? CosmiqColors.teal : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w500 : FontWeight.w400,
            color: isSelected
                ? CosmiqColors.textPrimary
                : CosmiqColors.tealDark,
          ),
        ),
      ),
    );
  }
}

class _CallRecordTile extends StatelessWidget {
  final CallRecord record;
  final VoidCallback onTap;

  const _CallRecordTile({required this.record, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isMissed = record.status == CallStatus.missed;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: CosmiqColors.separator, width: 0.5),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.displayName,
                    style: TextStyle(
                      fontSize: 15,
                      color: isMissed
                          ? CosmiqColors.missedRed
                          : CosmiqColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${record.directionArrow} ${record.subtitle} · ${_formatTime(record.timestamp)}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: CosmiqColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.info_outline,
              size: 18,
              color: CosmiqColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) {
      return 'today, ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    if (diff.inHours < 48) return 'yesterday';

    final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return weekdays[dt.weekday - 1];
  }
}
