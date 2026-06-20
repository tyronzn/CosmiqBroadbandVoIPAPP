/// Represents the logged-in user's account information from PortaBilling.
class AccountInfo {
  final String username;
  final String extension;
  final String? displayName;
  final String? balance;
  final String? currency;
  final String? plan;
  final String? callerId;
  final String? email;
  final bool callForwardingEnabled;
  final String? callForwardingNumber;
  final bool dndEnabled;

  AccountInfo({
    required this.username,
    required this.extension,
    this.displayName,
    this.balance,
    this.currency,
    this.plan,
    this.callerId,
    this.email,
    this.callForwardingEnabled = false,
    this.callForwardingNumber,
    this.dndEnabled = false,
  });

  /// Parse from PortaBilling account info response
  factory AccountInfo.fromPortaBilling(Map<String, dynamic> json) {
    return AccountInfo(
      username: json['login'] ?? json['id'] ?? '',
      extension: json['id'] ?? json['login'] ?? '',
      displayName: _buildDisplayName(json),
      balance: json['balance']?.toString(),
      currency: json['iso_4217'] ?? 'ZAR',
      plan: json['product_name'],
      callerId: json['caller_name'] ?? json['cli'],
      email: json['email'],
      callForwardingEnabled: json['follow_me_enabled'] == 'Y',
      callForwardingNumber: json['follow_me_number'],
      dndEnabled: json['vm_enabled'] == 'Y',
    );
  }

  static String? _buildDisplayName(Map<String, dynamic> json) {
    final first = json['firstname'] ?? '';
    final last = json['lastname'] ?? '';
    final full = '$first $last'.trim();
    return full.isNotEmpty ? full : null;
  }

  /// Initials for avatar
  String get initials {
    if (displayName != null && displayName!.isNotEmpty) {
      final parts = displayName!.split(' ');
      if (parts.length >= 2) {
        return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
      }
      return displayName![0].toUpperCase();
    }
    return extension.isNotEmpty ? extension[0].toUpperCase() : '?';
  }

  /// Formatted balance with currency
  String get formattedBalance {
    if (balance == null) return 'N/A';
    final symbol = currency == 'ZAR' ? 'R' : currency ?? '';
    try {
      final amount = double.parse(balance!);
      return '$symbol ${amount.toStringAsFixed(2)}';
    } catch (_) {
      return '$symbol $balance';
    }
  }
}
