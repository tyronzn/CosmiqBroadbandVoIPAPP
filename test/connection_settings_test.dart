import 'package:flutter_test/flutter_test.dart';
import 'package:cosmiq_voip/services/connection_settings.dart';

/// These validators guard the one screen a support engineer can change in the
/// field. A bad value here looks exactly like a broken account, so the cases
/// are worth pinning down.
void main() {
  group('defaults', () {
    test('ships pointing at Cosmiq\u0027s own SIP service', () {
      // Users only ever type an extension and a password. If this default ever
      // drifts, every new install would fail to register.
      expect(ConnectionSettings.defaultSipHost, 'voice.cosmiqbroadband.co.za');
      expect(ConnectionSettings.defaultSipPort, '5060');
      expect(ConnectionSettings.defaultSipDomain, 'voice.cosmiqbroadband.co.za');
    });

    test('effective values fall back to those defaults', () {
      expect(ConnectionSettings.sipHost, ConnectionSettings.defaultSipHost);
      expect(ConnectionSettings.sipPort, ConnectionSettings.defaultSipPort);
      expect(ConnectionSettings.sipDomain, ConnectionSettings.defaultSipDomain);
      expect(ConnectionSettings.isOverridden, isFalse);
    });
  });

  group('validateSipHost', () {
    test('accepts a normal host name', () {
      expect(
        ConnectionSettings.validateSipHost('voice.cosmiqbroadband.co.za'),
        isNull,
      );
    });

    test('trims surrounding whitespace before judging', () {
      expect(ConnectionSettings.validateSipHost('  voice.example.co.za  '),
          isNull);
    });

    test('rejects an empty value', () {
      expect(ConnectionSettings.validateSipHost(''), isNotNull);
      expect(ConnectionSettings.validateSipHost('   '), isNotNull);
    });

    test('rejects a host with the port stuck on it', () {
      // A very easy mistake, and it would otherwise fail obscurely.
      final error = ConnectionSettings.validateSipHost('voice.example.co.za:5060');
      expect(error, isNotNull);
      expect(error, contains('port'));
    });

    test('rejects a URL rather than a host name', () {
      expect(ConnectionSettings.validateSipHost('sip://voice.example.co.za'),
          isNotNull);
    });

    test('rejects a value with no dot', () {
      expect(ConnectionSettings.validateSipHost('localhost'), isNotNull);
    });
  });

  group('validateSipPort', () {
    test('accepts the standard SIP port', () {
      expect(ConnectionSettings.validateSipPort('5060'), isNull);
    });

    test('rejects an empty value', () {
      expect(ConnectionSettings.validateSipPort(''), isNotNull);
    });

    test('rejects a non-numeric port', () {
      expect(ConnectionSettings.validateSipPort('abc'), isNotNull);
    });

    test('rejects a port outside the valid range', () {
      expect(ConnectionSettings.validateSipPort('0'), isNotNull);
      expect(ConnectionSettings.validateSipPort('70000'), isNotNull);
    });
  });

  group('validateSipDomain', () {
    test('accepts a normal domain', () {
      expect(
        ConnectionSettings.validateSipDomain('voice.cosmiqbroadband.co.za'),
        isNull,
      );
    });

    test('rejects empty, path-bearing and dotless values', () {
      expect(ConnectionSettings.validateSipDomain(''), isNotNull);
      expect(ConnectionSettings.validateSipDomain('example.co.za/ws'), isNotNull);
      expect(ConnectionSettings.validateSipDomain('localhost'), isNotNull);
    });
  });
}
