import 'package:material_ui/material_ui.dart';

import '../../core/state/today_order.dart';
import '../../data/models/models.dart';
import 'ui_helpers.dart';

/// A run of activity blocks under an optional heading on the Today page.
class ActivitySection {
  final String? label;
  final Color? color;
  final List<Activity> activities;

  const ActivitySection({
    required this.label,
    this.color,
    required this.activities,
  });
}

/// Arranges Today's activity blocks for [order]. Category sections stay in the
/// categories' own order; activities inside a section are listed A–Z, and
/// uncategorised activities fall into a final "Other" section.
List<ActivitySection> activitySections({
  required List<Activity> activities,
  required List<Category> categories,
  required TodayOrder order,
}) {
  int byCreation(Activity a, Activity b) {
    final byOrder = a.sortOrder.compareTo(b.sortOrder);
    if (byOrder != 0) return byOrder;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  int byName(Activity a, Activity b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());

  switch (order) {
    case TodayOrder.categories:
      final uncategorised = <Activity>[];
      final byCategory = <String, List<Activity>>{};
      for (final activity in activities) {
        final categoryId = activity.categoryId;
        if (categoryId == null) {
          uncategorised.add(activity);
        } else {
          (byCategory[categoryId] ??= []).add(activity);
        }
      }

      final sections = <ActivitySection>[];
      for (final category in categories) {
        final group = byCategory.remove(category.id);
        if (group == null || group.isEmpty) continue;
        group.sort(byName);
        sections.add(
          ActivitySection(
            label: category.name,
            color: UiHelpers.parseHexColor(category.colorHex),
            activities: group,
          ),
        );
      }
      // Activities that point at a category this list does not know about are
      // shown with the uncategorised ones rather than disappearing.
      for (final group in byCategory.values) {
        uncategorised.addAll(group);
      }
      if (uncategorised.isNotEmpty) {
        uncategorised.sort(byName);
        sections.add(
          ActivitySection(
            // A lone "Other" heading over the whole grid says nothing.
            label: sections.isEmpty ? null : 'Other',
            activities: uncategorised,
          ),
        );
      }
      return sections;

    case TodayOrder.manual:
      return [
        ActivitySection(
          label: null,
          activities: [...activities]..sort(byCreation),
        ),
      ];

    case TodayOrder.alphabetical:
      return [
        ActivitySection(label: null, activities: [...activities]..sort(byName)),
      ];

    case TodayOrder.pinned:
      final pinned = activities.where((a) => a.isPinned).toList()
        ..sort(byCreation);
      final rest = activities.where((a) => !a.isPinned).toList()
        ..sort(byCreation);
      return [
        if (pinned.isNotEmpty)
          ActivitySection(label: 'Pinned', activities: pinned),
        if (rest.isNotEmpty) ActivitySection(label: null, activities: rest),
      ];
  }
}
