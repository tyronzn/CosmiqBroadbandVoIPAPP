import 'package:flutter_test/flutter_test.dart';
import 'package:cosmiq_voip/services/diagnostics_log.dart';

void main() {
  setUp(DiagnosticsLog.clear);

  test('records entries with their level and tag', () {
    DiagnosticsLog.info('SIP', 'registering');
    DiagnosticsLog.error('WS', 'disconnected');

    final entries = DiagnosticsLog.entries;
    expect(entries, hasLength(2));
    expect(entries.first.level, DiagLevel.info);
    expect(entries.first.tag, 'SIP');
    expect(entries.last.level, DiagLevel.error);
    expect(entries.last.message, 'disconnected');
  });

  test('keeps newest entries once the cap is reached', () {
    for (var i = 0; i < DiagnosticsLog.maxEntries + 50; i++) {
      DiagnosticsLog.info('T', 'entry $i');
    }

    final entries = DiagnosticsLog.entries;
    expect(entries, hasLength(DiagnosticsLog.maxEntries));
    // The oldest 50 should have been dropped, not the newest.
    expect(entries.last.message,
        'entry ${DiagnosticsLog.maxEntries + 50 - 1}');
    expect(entries.first.message, 'entry 50');
  });

  test('clear empties the log', () {
    DiagnosticsLog.info('SIP', 'something');
    expect(DiagnosticsLog.isEmpty, isFalse);

    DiagnosticsLog.clear();
    expect(DiagnosticsLog.isEmpty, isTrue);
  });

  test('revision changes so widgets rebuild', () {
    final before = DiagnosticsLog.revision.value;
    DiagnosticsLog.warn('SIP', 'heads up');
    expect(DiagnosticsLog.revision.value, isNot(before));
  });

  test('asText includes the endpoint header and the messages', () {
    DiagnosticsLog.error('WS', 'handshake refused');

    final text = DiagnosticsLog.asText();
    expect(text, contains('Cosmiq VoIP diagnostics'));
    expect(text, contains('WSS URL'));
    expect(text, contains('SIP domain'));
    expect(text, contains('handshake refused'));
    expect(text, contains('[WS]'));
  });

  test('asText is still useful when nothing has been logged', () {
    final text = DiagnosticsLog.asText();
    expect(text, contains('no events recorded'));
  });
}
