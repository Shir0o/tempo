import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import 'helpers/ui_helpers.dart';
import 'theme/tempo_theme.dart';

/// Management interface for creating, renaming, ordering and deleting the
/// Categories that group Activities on the Today page.
class CategoryManagerView extends StatefulWidget {
  final TempoDatabase database;

  const CategoryManagerView({super.key, required this.database});

  @override
  State<CategoryManagerView> createState() => _CategoryManagerViewState();
}

class _CategoryManagerViewState extends State<CategoryManagerView> {
  bool _isLoading = true;
  List<Category> _categories = [];
  List<Activity> _activities = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final categories = await widget.database.getCategories();
      final activities = await widget.database.getAllActivities(
        includeArchived: true,
      );
      if (mounted) {
        setState(() {
          _categories = categories;
          _activities = activities;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  int _activityCount(Category category) =>
      _activities.where((a) => a.categoryId == category.id).length;

  void _setStatus(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _move(int index, int delta) async {
    final target = index + delta;
    if (target < 0 || target >= _categories.length) return;
    final reordered = List<Category>.of(_categories);
    final moved = reordered.removeAt(index);
    reordered.insert(target, moved);

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    for (var i = 0; i < reordered.length; i++) {
      if (reordered[i].sortOrder == i) continue;
      await widget.database.upsertCategory(
        reordered[i].copyWith(sortOrder: i, updatedAtEpochMs: now),
      );
    }
    await _load();
  }

  Future<void> _openEditor([Category? existing]) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    var selectedColor =
        existing?.colorHex ??
        UiHelpers.toHexColor(TempoColors.activityPalette.first);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        Future<void> save() async {
          final name = nameController.text.trim();
          if (name.isEmpty) return;
          final now = DateTime.now().toUtc().millisecondsSinceEpoch;
          final category = existing != null
              ? existing.copyWith(
                  name: name,
                  colorHex: selectedColor,
                  updatedAtEpochMs: now,
                )
              : Category(
                  id: const Uuid().v4(),
                  name: name,
                  colorHex: selectedColor,
                  sortOrder: _categories.length,
                  createdAtEpochMs: now,
                  updatedAtEpochMs: now,
                );
          try {
            await widget.database.upsertCategory(category);
          } catch (_) {
            _setStatus('That name is already used.');
            return;
          }
          if (ctx.mounted) Navigator.of(ctx).pop();
          await _load();
        }

        Future<void> delete() async {
          final confirm = await showDialog<bool>(
            context: ctx,
            builder: (dCtx) => AlertDialog(
              title: const Text('Delete this category?'),
              content: const Text(
                'Its activities stay in your record, without a category.',
              ),
              actions: [
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: TempoColors.ink),
                  onPressed: () => Navigator.of(dCtx).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: TempoColors.ink,
                    textStyle: TempoText.label.copyWith(fontSize: 14),
                  ),
                  onPressed: () => Navigator.of(dCtx).pop(true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
          if (confirm != true) return;
          await widget.database.deleteCategory(existing!.id);
          if (ctx.mounted) Navigator.of(ctx).pop();
          await _load();
        }

        return StatefulBuilder(
          builder: (context, setModalState) {
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
                      existing == null ? 'New category' : 'Edit category',
                      style: TempoText.screenTitle.copyWith(
                        color: TempoColors.ink,
                        fontSize: 24,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: nameController,
                      style: TempoText.body.copyWith(color: TempoColors.ink),
                      cursorColor: TempoColors.ink,
                      autofocus: existing == null,
                      decoration: InputDecoration(
                        hintText: 'e.g. Essentials, Productive, Leisure',
                        hintStyle: TempoText.body.copyWith(
                          color: TempoColors.inkFaint,
                        ),
                        filled: true,
                        fillColor: TempoColors.paper,
                        contentPadding: const EdgeInsets.all(14),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(TempoRadii.row),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'COLOUR',
                      style: TempoText.overline.copyWith(
                        color: TempoColors.inkMuted,
                      ),
                    ),
                    const SizedBox(height: 10),
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
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Activities in this category use this colour.',
                      style: TempoText.label.copyWith(
                        color: TempoColors.inkMuted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 22),
                    Row(
                      children: [
                        if (existing != null) ...[
                          Expanded(
                            child: _SheetPill(
                              label: 'Delete',
                              filled: false,
                              onTap: delete,
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: _SheetPill(
                            label: 'Save',
                            filled: true,
                            onTap: save,
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
    nameController.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                    'Categories group activities on the Today page.',
                    style: TempoText.body.copyWith(
                      color: TempoColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (_categories.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Text(
                          'No categories yet.',
                          style: TempoText.body.copyWith(
                            color: TempoColors.textMuted,
                          ),
                        ),
                      ),
                    )
                  else
                    for (var i = 0; i < _categories.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _CategoryRow(
                          category: _categories[i],
                          activityCount: _activityCount(_categories[i]),
                          canMoveUp: i > 0,
                          canMoveDown: i < _categories.length - 1,
                          onTap: () => _openEditor(_categories[i]),
                          onMoveUp: () => _move(i, -1),
                          onMoveDown: () => _move(i, 1),
                        ),
                      ),
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
            'Categories',
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
            onTap: () => _openEditor(),
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
}

class _CategoryRow extends StatelessWidget {
  final Category category;
  final int activityCount;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback onTap;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  const _CategoryRow({
    required this.category,
    required this.activityCount,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onTap,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  @override
  Widget build(BuildContext context) {
    final color = UiHelpers.parseHexColor(category.colorHex);
    final count = activityCount == 1
        ? '1 activity'
        : '$activityCount activities';
    return Semantics(
      button: true,
      label: '${category.name}, $count. Edit.',
      child: Material(
        color: TempoColors.surface,
        borderRadius: BorderRadius.circular(TempoRadii.row),
        child: InkWell(
          borderRadius: BorderRadius.circular(TempoRadii.row),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        category.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TempoText.body.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        count,
                        style: TempoText.label.copyWith(
                          color: TempoColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: canMoveUp ? onMoveUp : null,
                  tooltip: 'Move up',
                  icon: const Icon(Icons.keyboard_arrow_up_rounded),
                  color: Colors.white,
                  disabledColor: TempoColors.textMuted.withValues(alpha: 0.3),
                ),
                IconButton(
                  onPressed: canMoveDown ? onMoveDown : null,
                  tooltip: 'Move down',
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  color: Colors.white,
                  disabledColor: TempoColors.textMuted.withValues(alpha: 0.3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
