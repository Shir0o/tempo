/// How the Today page arranges its activity blocks. Persisted in the
/// `settings` table under [storageKey].
enum TodayOrder {
  categories('categories', 'By category'),
  manual('manual', 'Manual order'),
  alphabetical('alphabetical', 'A to Z'),
  pinned('pinned', 'Pinned first');

  const TodayOrder(this.storageValue, this.label);

  final String storageValue;

  /// The short label shown in Settings and in the order sheet.
  final String label;

  /// The key this preference is stored under.
  static const String storageKey = 'today_activity_order';

  /// One line explaining what the order does.
  String get description => switch (this) {
    TodayOrder.categories => 'Grouped by category, in category order.',
    TodayOrder.manual => 'In the order activities were created.',
    TodayOrder.alphabetical => 'A to Z.',
    TodayOrder.pinned => 'Pinned activities first, then the rest.',
  };

  /// Decodes a stored value, falling back to [TodayOrder.categories].
  static TodayOrder fromStorage(String? value) => values.firstWhere(
    (order) => order.storageValue == value,
    orElse: () => TodayOrder.categories,
  );
}
