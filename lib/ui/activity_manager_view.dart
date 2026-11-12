import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import 'activity_icon.dart';
import 'helpers/activity_emoji.dart';
import 'helpers/ui_helpers.dart';
import 'theme/tempo_theme.dart';

/// Management interface for creating, customizing, and organizing Activities.
class ActivityManagerView extends StatefulWidget {
  final TempoDatabase database;

  const ActivityManagerView({super.key, required this.database});

  @override
  State<ActivityManagerView> createState() => _ActivityManagerViewState();
}

class _ActivityManagerViewState extends State<ActivityManagerView> {
  bool _isLoading = true;
  bool _showArchived = false;
  List<Activity> _activities = [];
  List<Category> _categories = [];

  /// Icon stored on a new Activity left without an emoji; it reads as "no
  /// icon yet" everywhere, so the auto-assign pass can still fill it.
  static const String _defaultIcon = 'schedule';

  @override
  void initState() {
    super.initState();
    _loadActivities();
  }

  Future<void> _loadActivities() async {
    if (!_isLoading && mounted) {
      setState(() => _isLoading = true);
    }
    try {
      final list = await widget.database.getAllActivities(
        includeArchived: true,
      );
      final categories = await widget.database.getCategories();
      if (mounted) {
        setState(() {
          _activities = list;
          _categories = categories;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Category? _categoryById(String? id) {
    if (id == null) return null;
    for (final category in _categories) {
      if (category.id == id) return category;
    }
    return null;
  }

  Future<void> _openActivityEditor([Activity? existing]) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    String selectedColor =
        existing?.colorHex ??
        UiHelpers.toHexColor(TempoColors.activityPalette.first);
    bool isPinned = existing?.isPinned ?? false;
    String? selectedCategoryId = existing?.categoryId;
    // An emoji already worn counts as chosen; otherwise the sheet shows a
    // live guess from the name until one is tapped.
    String? pickedEmoji = existing == null
        ? null
        : ActivityIcon.emojiOf(existing.iconName);
    var iconChosen = pickedEmoji != null;
    var showAllEmoji = false;
    var disposeScheduled = false;
    final others = [
      for (final a in _activities)
        if (a.id != existing?.id) a,
    ];
    final takenBy = <String, String>{
      for (final a in others.where((a) => !a.isArchived))
        ?ActivityIcon.emojiOf(a.iconName): a.name,
    };

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        // The sheet still rebuilds while it slides away, so the field's
        // controller is disposed once the exit animation is done, not on pop.
        if (!disposeScheduled) {
          disposeScheduled = true;
          ModalRoute.of(ctx)?.completed.whenComplete(nameController.dispose);
        }
        return StatefulBuilder(
          builder: (context, setModalState) {
            final selectedCategory = _categoryById(selectedCategoryId);
            final typedName = nameController.text.trim();
            final guessed = ActivityEmoji.guess(
              typedName,
              categoryName: selectedCategory?.name,
            );
            final suggestion = guessed == null
                ? null
                : ActivityEmoji.distinct(guessed, takenBy.keys);
            final emoji = iconChosen ? pickedEmoji : suggestion;
            final previewColor = UiHelpers.parseHexColor(
              selectedCategory?.colorHex ?? selectedColor,
            );
            // Quick picks: the guess, then its alternates, then whatever is
            // already chosen, at most five.
            final quickPicks = <String>{
              ?suggestion,
              ?guessed,
              ...?ActivityEmoji.alternates[guessed],
              ?pickedEmoji,
            }.take(5).toList();
            final duplicate = _sameName(others, typedName);
            final sharedWith = emoji == null ? null : takenBy[emoji];
            final iconCaption = sharedWith != null && iconChosen
                ? 'Also used by $sharedWith.'
                : !iconChosen && suggestion != null
                ? 'Guessed from the name. Tap another to change it.'
                : !iconChosen && typedName.isNotEmpty
                ? 'No guess for this name yet. Pick one, or leave it blank.'
                : null;

            void choose(String? value) => setModalState(() {
              pickedEmoji = value;
              iconChosen = true;
            });

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 20,
                right: 20,
                top: 4,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      existing == null ? 'New activity' : 'Edit activity',
                      style: TempoText.screenTitle.copyWith(
                        color: TempoColors.ink,
                        fontSize: 24,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Semantics(
                          label: emoji == null ? 'No icon' : 'Icon $emoji',
                          child: ActivityIcon.parts(
                            iconName: emoji ?? '',
                            color: previewColor,
                            size: 52,
                            bordered: true,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: nameController,
                            onChanged: (_) => setModalState(() {}),
                            style: TempoText.body.copyWith(
                              color: TempoColors.ink,
                            ),
                            cursorColor: TempoColors.ink,
                            autofocus: existing == null,
                            decoration: InputDecoration(
                              hintText: 'e.g. Reading, Meals, Errands',
                              hintStyle: TempoText.body.copyWith(
                                color: TempoColors.inkFaint,
                              ),
                              filled: true,
                              fillColor: TempoColors.paper,
                              contentPadding: const EdgeInsets.all(14),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(
                                  TempoRadii.row,
                                ),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (duplicate != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        duplicate.isArchived
                            ? '${duplicate.name} is archived. Unarchive it '
                                  'instead of adding it again.'
                            : 'There is already an activity called '
                                  '${duplicate.name}.',
                        style: TempoText.label.copyWith(
                          color: TempoColors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Text(
                      'ICON',
                      style: TempoText.overline.copyWith(
                        color: TempoColors.inkMuted,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final pick in quickPicks)
                          _EmojiCell(
                            emoji: pick,
                            selected: pick == emoji,
                            usedBy: takenBy[pick],
                            onTap: () => choose(pick),
                          ),
                        _CategoryChip(
                          label: showAllEmoji ? 'Fewer' : 'More',
                          selected: false,
                          onTap: () =>
                              setModalState(() => showAllEmoji = !showAllEmoji),
                        ),
                        if (emoji != null)
                          _CategoryChip(
                            label: 'Clear',
                            selected: false,
                            onTap: () => choose(null),
                          ),
                      ],
                    ),
                    if (showAllEmoji) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final option in ActivityEmoji.vocabulary)
                            if (!quickPicks.contains(option))
                              _EmojiCell(
                                emoji: option,
                                selected: option == emoji,
                                usedBy: takenBy[option],
                                onTap: () => choose(option),
                              ),
                        ],
                      ),
                    ],
                    if (iconCaption != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        iconCaption,
                        style: TempoText.label.copyWith(
                          color: TempoColors.inkMuted,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Text(
                      'CATEGORY',
                      style: TempoText.overline.copyWith(
                        color: TempoColors.inkMuted,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _CategoryChip(
                          label: 'None',
                          selected: selectedCategoryId == null,
                          onTap: () =>
                              setModalState(() => selectedCategoryId = null),
                        ),
                        for (final category in _categories)
                          _CategoryChip(
                            label: category.name,
                            color: UiHelpers.parseHexColor(category.colorHex),
                            selected: selectedCategoryId == category.id,
                            onTap: () => setModalState(() {
                              selectedCategoryId = category.id;
                              selectedColor = category.colorHex;
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'COLOUR',
                      style: TempoText.overline.copyWith(
                        color: TempoColors.inkMuted,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (selectedCategory == null)
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: TempoColors.activityPalette.map((color) {
                          final hex = UiHelpers.toHexColor(color);
                          final isSelected =
                              hex.toLowerCase() == selectedColor.toLowerCase();
                          return Semantics(
                            button: true,
                            selected: isSelected,
                            label: 'Colour $hex',
                            child: GestureDetector(
                              onTap: () =>
                                  setModalState(() => selectedColor = hex),
                              child: Container(
                                width: 40,
                                height: 40,
                                padding: const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: isSelected
                                        ? TempoColors.ink
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: color,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      )
                    else
                      Row(
                        children: [
                          Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              color: UiHelpers.parseHexColor(
                                selectedCategory.colorHex,
                              ),
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Colour comes from ${selectedCategory.name}.',
                              style: TempoText.label.copyWith(
                                color: TempoColors.inkMuted,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Show on Today',
                                style: TempoText.body.copyWith(
                                  color: TempoColors.ink,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Pinned activities lead the pin-first order',
                                style: TempoText.label.copyWith(
                                  color: TempoColors.inkMuted,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: isPinned,
                          onChanged: (val) =>
                              setModalState(() => isPinned = val),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        if (existing != null) ...[
                          Expanded(
                            child: _SheetPill(
                              label: existing.isArchived
                                  ? 'Unarchive'
                                  : 'Archive',
                              filled: false,
                              onTap: () async {
                                final changed = await _toggleArchive(existing);
                                if (changed && ctx.mounted) {
                                  Navigator.of(ctx).pop();
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: _SheetPill(
                            label: 'Save',
                            filled: true,
                            onTap: () async {
                              final name = nameController.text.trim();
                              if (name.isEmpty || duplicate != null) return;
                              final iconName =
                                  emoji ??
                                  (iconChosen || existing == null
                                      ? _defaultIcon
                                      : existing.iconName);

                              final now = DateTime.now()
                                  .toUtc()
                                  .millisecondsSinceEpoch;
                              final effectiveColor =
                                  selectedCategory?.colorHex ?? selectedColor;
                              if (existing != null) {
                                final updated = existing.copyWith(
                                  name: name,
                                  iconName: iconName,
                                  colorHex: effectiveColor,
                                  isPinned: isPinned,
                                  categoryId: selectedCategoryId,
                                  clearCategoryId: selectedCategoryId == null,
                                  updatedAtEpochMs: now,
                                );
                                await widget.database.updateActivity(updated);
                              } else {
                                final newAct = Activity(
                                  id: const Uuid().v4(),
                                  name: name,
                                  colorHex: effectiveColor,
                                  iconName: iconName,
                                  isPinned: isPinned,
                                  categoryId: selectedCategoryId,
                                  sortOrder: _activities.length,
                                  isArchived: false,
                                  createdAtEpochMs: now,
                                  updatedAtEpochMs: now,
                                );
                                await widget.database.insertActivity(newAct);
                              }

                              if (ctx.mounted) Navigator.of(ctx).pop();
                              _loadActivities();
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Another Activity already called [name] (any case), archived or not.
  static Activity? _sameName(List<Activity> others, String name) {
    if (name.isEmpty) return null;
    final key = name.toLowerCase();
    for (final a in others) {
      if (a.name.trim().toLowerCase() == key) return a;
    }
    return null;
  }

  /// Archives an Activity, offering to move its Records to another Activity
  /// first. Returns whether the archive state actually changed.
  Future<bool> _toggleArchive(Activity activity) async {
    if (activity.isArchived) {
      final updated = activity.copyWith(
        isArchived: false,
        updatedAtEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      );
      await widget.database.updateActivity(updated);
      await _loadActivities();
      return true;
    }

    final hasRecords = (await widget.database.getRecords(
      activityId: activity.id,
      limit: 1,
    )).isNotEmpty;
    if (hasRecords) {
      final targets = _activities
          .where((a) => !a.isArchived && a.id != activity.id)
          .toList();
      final choice = await _chooseArchiveAction(activity, targets);
      if (choice == null) return false;
      await widget.database.archiveActivity(
        activity,
        mergeIntoActivityId: choice.mergeInto?.id,
      );
    } else {
      await widget.database.archiveActivity(activity);
    }
    await _loadActivities();
    return true;
  }

  /// Lets the user keep an archived Activity's history by moving all of its
  /// Records into another Activity, or archive it as it is.
  Future<_ArchiveChoice?> _chooseArchiveAction(
    Activity activity,
    List<Activity> targets,
  ) {
    return showModalBottomSheet<_ArchiveChoice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TempoColors.panel,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Archive ${activity.name}?',
                style: TempoText.screenTitle.copyWith(
                  color: TempoColors.ink,
                  fontSize: 24,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                targets.isEmpty
                    ? 'This activity has records. They stay attached to it '
                          'while it is archived.'
                    : 'Keep its records by moving them to another activity '
                          'first. The records keep their times, notes and tags.',
                style: TempoText.body.copyWith(color: TempoColors.inkMuted),
              ),
              if (targets.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text(
                  'MERGE RECORDS INTO',
                  style: TempoText.overline.copyWith(
                    color: TempoColors.inkMuted,
                  ),
                ),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.4,
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: targets.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final target = targets[index];
                      return Material(
                        color: TempoColors.paper,
                        borderRadius: BorderRadius.circular(TempoRadii.row),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(TempoRadii.row),
                          onTap: () =>
                              Navigator.of(sheetContext)
                                  .pop(_ArchiveChoice(target)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                ActivityIcon.parts(
                                  iconName: target.iconName,
                                  color: UiHelpers.parseHexColor(
                                    target.colorHex,
                                  ),
                                  size: 34,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    target.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TempoText.body.copyWith(
                                      color: TempoColors.ink,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const Icon(
                                  Icons.chevron_right_rounded,
                                  color: TempoColors.inkMuted,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 16),
              _SheetPill(
                label: targets.isEmpty
                    ? 'Archive activity'
                    : 'Archive without merging',
                filled: false,
                onTap: () =>
                    Navigator.of(sheetContext).pop(const _ArchiveChoice(null)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Activity> _activitiesNeedingIcon() => _activities
      .where((a) => !a.isArchived && ActivityEmoji.needsIcon(a.iconName))
      .toList();

  List<Activity> _unresolvedActivities() => _activitiesNeedingIcon()
      .where((a) => ActivityEmoji.emojiForName(a.name) == null)
      .toList();

  /// Resolves a name to an emoji for every Activity that does not already wear
  /// one, then hands anything left over to the sweep.
  Future<void> _autoAssignEmoji() async {
    final all = await widget.database.getAllActivities(includeArchived: true);
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    // Emoji already worn, so two matches on the same word (Sleep, Nap) are
    // told apart by an alternate instead of sharing one icon.
    final taken = _wornEmoji(all);
    var updated = 0;
    for (final activity in all) {
      if (!ActivityEmoji.needsIcon(activity.iconName)) continue;
      final match = ActivityEmoji.emojiForName(activity.name);
      if (match == null) continue;
      final emoji = ActivityEmoji.distinct(match, taken);
      await widget.database.updateActivity(
        activity.copyWith(iconName: emoji, updatedAtEpochMs: now),
      );
      taken.add(emoji);
      updated++;
    }
    await _loadActivities();
    if (!mounted) return;

    final unresolved = _unresolvedActivities();
    if (unresolved.isNotEmpty) {
      await _openIconSweep(unresolved);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          updated == 0
              ? 'Every activity already has an icon.'
              : updated == 1
              ? '1 activity updated'
              : '$updated activities updated',
        ),
      ),
    );
  }

  /// Emoji worn by Activities that are not archived.
  static Set<String> _wornEmoji(Iterable<Activity> activities) => {
    for (final a in activities)
      if (!a.isArchived) ?ActivityIcon.emojiOf(a.iconName),
  };

  /// Groups of active Activities wearing the same emoji, in list order.
  static List<List<Activity>> _duplicateEmojiGroups(
    Iterable<Activity> activities,
  ) {
    final byEmoji = <String, List<Activity>>{};
    for (final activity in activities) {
      final emoji = ActivityIcon.emojiOf(activity.iconName);
      if (emoji != null) (byEmoji[emoji] ??= []).add(activity);
    }
    return [
      for (final group in byEmoji.values)
        if (group.length > 1) group,
    ];
  }

  /// Gives every active Activity its own emoji. The first Activity in each
  /// duplicate group keeps the shared emoji; later ones move to an unused
  /// alternate, then to any unused emoji in the vocabulary.
  Future<void> _deduplicateEmoji() async {
    final active = _activities.where((a) => !a.isArchived).toList();
    final groups = _duplicateEmojiGroups(active);
    if (groups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Every activity already has its own emoji.'),
        ),
      );
      return;
    }

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final taken = _wornEmoji(active);
    final updates = <Activity, String>{};
    final unresolved = <Activity>[];
    for (final group in groups) {
      final shared = ActivityIcon.emojiOf(group.first.iconName)!;
      for (final activity in group.skip(1)) {
        final emoji = ActivityEmoji.distinctUnused(shared, taken);
        if (emoji == null) {
          unresolved.add(activity);
          continue;
        }
        updates[activity] = emoji;
        taken.add(emoji);
      }
    }

    for (final entry in updates.entries) {
      await widget.database.updateActivity(
        entry.key.copyWith(iconName: entry.value, updatedAtEpochMs: now),
      );
    }
    await _loadActivities();
    if (!mounted) return;

    final updated = updates.length;
    final message = unresolved.isEmpty
        ? updated == 1
              ? '1 activity given a different emoji.'
              : '$updated activities given different emoji.'
        : '$updated updated; ${unresolved.length} still share an emoji.';
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// A guessed emoji for an Activity with no exact match, steered away from
  /// the ones other Activities wear.
  String? _guessFor(Activity activity) => ActivityEmoji.suggest(
    activity.name,
    categoryName: _categoryById(activity.categoryId)?.name,
    taken: _wornEmoji(_activities.where((a) => a.id != activity.id)),
  );

  Future<void> _setIcon(Activity activity, String iconName) async {
    await widget.database.updateActivity(
      activity.copyWith(
        iconName: iconName,
        updatedAtEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      ),
    );
    await _loadActivities();
  }

  Future<void> _openIconSweep(List<Activity> pending) async {
    var remaining = pending;
    Activity? selected;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TempoColors.panel,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final activity = selected;
            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                child: activity == null
                    ? _buildSweepList(
                        remaining,
                        onPick: (picked) =>
                            setSheetState(() => selected = picked),
                        onUseGuesses: (guesses) async {
                          for (final entry in guesses.entries) {
                            await _setIcon(entry.key, entry.value);
                          }
                          if (!mounted || !sheetContext.mounted) return;
                          setSheetState(() {
                            remaining = remaining
                                .where((a) => !guesses.containsKey(a))
                                .toList();
                          });
                          if (remaining.isEmpty) {
                            Navigator.of(sheetContext).pop();
                          }
                        },
                      )
                    : _buildEmojiPicker(
                        activity,
                        onBack: () => setSheetState(() => selected = null),
                        onPicked: (iconName) async {
                          await _setIcon(activity, iconName);
                          if (!mounted || !sheetContext.mounted) return;
                          setSheetState(() {
                            remaining = remaining
                                .where((a) => a.id != activity.id)
                                .toList();
                            selected = null;
                          });
                          if (remaining.isEmpty) {
                            Navigator.of(sheetContext).pop();
                          }
                        },
                      ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSweepList(
    List<Activity> pending, {
    required ValueChanged<Activity> onPick,
    required ValueChanged<Map<Activity, String>> onUseGuesses,
  }) {
    // Guesses are made one after another so two guesses don't land on the
    // same emoji either.
    final taken = _wornEmoji(_activities);
    final guesses = <Activity, String>{};
    for (final activity in pending) {
      final guess = ActivityEmoji.guess(
        activity.name,
        categoryName: _categoryById(activity.categoryId)?.name,
      );
      if (guess == null) continue;
      final emoji = ActivityEmoji.distinct(guess, taken);
      taken.add(emoji);
      guesses[activity] = emoji;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Choose an icon',
          style: TempoText.screenTitle.copyWith(
            color: TempoColors.ink,
            fontSize: 24,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          pending.length == 1
              ? '1 activity has no match yet.'
              : '${pending.length} activities have no match yet.',
          style: TempoText.body.copyWith(color: TempoColors.inkMuted),
        ),
        if (guesses.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            guesses.length == pending.length
                ? 'Each has a guess below.'
                : '${guesses.length} have a guess below.',
            style: TempoText.label.copyWith(
              color: TempoColors.inkMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.5,
          ),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: pending.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final activity = pending[index];
              return Material(
                color: TempoColors.paper,
                borderRadius: BorderRadius.circular(TempoRadii.row),
                child: InkWell(
                  borderRadius: BorderRadius.circular(TempoRadii.row),
                  onTap: () => onPick(activity),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        if (guesses[activity] case final guess?)
                          ActivityIcon.parts(
                            iconName: guess,
                            color: UiHelpers.parseHexColor(activity.colorHex),
                            size: 34,
                          )
                        else
                          Container(
                            width: 34,
                            height: 34,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: UiHelpers.parseHexColor(activity.colorHex),
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: Text(
                              ActivityEmoji.monogram(activity.name),
                              style: TempoText.label.copyWith(
                                color: TempoColors.ink,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            activity.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TempoText.body.copyWith(
                              color: TempoColors.ink,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (guesses.containsKey(activity))
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Text(
                              'guess',
                              style: TempoText.label.copyWith(
                                color: TempoColors.inkMuted,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        const Icon(
                          Icons.chevron_right_rounded,
                          color: TempoColors.inkMuted,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (guesses.isNotEmpty) ...[
          const SizedBox(height: 14),
          _SheetPill(
            label: guesses.length == 1
                ? 'Use the guess'
                : 'Use ${guesses.length} guesses',
            filled: true,
            onTap: () => onUseGuesses(guesses),
          ),
        ],
      ],
    );
  }

  Widget _buildEmojiPicker(
    Activity activity, {
    required VoidCallback onBack,
    required ValueChanged<String> onPicked,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: onBack,
              icon: const Icon(
                Icons.arrow_back_rounded,
                color: TempoColors.ink,
              ),
            ),
            Expanded(
              child: Text(
                activity.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TempoText.title.copyWith(color: TempoColors.ink),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.45,
          ),
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final emoji in {
                  ?_guessFor(activity),
                  ...ActivityEmoji.vocabulary,
                })
                  Semantics(
                    button: true,
                    label: 'Icon $emoji',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => onPicked(emoji),
                      child: Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: TempoColors.paper,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          emoji,
                          style: const TextStyle(fontSize: 22),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _SheetPill(
                label: 'Clear',
                filled: false,
                onTap: () => onPicked(''),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _SheetPill(
                label: 'Auto',
                filled: false,
                onTap: () {
                  final derived = _guessFor(activity);
                  if (derived != null) {
                    onPicked(derived);
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('No automatic match for this name.'),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEmojiTools(List<Activity> active) {
    final pending = active
        .where((a) => ActivityEmoji.needsIcon(a.iconName))
        .toList();
    final unresolved = pending
        .where((a) => ActivityEmoji.emojiForName(a.name) == null)
        .length;
    final duplicateGroups = _duplicateEmojiGroups(active);
    final duplicateCount = duplicateGroups.fold<int>(
      0,
      (count, group) => count + group.length - 1,
    );
    final autoDetail = pending.isEmpty
        ? 'All have an icon'
        : unresolved > 0
        ? '$unresolved need an icon'
        : '${pending.length} to assign';
    final dedupeDetail = duplicateCount == 0
        ? 'All unique'
        : duplicateCount == 1
        ? '1 to change'
        : '$duplicateCount to change';

    return Material(
      color: TempoColors.surface,
      borderRadius: BorderRadius.circular(TempoRadii.row),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _EmojiToolRow(
            icon: Icons.emoji_emotions_outlined,
            label: 'Auto-assign emoji',
            detail: autoDetail,
            onTap: _autoAssignEmoji,
          ),
          const Divider(height: 1, color: TempoColors.line),
          _EmojiToolRow(
            icon: Icons.auto_fix_high_rounded,
            label: 'De-duplicate emoji',
            detail: dedupeDetail,
            onTap: _deduplicateEmoji,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = _activities.where((a) => !a.isArchived).toList();
    final archived = _activities.where((a) => a.isArchived).toList();
    final pinnedIds = active.where((a) => a.isPinned).map((a) => a.id).toList();
    final emojiTools = _buildEmojiTools(active);

    return Scaffold(
      backgroundColor: TempoColors.background,
      body: SafeArea(
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(color: TempoColors.accent),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                children: [
                  _buildHeader(context),
                  const SizedBox(height: 10),
                  Text(
                    'Shown on Today in this order.',
                    style: TempoText.body.copyWith(
                      color: TempoColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 14),
                  emojiTools,
                  const SizedBox(height: 18),
                  GridView.count(
                    crossAxisCount: 3,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      for (final a in active)
                        _ActivityBlock(
                          activity: a,
                          keyNumber: pinnedIds.take(9).contains(a.id)
                              ? pinnedIds.indexOf(a.id) + 1
                              : null,
                          onTap: () => _openActivityEditor(a),
                        ),
                      _NewBlock(onTap: () => _openActivityEditor()),
                    ],
                  ),
                  if (archived.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    _buildArchivedRow(archived),
                    if (_showArchived) ...[
                      const SizedBox(height: 10),
                      GridView.count(
                        crossAxisCount: 3,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          for (final a in archived)
                            _ActivityBlock(
                              activity: a,
                              onTap: () => _openActivityEditor(a),
                            ),
                        ],
                      ),
                    ],
                  ],
                ],
              ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: [
        Semantics(
          button: true,
          label: 'Back',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => Navigator.of(context).maybePop(),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: TempoColors.line),
              ),
              child: const Icon(
                Icons.arrow_back_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            'Activities',
            style: TempoText.screenTitle.copyWith(
              color: Colors.white,
              fontSize: 28,
            ),
          ),
        ),
        Material(
          color: TempoColors.accent,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => _openActivityEditor(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                '+ New',
                style: TempoText.label.copyWith(
                  color: TempoColors.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildArchivedRow(List<Activity> archived) {
    return Material(
      color: TempoColors.surface,
      borderRadius: BorderRadius.circular(TempoRadii.row),
      child: InkWell(
        borderRadius: BorderRadius.circular(TempoRadii.row),
        onTap: () => setState(() => _showArchived = !_showArchived),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Archived · ${archived.length}',
                  style: TempoText.body.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                _showArchived
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                color: TempoColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArchiveChoice {
  final Activity? mergeInto;

  const _ArchiveChoice(this.mergeInto);
}

class _EmojiToolRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String detail;
  final VoidCallback onTap;

  const _EmojiToolRow({
    required this.icon,
    required this.label,
    required this.detail,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$label, $detail',
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: TempoColors.textMuted, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TempoText.body.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                detail,
                style: TempoText.label.copyWith(
                  color: TempoColors.textMuted,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.chevron_right_rounded,
                color: TempoColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActivityBlock extends StatelessWidget {
  final Activity activity;
  final int? keyNumber;
  final VoidCallback onTap;

  const _ActivityBlock({
    required this.activity,
    required this.onTap,
    this.keyNumber,
  });

  @override
  Widget build(BuildContext context) {
    final color = UiHelpers.parseHexColor(activity.colorHex);
    final meta = activity.isArchived
        ? 'Archived'
        : (activity.isPinned ? 'Pinned' : '');
    return Opacity(
      opacity: activity.isArchived ? 0.55 : 1,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(TempoRadii.block),
        child: InkWell(
          borderRadius: BorderRadius.circular(TempoRadii.block),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Stack(
              children: [
                if (meta.isNotEmpty)
                  Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        meta,
                        style: TempoText.overline.copyWith(
                          color: TempoColors.inkMuted,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ),
                if (keyNumber != null)
                  Align(
                    alignment: Alignment.topRight,
                    child: Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: TempoColors.ink,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '$keyNumber',
                        style: TempoText.numeral.copyWith(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (ActivityIcon.has(activity)) ...[
                        ActivityIcon.glyph(activity, size: 22),
                        const SizedBox(height: 6),
                      ],
                      Text(
                        activity.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TempoText.title.copyWith(
                          color: TempoColors.ink,
                          fontSize: 15,
                        ),
                      ),
                    ],
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

class _NewBlock extends StatelessWidget {
  final VoidCallback onTap;

  const _NewBlock({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(TempoRadii.block),
      onTap: onTap,
      child: CustomPaint(
        painter: _DashedRRectPainter(
          color: const Color(0x40FFFFFF),
          radius: TempoRadii.block,
        ),
        child: Center(
          child: Text(
            '+ New',
            style: TempoText.label.copyWith(color: TempoColors.textMuted),
          ),
        ),
      ),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  final Color color;
  final double radius;

  const _DashedRRectPainter({required this.color, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.75),
          Radius.circular(radius),
        ),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in path.computeMetrics()) {
      double d = 0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + 6), paint);
        d += 11;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter old) =>
      old.color != color || old.radius != radius;
}

class _SheetPill extends StatelessWidget {
  final String label;
  final bool filled;
  final VoidCallback onTap;

  const _SheetPill({
    required this.label,
    required this.filled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: filled ? TempoColors.ink : Colors.transparent,
      shape: StadiumBorder(
        side: filled
            ? BorderSide.none
            : const BorderSide(color: TempoColors.ink, width: 1.5),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: SizedBox(
          height: 52,
          child: Center(
            child: Text(
              label,
              style: TempoText.body.copyWith(
                color: filled ? Colors.white : TempoColors.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One emoji in the activity editor's icon picker: Insert Paper, ink ring when
/// selected. An emoji another Activity wears gets a small ink dot so a repeat
/// is a choice, not an accident.
class _EmojiCell extends StatelessWidget {
  final String emoji;
  final bool selected;
  final String? usedBy;
  final VoidCallback onTap;

  const _EmojiCell({
    required this.emoji,
    required this.selected,
    required this.onTap,
    this.usedBy,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: usedBy == null ? 'Icon $emoji' : 'Icon $emoji, used by $usedBy',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: TempoColors.paper,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? TempoColors.ink : Colors.transparent,
              width: 2,
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 22, height: 1)),
              if (usedBy != null && !selected)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: TempoColors.inkFaint,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A compact pick-one pill for the category field in the activity editor.
class _CategoryChip extends StatelessWidget {
  final String label;
  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryChip({
    required this.label,
    this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? TempoColors.ink : TempoColors.paper,
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? TempoColors.ink : TempoColors.line,
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (color != null) ...[
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: TempoText.label.copyWith(
                    color: selected ? Colors.white : TempoColors.ink,
                    fontWeight: FontWeight.w600,
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
