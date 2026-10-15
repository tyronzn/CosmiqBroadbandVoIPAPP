import 'package:flutter/material.dart';
import '../services/connection_settings.dart';
import '../theme/cosmiq_theme.dart';

/// Diagnostic override for the SIP server the app registers to.
///
/// Users never need this: signing in with an extension and password connects to
/// Cosmiq's own SIP service out of the box. It exists so support can correct a
/// changed or mistyped server on the handset instead of shipping a new build —
/// which on iOS would otherwise mean going back to a Mac.
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _domainController;
  String? _hostError;
  String? _portError;
  String? _domainError;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: ConnectionSettings.sipHost);
    _portController = TextEditingController(text: ConnectionSettings.sipPort);
    _domainController =
        TextEditingController(text: ConnectionSettings.sipDomain);
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _domainController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final host = _hostController.text.trim();
    final port = _portController.text.trim();
    final domain = _domainController.text.trim();

    final hostError = ConnectionSettings.validateSipHost(host);
    final portError = ConnectionSettings.validateSipPort(port);
    final domainError = ConnectionSettings.validateSipDomain(domain);

    setState(() {
      _hostError = hostError;
      _portError = portError;
      _domainError = domainError;
    });
    if (hostError != null || portError != null || domainError != null) return;

    await ConnectionSettings.setSipHost(host);
    await ConnectionSettings.setSipPort(port);
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
      _hostController.text = ConnectionSettings.sipHost;
      _portController.text = ConnectionSettings.sipPort;
      _domainController.text = ConnectionSettings.sipDomain;
      _hostError = null;
      _portError = null;
      _domainError = null;
      _saved = true;
    });
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    required String hint,
    required String help,
    String? error,
    TextInputType keyboard = TextInputType.url,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: keyboard,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white,
            hintText: hint,
            errorText: error,
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 4),
        Text(help,
            style: const TextStyle(
                fontSize: 12, color: CosmiqColors.textSecondary)),
        const SizedBox(height: 20),
      ],
    );
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
          if (ConnectionSettings.isOverridden) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF4E5),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFFFD8A8)),
              ),
              child: const Text(
                'These settings have been changed from the defaults. If calling '
                'has stopped working, use Reset to defaults below.',
                style: TextStyle(fontSize: 13, height: 1.35),
              ),
            ),
            const SizedBox(height: 16),
          ],

          _field(
            label: 'SIP server',
            controller: _hostController,
            hint: 'voice.cosmiqbroadband.co.za',
            help: 'The server the app registers to. Leave this alone unless '
                'support has asked you to change it.',
            error: _hostError,
          ),
          _field(
            label: 'Port',
            controller: _portController,
            hint: '5060',
            help: 'Standard SIP port is 5060.',
            error: _portError,
            keyboard: TextInputType.number,
          ),
          _field(
            label: 'SIP domain',
            controller: _domainController,
            hint: 'voice.cosmiqbroadband.co.za',
            help: 'Used in your SIP address, as extension@domain.',
            error: _domainError,
          ),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton(onPressed: _save, child: const Text('Save')),
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
              style:
                  TextStyle(fontSize: 12, color: CosmiqColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}
