import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/time/timezone_id.dart';
import '../theme/tempo_theme.dart';
import 'history_widgets.dart';

/// Opens the time zone picker for one Edge of a Record and returns the zone
/// picked, or null when dismissed. Nothing is applied here: the edit sheet
/// stages the pick until Save.
///
/// The Edge's instant never moves; each row shows what that instant reads as
/// in the zone, so the right one is easy to spot.
Future<String?> showZonePicker(
  BuildContext context, {
  required String edgeName,
  required int atEpochMs,
  required String currentZone,
  required String deviceZone,
  Iterable<String> recent = const [],
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.92,
      child: _ZonePicker(
        edgeName: edgeName,
        atEpochMs: atEpochMs,
        currentZone: currentZone,
        deviceZone: deviceZone,
        recent: [currentZone, ...recent],
      ),
    ),
  );
}

class _ZonePicker extends StatefulWidget {
  final String edgeName;
  final int atEpochMs;
  final String currentZone;
  final String deviceZone;
  final List<String> recent;

  const _ZonePicker({
    required this.edgeName,
    required this.atEpochMs,
    required this.currentZone,
    required this.deviceZone,
    required this.recent,
  });

  @override
  State<_ZonePicker> createState() => _ZonePickerState();
}

class _ZonePickerState extends State<_ZonePicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final zones = timezoneChoices(
      deviceZone: widget.deviceZone,
      recent: widget.recent,
      query: _query,
      atEpochMs: widget.atEpochMs,
    );
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
                          '${widget.edgeName} time zone',
                          style: TempoText.title.copyWith(
                            fontSize: 22,
                            color: TempoColors.ink,
                          ),
                        ),
                        Text(
                          'The moment stays the same; only its clock changes',
                          style: TempoText.label.copyWith(
                            color: TempoColors.inkMuted,
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
                cursorColor: TempoColors.ink,
                textInputAction: TextInputAction.search,
                onChanged: (v) => setState(() => _query = v),
                onSubmitted: (_) {
                  if (zones.length == 1) {
                    Navigator.of(context).pop(zones.first);
                  }
                },
                style: TempoText.body.copyWith(
                  fontSize: 16,
                  color: TempoColors.ink,
                ),
                decoration: InputDecoration(
                  hintText: 'Search a city or abbreviation',
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
              child: zones.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        'No time zone matches “${_query.trim()}”.',
                        style: TempoText.body.copyWith(
                          color: TempoColors.inkMuted,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                      itemCount: zones.length,
                      itemBuilder: (context, i) => _ZoneRow(
                        zone: zones[i],
                        atEpochMs: widget.atEpochMs,
                        isDevice: zones[i] == widget.deviceZone,
                        current: zones[i] == widget.currentZone,
                        onTap: () => Navigator.of(context).pop(zones[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZoneRow extends StatelessWidget {
  final String zone;
  final int atEpochMs;
  final bool isDevice;
  final bool current;
  final VoidCallback onTap;

  const _ZoneRow({
    required this.zone,
    required this.atEpochMs,
    required this.isDevice,
    required this.current,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final name = zone.replaceAll('_', ' ');
    final abbreviation = zoneAbbreviationAt(zone, atEpochMs);
    final time = DateFormat('HH:mm').format(wallClockAt(zone, atEpochMs));
    final detail = isDevice ? 'This device · $abbreviation' : abbreviation;
    return Semantics(
      button: true,
      selected: current,
      label: '$name, $detail, reads $time',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(TempoRadii.row),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TempoText.body.copyWith(
                        fontSize: 16,
                        fontWeight: current ? FontWeight.w700 : null,
                        color: TempoColors.ink,
                      ),
                    ),
                    SheetOverline(detail),
                  ],
                ),
              ),
              Text(
                time,
                style: TempoText.numeral.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: TempoColors.ink,
                ),
              ),
              SizedBox(
                width: 32,
                child: current
                    ? const Icon(
                        Icons.check_rounded,
                        size: 20,
                        color: TempoColors.ink,
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
