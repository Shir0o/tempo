import 'package:material_ui/material_ui.dart';

import '../../core/speech/speech_input.dart';
import '../../core/state/activity_filter_controller.dart';
import '../../data/models/models.dart';
import 'activity_result_row.dart';
import 'theme/tempo_theme.dart';

/// Values the sheet needs that live in the dashboard.
class FilterSheetData {
  final String lapLabel;
  final Map<String, int> durations;
  final Map<String, String> categoryNames;

  const FilterSheetData({
    required this.lapLabel,
    required this.durations,
    required this.categoryNames,
  });
}

Future<void> showActivityFilterSheet({
  required BuildContext context,
  required ActivityFilterController controller,
  required List<Activity> catalog,
  required SpeechInput? speechInput,
  required FilterSheetData data,
  required ValueChanged<Activity> onPick,
  required VoidCallback onManageActivities,
}) {
  controller.setCatalog(catalog);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: TempoColors.panel,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(TempoRadii.sheet),
      ),
    ),
    builder: (_) => _ActivityFilterSheet(
      controller: controller,
      speechInput: speechInput,
      data: data,
      onPick: onPick,
      onManageActivities: onManageActivities,
    ),
  );
}

class _ActivityFilterSheet extends StatefulWidget {
  final ActivityFilterController controller;
  final SpeechInput? speechInput;
  final FilterSheetData data;
  final ValueChanged<Activity> onPick;
  final VoidCallback onManageActivities;

  const _ActivityFilterSheet({
    required this.controller,
    required this.speechInput,
    required this.data,
    required this.onPick,
    required this.onManageActivities,
  });

  @override
  State<_ActivityFilterSheet> createState() => _ActivityFilterSheetState();
}

class _ActivityFilterSheetState extends State<_ActivityFilterSheet>
    with WidgetsBindingObserver {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _text.addListener(_onTextChanged);
    final speech = widget.speechInput;
    if (speech != null) {
      speech.isAvailable().then((available) {
        if (mounted) widget.controller.setAvailability(available);
      });
    } else {
      widget.controller.setAvailability(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _text.removeListener(_onTextChanged);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final leaving =
        state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
    if (leaving &&
        !widget.controller.isPending &&
        mounted &&
        Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  void _onTextChanged() => widget.controller.setQuery(_text.text);

  void _closeAndPick(Activity activity) {
    Navigator.of(context).pop();
    widget.onPick(activity);
  }

  void _closeAndManage() {
    Navigator.of(context).pop();
    widget.onManageActivities();
  }

  Future<void> _listen() async {
    final speech = widget.speechInput;
    if (speech == null || widget.controller.isPending) return;
    widget.controller.markListening();
    try {
      final transcript = await speech.listen();
      if (!mounted) return;
      if (transcript != null && transcript.isNotEmpty) {
        _text.text = transcript;
        _text.selection = TextSelection.collapsed(offset: transcript.length);
      }
    } finally {
      widget.controller.finishListening();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: FractionallySizedBox(
        heightFactor: 0.7,
        child: SafeArea(
          top: false,
          child: AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(),
                _buildField(),
                Expanded(child: _buildBody()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: TempoColors.track,
                borderRadius: BorderRadius.circular(TempoRadii.pill),
              ),
            ),
          ),
          Text(
            'Find an Activity',
            style: TempoText.title.copyWith(
              color: TempoColors.ink,
              fontSize: 22,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.data.lapLabel,
            style: TempoText.label.copyWith(
              color: TempoColors.inkMuted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildField() {
    final controller = widget.controller;
    final hasText = _text.text.isNotEmpty;
    final showMic = controller.availability == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: TextField(
        key: const ValueKey('activity-filter-field'),
        controller: _text,
        focusNode: _focus,
        autofocus: true,
        textInputAction: TextInputAction.search,
        style: TempoText.body.copyWith(color: TempoColors.ink),
        decoration: InputDecoration(
          hintText: 'Filter Activities',
          hintStyle: TempoText.body.copyWith(color: TempoColors.inkMuted),
          filled: true,
          fillColor: TempoColors.paper,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(TempoRadii.row),
            borderSide: BorderSide.none,
          ),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasText)
                IconButton(
                  key: const ValueKey('activity-filter-clear'),
                  tooltip: 'Clear query',
                  onPressed: () {
                    _text.clear();
                    _focus.requestFocus();
                  },
                  icon: const Icon(Icons.close, color: TempoColors.inkMuted),
                ),
              if (showMic)
                IconButton(
                  key: const ValueKey('activity-filter-mic'),
                  tooltip: controller.isPending
                      ? 'Starting voice input'
                      : 'Start voice input',
                  onPressed: controller.isPending ? null : _listen,
                  icon: Icon(
                    controller.isPending ? Icons.hourglass_top : Icons.mic_none,
                    color: TempoColors.ink,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final controller = widget.controller;
    final data = widget.data;

    if (!controller.hasQuery) {
      return const Center(
        child: Text(
          'Type a name to narrow the list.',
          style: TextStyle(color: TempoColors.inkMuted),
        ),
      );
    }

    if (controller.matches.isEmpty) {
      return _buildNoMatch();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (controller.total > controller.matches.length)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
            child: Text(
              'showing ${controller.matches.length} of ${controller.total}',
              style: TempoText.overline.copyWith(color: TempoColors.inkMuted),
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            itemCount: controller.matches.length,
            itemBuilder: (context, index) {
              final match = controller.matches[index];
              final activity = match.activity;
              final categoryId = activity.categoryId;
              return ActivityResultRow(
                activity: activity,
                durationMs: data.durations[activity.id] ?? 0,
                categoryName: categoryId == null
                    ? null
                    : data.categoryNames[categoryId],
                onTap: () => _closeAndPick(activity),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildNoMatch() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'No unarchived Activity matches "${_text.text.trim()}".',
              textAlign: TextAlign.center,
              style: TempoText.body.copyWith(color: TempoColors.ink),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              alignment: WrapAlignment.center,
              children: [
                TextButton(
                  onPressed: () {
                    _text.clear();
                    _focus.requestFocus();
                  },
                  child: const Text('Clear'),
                ),
                TextButton(
                  onPressed: _closeAndManage,
                  child: const Text('Manage Activities'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
