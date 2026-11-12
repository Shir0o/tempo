import 'package:material_ui/material_ui.dart';

import '../../data/models/models.dart';
import '../activity_icon.dart';
import '../helpers/ui_helpers.dart';
import '../theme/tempo_theme.dart';
import 'history_widgets.dart';

/// Opens the Change Activity picker over the edit sheet and returns the
/// Activity picked, or null when dismissed. Nothing is applied here: the edit
/// sheet stages the pick until Save.
Future<Activity?> showActivityPicker(
  BuildContext context, {
  required List<Activity> activities,
  required List<Category> categories,
  required List<Activity> suggestions,
  required String? currentId,
  required String subtitle,
  required String aroundLabel,
}) {
  return showModalBottomSheet<Activity>(
    context: context,
    isScrollControlled: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.92,
      child: _ActivityPicker(
        activities: activities,
        categories: categories,
        suggestions: suggestions,
        currentId: currentId,
        subtitle: subtitle,
        aroundLabel: aroundLabel,
      ),
    ),
  );
}

class _ActivityPicker extends StatefulWidget {
  final List<Activity> activities;
  final List<Category> categories;
  final List<Activity> suggestions;
  final String? currentId;
  final String subtitle;
  final String aroundLabel;

  const _ActivityPicker({
    required this.activities,
    required this.categories,
    required this.suggestions,
    required this.currentId,
    required this.subtitle,
    required this.aroundLabel,
  });

  @override
  State<_ActivityPicker> createState() => _ActivityPickerState();
}

class _ActivityPickerState extends State<_ActivityPicker> {
  String _query = '';

  /// Activities grouped under their Category in the Categories' own order,
  /// A–Z inside each; uncategorised ones last under "Other".
  List<(String?, List<Activity>)> _groups() {
    final q = _query.trim().toLowerCase();
    final shown =
        widget.activities
            .where((a) => q.isEmpty || a.name.toLowerCase().contains(q))
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    final known = {for (final c in widget.categories) c.id};
    final groups = <(String?, List<Activity>)>[
      for (final c in widget.categories)
        (c.name, shown.where((a) => a.categoryId == c.id).toList()),
    ];
    final other = shown.where((a) => !known.contains(a.categoryId)).toList();
    groups.add((groups.any((g) => g.$2.isNotEmpty) ? 'Other' : null, other));
    return groups.where((g) => g.$2.isNotEmpty).toList();
  }

  void _pick(Activity a) => Navigator.of(context).pop(a);

  @override
  Widget build(BuildContext context) {
    final groups = _groups();
    final searching = _query.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    color: TempoColors.ink,
                    icon: const Icon(Icons.chevron_left_rounded, size: 28),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Change Activity',
                          style: TempoText.title.copyWith(
                            fontSize: 22,
                            color: TempoColors.ink,
                          ),
                        ),
                        Text(
                          widget.subtitle,
                          style: TempoText.label.copyWith(
                            color: TempoColors.inkMuted,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: TextField(
                autofocus: true,
                cursorColor: TempoColors.ink,
                textInputAction: TextInputAction.search,
                onChanged: (v) => setState(() => _query = v),
                onSubmitted: (_) {
                  if (groups.length == 1 && groups.first.$2.length == 1) {
                    _pick(groups.first.$2.first);
                  }
                },
                style: TempoText.body.copyWith(
                  fontSize: 16,
                  color: TempoColors.ink,
                ),
                decoration: InputDecoration(
                  hintText: 'Search ${widget.activities.length} Activities',
                  hintStyle: TempoText.body.copyWith(
                    fontSize: 16,
                    color: TempoColors.inkFaint,
                  ),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: TempoColors.ink,
                  ),
                  filled: true,
                  fillColor: TempoColors.paper,
                  contentPadding: const EdgeInsets.all(14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(TempoRadii.row),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(TempoRadii.row),
                    borderSide: const BorderSide(
                      color: TempoColors.ink,
                      width: 2,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                children: [
                  if (!searching && widget.suggestions.isNotEmpty) ...[
                    SheetOverline(widget.aroundLabel),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (final (i, a) in widget.suggestions.indexed) ...[
                          if (i > 0) const SizedBox(width: 8),
                          Expanded(child: _SuggestionTile(a, () => _pick(a))),
                        ],
                        for (var i = widget.suggestions.length; i < 3; i++) ...[
                          const SizedBox(width: 8),
                          const Expanded(child: SizedBox()),
                        ],
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                  for (final (name, items) in groups) ...[
                    if (name != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                        child: SheetOverline(name),
                      ),
                    for (final a in items)
                      _ActivityRow(
                        activity: a,
                        current: a.id == widget.currentId,
                        onTap: () => _pick(a),
                      ),
                    const SizedBox(height: 12),
                  ],
                  if (groups.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text(
                        'No Activity called “${_query.trim()}”. '
                        'Add it in Activities.',
                        style: TempoText.body.copyWith(
                          color: TempoColors.inkMuted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  final Activity activity;
  final VoidCallback onTap;

  const _SuggestionTile(this.activity, this.onTap);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: activity.name,
      excludeSemantics: true,
      child: Material(
        color: UiHelpers.parseHexColor(activity.colorHex),
        borderRadius: BorderRadius.circular(TempoRadii.block),
        child: InkWell(
          borderRadius: BorderRadius.circular(TempoRadii.block),
          onTap: onTap,
          child: Container(
            height: 76,
            padding: const EdgeInsets.all(10),
            alignment: Alignment.bottomLeft,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ActivityIcon.glyph(activity, size: 18),
                Text(
                  activity.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TempoText.label.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: TempoColors.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final Activity activity;
  final bool current;
  final VoidCallback onTap;

  const _ActivityRow({
    required this.activity,
    required this.current,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: current,
      label: current ? '${activity.name}, current' : activity.name,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                ActivityIcon(activity, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    activity.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TempoText.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: TempoColors.ink,
                    ),
                  ),
                ),
                if (current)
                  const Icon(Icons.check_rounded, color: TempoColors.ink),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
