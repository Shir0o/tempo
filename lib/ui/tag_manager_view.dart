import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import 'helpers/ui_helpers.dart';
import 'theme/tempo_theme.dart';

/// Management interface for the Tags attached to Records, including which one
/// is the Contact Tag. At most one tag carries that flag; setting it on another
/// tag clears the previous one.
class TagManagerView extends StatefulWidget {
  final TempoDatabase database;

  const TagManagerView({super.key, required this.database});

  @override
  State<TagManagerView> createState() => _TagManagerViewState();
}

class _TagManagerViewState extends State<TagManagerView> {
  bool _isLoading = true;
  List<Tag> _tags = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final tags = await widget.database.getAllTags();
      if (mounted) {
        setState(() {
          _tags = tags;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

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

  Future<void> _openEditor([Tag? existing]) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    var selectedColor =
        existing?.colorHex ??
        UiHelpers.toHexColor(TempoColors.activityPalette.first);
    var isContact = existing?.isContact ?? false;
    final hasContact = _tags.any((tag) => tag.isContact);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        Future<void> save() async {
          final name = nameController.text.trim();
          if (name.isEmpty) return;
          final now = DateTime.now().toUtc().millisecondsSinceEpoch;
          final tag = existing != null
              ? existing.copyWith(
                  name: name,
                  colorHex: selectedColor,
                  isContact: isContact,
                  updatedAtEpochMs: now,
                )
              : Tag(
                  id: const Uuid().v4(),
                  name: name,
                  colorHex: selectedColor,
                  isContact: isContact,
                  createdAtEpochMs: now,
                  updatedAtEpochMs: now,
                );
          try {
            if (existing == null) {
              await widget.database.insertTag(tag);
            } else {
              await widget.database.updateTag(tag);
            }
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
              title: const Text('Delete this tag?'),
              content: const Text(
                'Records keep their Activity and note; only this label is '
                'removed.',
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
          await widget.database.deleteTag(existing!.id);
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
                      existing == null ? 'New tag' : 'Edit tag',
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
                        hintText: 'e.g. Contact, Travel, Project',
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
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
                      decoration: BoxDecoration(
                        color: TempoColors.paper,
                        borderRadius: BorderRadius.circular(TempoRadii.row),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Contact tag',
                                  style: TempoText.body.copyWith(
                                    color: TempoColors.ink,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  'Attached when a note names someone after '
                                  'the w/ or with marker.',
                                  style: TempoText.label.copyWith(
                                    color: TempoColors.inkMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: isContact,
                            onChanged: (value) =>
                                setModalState(() => isContact = value),
                          ),
                        ],
                      ),
                    ),
                    if (isContact && hasContact && existing?.isContact != true)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'This replaces the tag currently marked as Contact.',
                          style: TempoText.label.copyWith(
                            color: TempoColors.inkMuted,
                          ),
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
                    'Tags label Records across Activities. One tag can be the '
                    'Contact tag: it is attached whenever a note names someone '
                    'after the w/ or with marker.',
                    style: TempoText.body.copyWith(
                      color: TempoColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (_tags.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Text(
                          'No tags yet.',
                          style: TempoText.body.copyWith(
                            color: TempoColors.textMuted,
                          ),
                        ),
                      ),
                    )
                  else
                    for (final tag in _tags)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _TagRow(tag: tag, onTap: () => _openEditor(tag)),
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
            'Tags',
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

class _TagRow extends StatelessWidget {
  final Tag tag;
  final VoidCallback onTap;

  const _TagRow({required this.tag, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = UiHelpers.parseHexColor(tag.colorHex);
    final subtitle = tag.isContact ? 'Contact tag' : 'Tag';
    return Semantics(
      button: true,
      label: '${tag.name}, $subtitle. Edit.',
      child: Material(
        color: TempoColors.surface,
        borderRadius: BorderRadius.circular(TempoRadii.row),
        child: InkWell(
          borderRadius: BorderRadius.circular(TempoRadii.row),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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
                  child: Text(
                    tag.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TempoText.body.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (tag.isContact)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: TempoColors.accent,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'Contact',
                      style: TempoText.label.copyWith(
                        color: TempoColors.ink,
                        fontWeight: FontWeight.w700,
                      ),
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
