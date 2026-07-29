import 'package:flutter_test/flutter_test.dart';
import 'package:cosmiq_voip/services/connection_settings.dart';

/// The endpoint validators are the guard rail for the one setting a user is
/// most likely to type by hand — the WebRTC gateway URL supplied by the
/// carrier. A bad value here looks identical to a broken account, so these
/// cases are worth pinning down.
void main() {
  group('validateWssUrl', () {
    test('accepts a plain wss host', () {
      expect(
        ConnectionSettings.validateWssUrl('wss://webrtc.example.co.za'),
        isNull,
      );
    });

    test('accepts a wss host with port and path', () {
      expect(
        ConnectionSettings.validateWssUrl('wss://webrtc.example.co.za:8443/ws'),
        isNull,
      );
    });

    test('accepts ws:// for local testing', () {
      expect(ConnectionSettings.validateWssUrl('ws://localhost:8080'), isNull);
    });

    test('trims surrounding whitespace before judging', () {
      expect(
        ConnectionSettings.validateWssUrl('  wss://webrtc.example.co.za  '),
        isNull,
      );
    });

    test('rejects an empty value', () {
      expect(ConnectionSettings.validateWssUrl(''), isNotNull);
      expect(ConnectionSettings.validateWssUrl('   '), isNotNull);
    });

    test('rejects a non-websocket scheme', () {
      final error = ConnectionSettings.validateWssUrl('https://example.co.za');
      expect(error, isNotNull);
      expect(error, contains('wss://'));
    });

    test('rejects text that is not a URL', () {
      expect(ConnectionSettings.validateWssUrl('not a url'), isNotNull);
    });

    test('rejects a URL with no host', () {
      expect(ConnectionSettings.validateWssUrl('wss://'), isNotNull);
    });
  });

  group('validateSipDomain', () {
    test('accepts a normal domain', () {
      expect(
        ConnectionSettings.validateSipDomain('voice.cosmiqbroadband.co.za'),
        isNull,
      );
    });

    test('rejects an empty value', () {
      expect(ConnectionSettings.validateSipDomain(''), isNotNull);
    });

    test('rejects a value with no dot', () {
      expect(ConnectionSettings.validateSipDomain('localhost'), isNotNull);
    });

    test('rejects a value containing a path', () {
      expect(ConnectionSettings.validateSipDomain('example.co.za/ws'), isNotNull);
    });

    test('rejects a value containing a space', () {
      expect(ConnectionSettings.validateSipDomain('example .co.za'), isNotNull);
    });
  });

  group('defaults', () {
    test('effective values fall back to the compiled-in defaults', () {
      // No overrides are loaded in a bare test process.
      expect(ConnectionSettings.wssUrl, ConnectionSettings.defaultWssUrl);
      expect(ConnectionSettings.sipDomain, ConnectionSettings.defaultSipDomain);
      expect(ConnectionSettings.isOverridden, isFalse);
      expect(ConnectionSettings.isUsingUnconfirmedDefault, isTrue);
    });
  });
}
