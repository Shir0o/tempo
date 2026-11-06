import 'package:flutter/material.dart';

import '../core/state/people_index.dart';
import '../data/models/models.dart';
import 'history/history_widgets.dart';
import 'theme/tempo_theme.dart';

/// What the note sheet hands back when confirmed.
class NoteSheetResult {
  final String comment;
  final List<String> tagIds;

  const NoteSheetResult({required this.comment, required this.tagIds});
}

/// The compact note sheet: People, comment and Tags for one Record.
///
/// Used after a label ("Add note", with Save / Skip) and before one
/// (long-press, with Cancel / `Log <Activity>`). Returns null when skipped or
/// dismissed. [suggestedReading] prefills an empty comment; nothing fills it
/// yet (AutoAdvance will).
Future<NoteSheetResult?> showNoteSheet(
  BuildContext context, {
  required String activityName,
  required Color activityColor,
  required String subtitle,
  required List<Tag> tags,
  required List<String> people,
  String initialComment = '',
  List<String> initialTagIds = const [],
  String suggestedReading = '',
  String confirmLabel = 'Save',
  String dismissLabel = 'Skip',
}) {
  return showModalBottomSheet<NoteSheetResult>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _NoteSheet(
      activityName: activityName,
      activityColor: activityColor,
      subtitle: subtitle,
      tags: tags,
      people: people,
      initialComment: initialComment.isEmpty
          ? suggestedReading
          : initialComment,
      initialTagIds: initialTagIds,
      confirmLabel: confirmLabel,
      dismissLabel: dismissLabel,
    ),
  );
}

class _NoteSheet extends StatefulWidget {
  final String activityName;
  final Color activityColor;
  final String subtitle;
  final List<Tag> tags;
  final List<String> people;
  final String initialComment;
  final List<String> initialTagIds;
  final String confirmLabel;
  final String dismissLabel;

  const _NoteSheet({
    required this.activityName,
    required this.activityColor,
    required this.subtitle,
    required this.tags,
    required this.people,
    required this.initialComment,
    required this.initialTagIds,
    required this.confirmLabel,
    required this.dismissLabel,
  });

  @override
  State<_NoteSheet> createState() => _NoteSheetState();
}

class _NoteSheetState extends State<_NoteSheet> {
  late final TextEditingController _comment = TextEditingController(
    text: widget.initialComment,
  );
  late List<String> _tagIds = List.of(widget.initialTagIds);
  late final String? _contactId = contactTagId(widget.tags);

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  void _confirm() {
    Navigator.of(context)
        .pop(NoteSheetResult(comment: _comment.text.trim(), tagIds: _tagIds));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                container: true,
                label: '${widget.activityName}, ${widget.subtitle}',
                excludeSemantics: true,
                child: Row(
                  children: [
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: widget.activityColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        widget.activityName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TempoText.title.copyWith(
                          color: TempoColors.ink,
                          fontSize: 22,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
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
              const SizedBox(height: 14),
              const SheetOverline('With'),
              PeopleChips(
                comment: _comment,
                suggestions: widget.people,
                onPeopleChanged: (names) => setState(
                  () => _tagIds = tagIdsWithContact(
                    _tagIds,
                    _contactId,
                    hasPeople: names.isNotEmpty,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _comment,
                cursorColor: TempoColors.ink,
                style: TempoText.body.copyWith(color: TempoColors.ink),
                decoration: InputDecoration(
                  hintText: 'Add a note',
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
              if (widget.tags.isNotEmpty) ...[
                const SizedBox(height: 2),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final tag in widget.tags)
                      SheetChip(
                        label: tag.name,
                        height: 32,
                        selected: _tagIds.contains(tag.id),
                        onTap: () => setState(() {
                          if (!_tagIds.remove(tag.id)) _tagIds.add(tag.id);
                        }),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: SheetOutlineButton(
                      label: widget.dismissLabel,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _confirm,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        backgroundColor: TempoColors.ink,
                        foregroundColor: Colors.white,
                        shape: const StadiumBorder(),
                        textStyle: const TextStyle(
                          fontFamily: tempoFontFamily,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: Text(
                        widget.confirmLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// People chips bound to a comment field.
///
/// A chip is selected while its name is written after the NameMarker in
/// [comment], so typing and tapping stay in step. Tapping rewrites that part
/// of the comment; "+ New name" adds a typed one. [onPeopleChanged] runs after
/// each tap with the People now named, so the caller can keep the Contact Tag
/// in step.
class PeopleChips extends StatelessWidget {
  final TextEditingController comment;
  final List<String> suggestions;
  final ValueChanged<List<String>> onPeopleChanged;

  const PeopleChips({
    super.key,
    required this.comment,
    required this.suggestions,
    required this.onPeopleChanged,
  });

  void _write(List<String> names) {
    comment.text = withPeople(comment.text, names);
    onPeopleChanged(names);
  }

  Future<void> _addNew(BuildContext context, List<String> selected) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewNameDialog(),
    );
    if (name == null) return;
    final known = selected.any((s) => s.toLowerCase() == name.toLowerCase());
    if (!known) _write([...selected, name]);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: comment,
      builder: (context, _) {
        final selected = peopleIn(comment.text);
        final selectedKeys = {for (final s in selected) s.toLowerCase()};
        final suggestionKeys = {for (final s in suggestions) s.toLowerCase()};
        final chips = [
          ...suggestions,
          for (final s in selected)
            if (!suggestionKeys.contains(s.toLowerCase())) s,
        ];
        return Wrap(
          spacing: 6,
          children: [
            for (final name in chips)
              SheetChip(
                label: name,
                height: 32,
                selected: selectedKeys.contains(name.toLowerCase()),
                onTap: () => _write(
                  selectedKeys.contains(name.toLowerCase())
                      ? [
                          for (final s in selected)
                            if (s.toLowerCase() != name.toLowerCase()) s,
                        ]
                      : [...selected, name],
                ),
              ),
            SheetChip(
              label: '+ New name',
              height: 32,
              selected: false,
              onTap: () => _addNew(context, selected),
            ),
          ],
        );
      },
    );
  }
}

/// Asks for one Person's name. Each word is capitalised, and the name must be
/// one or two words so it reads back the same from the comment.
class _NewNameDialog extends StatefulWidget {
  const _NewNameDialog();

  @override
  State<_NewNameDialog> createState() => _NewNameDialogState();
}

class _NewNameDialogState extends State<_NewNameDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .map((word) => word[0].toUpperCase() + word.substring(1))
        .join(' ');
    if (name.isEmpty) return;
    final read = peopleIn('w/ $name');
    if (read.length != 1 || read.first != name) {
      setState(() => _error = 'One or two words, letters only');
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New name'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        onSubmitted: (_) => _submit(),
        cursorColor: TempoColors.ink,
        style: TempoText.body.copyWith(color: TempoColors.ink),
        decoration: InputDecoration(
          hintText: 'Name',
          hintStyle: TempoText.body.copyWith(color: TempoColors.inkFaint),
          errorText: _error,
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: TempoColors.ink),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: TempoColors.ink),
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
