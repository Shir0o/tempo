import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/core/state/activity_filter_controller.dart';
import 'package:tempo/data/models/models.dart';

Activity activity(String id, String name, {bool archived = false}) => Activity(
  id: id,
  name: name,
  isArchived: archived,
  createdAtEpochMs: 0,
  updatedAtEpochMs: 0,
);

void main() {
  test('setting the catalog and query produces matches', () {
    final controller = ActivityFilterController()
      ..setCatalog([activity('a1', 'Cleaning'), activity('a2', 'Laundry')])
      ..setQuery('clea');

    expect(controller.matches, hasLength(1));
    expect(controller.matches.single.activity.id, 'a1');
    expect(controller.total, 1);

    controller.dispose();
  });

  test('clear empties the query and the matches', () {
    final controller = ActivityFilterController()
      ..setCatalog([activity('a1', 'Cleaning')])
      ..setQuery('clea')
      ..clear();

    expect(controller.query, isEmpty);
    expect(controller.matches, isEmpty);
    expect(controller.hasQuery, isFalse);

    controller.dispose();
  });

  test('a catalog change recomputes an active query', () {
    final controller = ActivityFilterController()
      ..setCatalog([activity('a1', 'Cleaning')])
      ..setQuery('clean');

    controller.setCatalog([
      activity('a1', 'Cleaning'),
      activity('a2', 'Cleaner'),
    ]);

    expect(controller.total, 2);
    controller.dispose();
  });

  test('availability and pending transitions notify listeners', () {
    final controller = ActivityFilterController();
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.setAvailability(true);
    controller.markListening();
    controller.finishListening();

    expect(controller.availability, isTrue);
    expect(controller.isPending, isFalse);
    expect(notifications, 3);

    controller.dispose();
  });
}
