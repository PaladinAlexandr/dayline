import 'model.dart';

/// Shared calendar rules also drive the native Windows desktop widget.
List<Map<String, Object>> desktopWidgetEntries(
  List<PlanItem> items,
  DateTime now,
) {
  final day = dayOnly(now);
  final upcoming = agenda(
    items,
    day,
    DateTime(day.year, day.month, day.day + 30),
  ).where((o) => !o.done && o.end.isAfter(now)).take(50);
  return upcoming.map((o) {
    final date = dayOnly(o.start);
    final tomorrow = DateTime(day.year, day.month, day.day + 1);
    final label = date == day
        ? 'Сегодня'
        : date == tomorrow
        ? 'Завтра'
        : '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}';
    return <String, Object>{
      'id': o.item.id,
      'title': o.item.title,
      'detail': '$label · ${o.time}',
      'category': '${o.item.task ? 'Задача' : 'Событие'} · ${o.item.category}',
      'color': o.item.color,
    };
  }).toList();
}
