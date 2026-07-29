import 'package:flutter/material.dart';
import '../services/connection_settings.dart';
import '../theme/cosmiq_theme.dart';

/// Lets the WebRTC gateway endpoint be corrected on the device.
///
/// The carrier supplies the exact WSS host, port and path; if it doesn't match
/// the shipped default, registration fails. Editing it here avoids a rebuild —
/// which on iOS would otherwise mean going back to a Mac for every attempt.
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  late final TextEditingController _wssController;
  late final TextEditingController _domainController;
  String? _wssError;
  String? _domainError;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _wssController = TextEditingController(text: ConnectionSettings.wssUrl);
    _domainController =
        TextEditingController(text: ConnectionSettings.sipDomain);
  }

  @override
  void dispose() {
    _wssController.dispose();
    _domainController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final wss = _wssController.text.trim();
    final domain = _domainController.text.trim();
    final wssError = ConnectionSettings.validateWssUrl(wss);
    final domainError = ConnectionSettings.validateSipDomain(domain);

    setState(() {
      _wssError = wssError;
      _domainError = domainError;
    });
    if (wssError != null || domainError != null) return;

    await ConnectionSettings.setWssUrl(wss);
    await ConnectionSettings.setSipDomain(domain);
    if (!mounted) return;
    setState(() => _saved = true);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Saved. Sign out and back in to reconnect.'),
      ),
    );
  }

  Future<void> _reset() async {
    await ConnectionSettings.resetToDefaults();
    if (!mounted) return;
    setState(() {
      _wssController.text = ConnectionSettings.wssUrl;
      _domainController.text = ConnectionSettings.sipDomain;
      _wssError = null;
      _domainError = null;
      _saved = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CosmiqColors.backgroundSecondary,
      appBar: AppBar(
        title: const Text('Connection'),
        backgroundColor: Colors.white,
        foregroundColor: CosmiqColors.textPrimary,
        elevation: 0.5,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (ConnectionSettings.isUsingUnconfirmedDefault) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF4E5),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFFFD8A8)),
              ),
              child: const Text(
                'This is still the default gateway address, which has not been '
                'confirmed with your provider. Until the real address is '
                'entered here, sign-in is expected to fail.',
                style: TextStyle(fontSize: 13, height: 1.35),
              ),
            ),
            const SizedBox(height: 16),
          ],

          const Text(
            'WebRTC gateway (WSS)',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _wssController,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white,
              hintText: 'wss://host:port/path',
              errorText: _wssError,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Supplied by your provider. Include the port and path if they gave '
            'you one, e.g. wss://webrtc.example.co.za:8443/ws',
            style: TextStyle(fontSize: 12, color: CosmiqColors.textSecondary),
          ),
          const SizedBox(height: 20),

          const Text(
            'SIP domain',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _domainController,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white,
              hintText: 'voice.example.co.za',
              errorText: _domainError,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'The domain in your SIP address, used as sip:<extension>@<domain>.',
            style: TextStyle(fontSize: 12, color: CosmiqColors.textSecondary),
          ),
          const SizedBox(height: 24),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _save,
              child: const Text('Save'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: _reset,
              child: const Text('Reset to defaults'),
            ),
          ),

          if (_saved) ...[
            const SizedBox(height: 12),
            const Text(
              'Changes take effect on the next sign-in.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: CosmiqColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}
