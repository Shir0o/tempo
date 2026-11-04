import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/core/state/today_order.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/ui/helpers/activity_order.dart';

Activity _activity(
  String id,
  String name, {
  String? categoryId,
  int sortOrder = 0,
  bool pinned = false,
}) => Activity(
  id: id,
  name: name,
  categoryId: categoryId,
  isPinned: pinned,
  sortOrder: sortOrder,
  createdAtEpochMs: 0,
  updatedAtEpochMs: 0,
);

Category _category(String id, String name, int sortOrder) => Category(
  id: id,
  name: name,
  sortOrder: sortOrder,
  createdAtEpochMs: 0,
  updatedAtEpochMs: 0,
);

void main() {
  final categories = [
    _category('cat-work', 'Work', 0),
    _category('cat-rest', 'Rest', 1),
  ];
  final activities = [
    _activity('gym', 'Gym', sortOrder: 2, pinned: true),
    _activity('reading', 'Reading', categoryId: 'cat-work', sortOrder: 1),
    _activity('email', 'Email', categoryId: 'cat-work', sortOrder: 0),
    _activity('sleep', 'Sleep', categoryId: 'cat-rest', sortOrder: 0),
  ];

  test('categories groups by category order, then Other', () {
    final sections = activitySections(
      activities: activities,
      categories: categories,
      order: TodayOrder.categories,
    );

    expect(sections.map((s) => s.label), ['Work', 'Rest', 'Other']);
    expect(sections[0].activities.map((a) => a.name), ['Email', 'Reading']);
    expect(sections[1].activities.single.name, 'Sleep');
    expect(sections[2].activities.single.name, 'Gym');
  });

  test(
    'categories hides empty categories and keeps one flat grid otherwise',
    () {
      final sections = activitySections(
        activities: activities,
        categories: [_category('cat-empty', 'Empty', 0)],
        order: TodayOrder.categories,
      );

      expect(sections.single.label, isNull);
      expect(sections.single.activities.map((a) => a.name), [
        'Email',
        'Sleep',
        'Reading',
        'Gym',
      ]);
    },
  );

  test('manual order follows sortOrder then name', () {
    final sections = activitySections(
      activities: activities,
      categories: categories,
      order: TodayOrder.manual,
    );

    expect(sections.single.label, isNull);
    expect(sections.single.activities.map((a) => a.name), [
      'Email',
      'Sleep',
      'Reading',
      'Gym',
    ]);
  });

  test('alphabetical order ignores categories', () {
    final sections = activitySections(
      activities: activities,
      categories: categories,
      order: TodayOrder.alphabetical,
    );

    expect(sections.single.activities.map((a) => a.name), [
      'Email',
      'Gym',
      'Reading',
      'Sleep',
    ]);
  });

  test('pinned first puts pinned activities in their own section', () {
    final sections = activitySections(
      activities: activities,
      categories: categories,
      order: TodayOrder.pinned,
    );

    expect(sections.first.label, 'Pinned');
    expect(sections.first.activities.single.name, 'Gym');
    expect(sections.last.label, isNull);
    expect(sections.last.activities.map((a) => a.name), [
      'Email',
      'Sleep',
      'Reading',
    ]);
  });

  test('the stored order decodes with a Categories fallback', () {
    expect(TodayOrder.fromStorage('pinned'), TodayOrder.pinned);
    expect(TodayOrder.fromStorage('nonsense'), TodayOrder.categories);
    expect(TodayOrder.fromStorage(null), TodayOrder.categories);
  });
}
