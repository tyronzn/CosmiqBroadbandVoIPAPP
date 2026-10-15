import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/diagnostics_log.dart';
import '../theme/cosmiq_theme.dart';

/// Shows the in-app connection log and copies it to the clipboard.
///
/// Testing happens on a handset with no console attached — on iOS, reading the
/// device log needs a Mac — so this is the only practical way to find out why a
/// sign-in or call failed while in the field.
class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  Color _colorFor(DiagLevel level) {
    switch (level) {
      case DiagLevel.error:
        return CosmiqColors.hangupRed;
      case DiagLevel.warn:
        return const Color(0xFFB26A00);
      case DiagLevel.info:
        return CosmiqColors.textPrimary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CosmiqColors.backgroundSecondary,
      appBar: AppBar(
        title: const Text('Diagnostics'),
        backgroundColor: Colors.white,
        foregroundColor: CosmiqColors.textPrimary,
        elevation: 0.5,
        actions: [
          IconButton(
            tooltip: 'Copy log',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: DiagnosticsLog.asText()),
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Log copied to clipboard')),
                );
              }
            },
          ),
          IconButton(
            tooltip: 'Clear log',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => DiagnosticsLog.clear(),
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: DiagnosticsLog.revision,
        builder: (context, _, __) {
          final entries = DiagnosticsLog.entries.reversed.toList();

          if (entries.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No events yet.\nSign in to record connection activity.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: CosmiqColors.textSecondary),
                ),
              ),
            );
          }

          return Column(
            children: [
              Container(
                width: double.infinity,
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Text(
                  '${entries.length} event${entries.length == 1 ? "" : "s"} · '
                  'newest first · tap Copy to share with support',
                  style: const TextStyle(
                    fontSize: 12,
                    color: CosmiqColors.textSecondary,
                  ),
                ),
              ),
              const Divider(height: 0.5, color: CosmiqColors.separator),
              Expanded(
                child: ListView.separated(
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const Divider(
                    height: 0.5,
                    color: CosmiqColors.separator,
                  ),
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 62,
                            child: Text(
                              entry.timestamp,
                              style: const TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: CosmiqColors.textSecondary,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 44,
                            child: Text(
                              entry.tag,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: CosmiqColors.tealDark,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              entry.message,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.3,
                                color: _colorFor(entry.level),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
