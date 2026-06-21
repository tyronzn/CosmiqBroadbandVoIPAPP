/// Server configuration for Cosmiq VoIP
/// Hardcoded to voice.cosmiqbroadband.co.za — users never see or edit this.
class ServerConfig {
  ServerConfig._();

  /// SIP server hostname
  static const String sipServer = 'voice.cosmiqbroadband.co.za';

  /// SIP port — standard UDP
  static const int sipPort = 5060;

  /// SIP transport
  static const String sipTransport = 'UDP';

  /// PortaBilling REST API base URL.
  ///
  /// NOTE: the billing/self-care API is NOT on the SIP host. Cosmiq is a
  /// reseller on Backspace's PortaSwitch platform. The :8442 host serves the
  /// reseller/admin portal (:8442/ui/); the **account self-care** API — what an
  /// extension logs into for CDRs/voicemail/balance — is on **port 8443**.
  /// SIP registration stays on [sipServer].
  ///
  /// Endpoint paths already include the service segment (e.g. "/Session/login",
  /// "/Account/get_account_info"), so this must stay the bare ".../rest" with
  /// no trailing service name.
  static const String portaBillingApiUrl =
      'https://secure.backspace.co.za:8443/rest';

  /// SIP realm / domain
  static const String sipRealm = 'voice.cosmiqbroadband.co.za';

  /// SIP domain used in the SIP URI (sip:<ext>@<sipDomain>) for the WebRTC path.
  static const String sipDomain = sipRealm;

  /// SIP-over-WebSocket (WSS) gateway URL for the portable dart-sip-ua engine.
  /// PLACEHOLDER — confirm the exact path with Backspace (a webrtc.* host exists).
  /// Without PortaSIP's WebRTC gateway this engine cannot connect.
  static const String wssUrl = 'wss://webrtc.cosmiqbroadband.co.za';

  /// Domain that the account self-care API login requires as a mandatory field.
  /// PortaBilling identifies the account by login + domain; for these accounts
  /// it is the SIP service domain.
  static const String portaLoginDomain = sipRealm;

  /// STUN server for NAT traversal
  static const String stunServer = 'stun:stun.l.google.com:19302';

  /// App display name
  static const String appName = 'Cosmiq VoIP';

  /// App version
  static const String appVersion = '1.0.0';

  /// Default audio codec preference order
  static const List<String> preferredCodecs = ['opus', 'PCMA', 'PCMU'];
}
