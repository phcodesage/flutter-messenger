/// Model for common phrases used in quick messaging
class CommonPhrase {
  static const List<CommonPhrase> preloadedDefaults = <CommonPhrase>[
    CommonPhrase(id: null, phrase: 'How are things coming?', usageCount: 0, isDefault: true, isCustom: false),
    CommonPhrase(id: null, phrase: 'Can we do a quick sync?', usageCount: 0, isDefault: true, isCustom: false),
    CommonPhrase(id: null, phrase: 'Thanks, got it.', usageCount: 0, isDefault: true, isCustom: false),
  ];

  final int? id;
  final String phrase;
  final int usageCount;
  final bool isDefault;
  final bool isCustom;
  final int? pinOrderWeb;
  final int? pinOrderMobile;
  final DateTime? lastUsedAt;

  const CommonPhrase({
    required this.id,
    required this.phrase,
    required this.usageCount,
    required this.isDefault,
    required this.isCustom,
    this.pinOrderWeb,
    this.pinOrderMobile,
    this.lastUsedAt,
  });

  /// Whether this phrase is pinned on mobile
  bool get isPinnedMobile => pinOrderMobile != null;

  /// Whether this phrase is pinned on web
  bool get isPinnedWeb => pinOrderWeb != null;

  factory CommonPhrase.fromJson(Map<String, dynamic> json) {
    return CommonPhrase(
      id: json['id'] as int?,
      phrase: (json['phrase'] ?? '').toString(),
      usageCount: (json['usage_count'] ?? 0) as int,
      isDefault: (json['is_default'] ?? false) as bool,
      isCustom: (json['is_custom'] ?? false) as bool,
      pinOrderWeb: json['pin_order_web'] as int?,
      pinOrderMobile: json['pin_order_mobile'] as int?,
      lastUsedAt: json['last_used_at'] != null
          ? DateTime.tryParse(json['last_used_at'].toString())
          : null,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'phrase': phrase,
    'usage_count': usageCount,
    'is_default': isDefault,
    'is_custom': isCustom,
    'pin_order_web': pinOrderWeb,
    'pin_order_mobile': pinOrderMobile,
    'last_used_at': lastUsedAt?.toIso8601String(),
  };

  @override
  String toString() =>
      'CommonPhrase(id: $id, phrase: $phrase, usageCount: $usageCount, '
      'isDefault: $isDefault, isCustom: $isCustom, '
      'pinnedMobile: $isPinnedMobile, pinnedWeb: $isPinnedWeb)';
}
