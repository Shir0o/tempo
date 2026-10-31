import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import 'helpers/ui_helpers.dart';

/// Management interface for creating, customizing, and organizing habits/activities.
class ActivityManagerView extends StatefulWidget {
  final TempoDatabase database;

  const ActivityManagerView({super.key, required this.database});

  @override
  State<ActivityManagerView> createState() => _ActivityManagerViewState();
}

class _ActivityManagerViewState extends State<ActivityManagerView> {
  bool _isLoading = true;
  List<Activity> _activities = [];

  static const List<String> _colorPalette = [
    '#4CAF50', // Green
    '#2196F3', // Blue
    '#9C27B0', // Purple
    '#FF9800', // Orange
    '#E91E63', // Pink
    '#00BCD4', // Cyan
    '#FF5722', // Deep Orange
    '#607D8B', // Blue Grey
    '#3F51B5', // Indigo
    '#009688', // Teal
    '#FFC107', // Amber
    '#795548', // Brown
  ];

  static const List<String> _iconOptions = [
    'schedule',
    'code',
    'fitness_center',
    'directions_run',
    'book',
    'work',
    'school',
    'brush',
    'music_note',
    'local_cafe',
    'sports_esports',
    'bed',
    'restaurant',
    'build',
    'phone_android',
    'movie',
    'pets',
    'shopping_cart',
  ];

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
      if (mounted) {
        setState(() {
          _activities = list;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _openActivityEditor([Activity? existing]) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    String selectedColor = existing?.colorHex ?? _colorPalette.first;
    String selectedIcon = existing?.iconName ?? _iconOptions.first;
    bool isPinned = existing?.isPinned ?? false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C1C24),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 20,
                right: 20,
                top: 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      existing == null
                          ? 'New Habit / Activity'
                          : 'Edit Activity',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Name input
                    TextField(
                      controller: nameController,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      autofocus: existing == null,
                      decoration: InputDecoration(
                        labelText: 'Activity Name',
                        labelStyle: const TextStyle(color: Colors.white60),
                        hintText: 'e.g. Coding, Reading, Workout',
                        hintStyle: const TextStyle(color: Colors.white24),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Pinned Switch
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Pin to 1-Tap Dashboard',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      subtitle: const Text(
                        'Pinned habits appear in the quick capture grid',
                        style: TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                      value: isPinned,
                      activeTrackColor: const Color(0xFF4CAF50),
                      onChanged: (val) => setModalState(() => isPinned = val),
                    ),
                    const SizedBox(height: 12),

                    // Color palette
                    const Text(
                      'COLOR',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _colorPalette.map((hex) {
                        final color = UiHelpers.parseHexColor(hex);
                        final isSelected =
                            hex.toLowerCase() == selectedColor.toLowerCase();
                        return GestureDetector(
                          onTap: () => setModalState(() => selectedColor = hex),
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isSelected
                                    ? Colors.white
                                    : Colors.transparent,
                                width: 2.5,
                              ),
                            ),
                            child: isSelected
                                ? const Icon(
                                    Icons.check,
                                    color: Colors.white,
                                    size: 18,
                                  )
                                : null,
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),

                    // Icon options
                    const Text(
                      'ICON',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _iconOptions.map((iconKey) {
                        final icon = UiHelpers.getIconData(iconKey);
                        final isSelected = iconKey == selectedIcon;
                        return GestureDetector(
                          onTap: () =>
                              setModalState(() => selectedIcon = iconKey),
                          child: Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? UiHelpers.parseHexColor(selectedColor)
                                        .withValues(alpha: 0.3)
                                  : Colors.white.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isSelected
                                    ? UiHelpers.parseHexColor(selectedColor)
                                    : Colors.transparent,
                              ),
                            ),
                            child: Icon(
                              icon,
                              size: 18,
                              color: isSelected ? Colors.white : Colors.white60,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 20),

                    // Save Button
                    ElevatedButton(
                      onPressed: () async {
                        final name = nameController.text.trim();
                        if (name.isEmpty) return;

                        final now = DateTime.now()
                            .toUtc()
                            .millisecondsSinceEpoch;
                        if (existing != null) {
                          final updated = existing.copyWith(
                            name: name,
                            colorHex: selectedColor,
                            iconName: selectedIcon,
                            isPinned: isPinned,
                            updatedAtEpochMs: now,
                          );
                          await widget.database.updateActivity(updated);
                        } else {
                          final newAct = Activity(
                            id: const Uuid().v4(),
                            name: name,
                            colorHex: selectedColor,
                            iconName: selectedIcon,
                            isPinned: isPinned,
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
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4CAF50),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(
                        existing != null ? 'Save Changes' : 'Create Activity',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _toggleArchive(Activity activity) async {
    final updated = activity.copyWith(
      isArchived: !activity.isArchived,
      updatedAtEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
    await widget.database.updateActivity(updated);
    _loadActivities();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121216),
      appBar: AppBar(
        title: const Text(
          'Habits & Activities',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: const Color(0xFF121216),
        elevation: 0,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openActivityEditor(),
        backgroundColor: const Color(0xFF4CAF50),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF4CAF50)),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: _activities.length,
              itemBuilder: (context, index) {
                final activity = _activities[index];
                final color = UiHelpers.parseHexColor(activity.colorHex);
                final icon = UiHelpers.getIconData(activity.iconName);

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: const Color(0xFF1A1A22),
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.05),
                      ),
                    ),
                    child: ListTile(
                      onTap: () => _openActivityEditor(activity),
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(icon, color: color, size: 20),
                      ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              activity.name,
                              style: TextStyle(
                                color: activity.isArchived
                                    ? Colors.white38
                                    : Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                decoration: activity.isArchived
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                          if (activity.isPinned)
                            const Icon(
                              Icons.push_pin,
                              color: Color(0xFF4CAF50),
                              size: 16,
                            ),
                        ],
                      ),
                      subtitle: Text(
                        activity.isArchived
                            ? 'Archived'
                            : (activity.isPinned
                                  ? 'Pinned to dashboard'
                                  : 'Standard habit'),
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                      trailing: PopupMenuButton<String>(
                        icon: const Icon(
                          Icons.more_vert,
                          color: Colors.white54,
                        ),
                        color: const Color(0xFF22222C),
                        onSelected: (val) {
                          if (val == 'edit') {
                            _openActivityEditor(activity);
                          } else if (val == 'archive') {
                            _toggleArchive(activity);
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'edit',
                            child: Text(
                              'Edit',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'archive',
                            child: Text(
                              activity.isArchived ? 'Unarchive' : 'Archive',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
