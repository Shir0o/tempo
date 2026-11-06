import 'package:flutter/foundation.dart';

import '../../data/models/models.dart';
import 'activity_matcher.dart';

/// Holds the filter sheet's state so it can be tested without a widget tree.
class ActivityFilterController extends ChangeNotifier {
  List<Activity> _catalog = const [];
  String _query = '';
  ActivityRanking _ranking = const ActivityRanking(matches: [], total: 0);
  bool? _availability;
  bool _pending = false;

  List<Activity> get catalog => List.unmodifiable(_catalog);
  String get query => _query;
  List<ActivityMatch> get matches => _ranking.matches;
  int get total => _ranking.total;
  bool? get availability => _availability;
  bool get isPending => _pending;
  bool get hasQuery => _query.trim().isNotEmpty;

  void setCatalog(List<Activity> catalog) {
    _catalog = List<Activity>.of(catalog);
    _recompute();
    notifyListeners();
  }

  void setQuery(String query) {
    if (_query == query) return;
    _query = query;
    _recompute();
    notifyListeners();
  }

  void clear() {
    if (_query.isEmpty) return;
    _query = '';
    _recompute();
    notifyListeners();
  }

  void setAvailability(bool available) {
    if (_availability == available) return;
    _availability = available;
    notifyListeners();
  }

  void markListening() {
    if (_pending) return;
    _pending = true;
    notifyListeners();
  }

  void finishListening() {
    if (!_pending) return;
    _pending = false;
    notifyListeners();
  }

  void _recompute() {
    _ranking = rankActivities(_catalog, _query);
  }
}
