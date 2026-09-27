import 'dart:convert';
import 'dart:math';

String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);
String clockText(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
String newId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${Random.secure().nextInt(0x7fffffff).toRadixString(36)}';
const months = [
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];
const monthNames = [
  'Январь',
  'Февраль',
  'Март',
  'Апрель',
  'Май',
  'Июнь',
  'Июль',
  'Август',
  'Сентябрь',
  'Октябрь',
  'Ноябрь',
  'Декабрь',
];
const weekdays = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
const repeatNames = {
  'none': 'Не повторять',
  'daily': 'Каждый день',
  'weekdays': 'По будням',
  'weekly': 'Каждую неделю',
  'monthly': 'Каждый месяц',
};

class PlanItem {
  final String id, title, note, category, repeat;
  final DateTime start, end;
  final bool task, allDay;
  final int priority, color;
  final List<int> reminders;
  final List<String> completed;
  PlanItem({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    this.task = true,
    this.allDay = false,
    this.note = '',
    this.category = 'Личное',
    this.repeat = 'none',
    this.priority = 1,
    this.color = 0,
    this.reminders = const [10],
    this.completed = const [],
  });
  factory PlanItem.fromJson(Map<String, dynamic> j) {
    final start = DateTime.parse(j['start'] as String);
    final end = DateTime.parse(j['end'] as String);
    if (!end.isAfter(start) ||
        end.difference(start).inHours > 745 ||
        start.year < 2000 ||
        end.year > 2100 ||
        !RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(j['id'] as String) ||
        (j['title'] as String).trim().isEmpty) {
      throw const FormatException('Некорректная запись');
    }
    return PlanItem(
      id: j['id'] as String,
      title: j['title'] as String,
      start: start,
      end: end,
      task: j['task'] as bool? ?? true,
      allDay: j['allDay'] as bool? ?? false,
      note: j['note'] as String? ?? '',
      category: j['category'] as String? ?? 'Личное',
      repeat: repeatNames.containsKey(j['repeat'])
          ? j['repeat'] as String
          : 'none',
      priority: (j['priority'] as int? ?? 1).clamp(0, 2),
      color: (j['color'] as int? ?? 0).clamp(0, 4),
      reminders:
          (j['reminders'] as List? ?? [])
              .cast<int>()
              .where((m) => m >= 0 && m <= 10080)
              .toSet()
              .toList()
            ..sort(),
      completed: (j['completed'] as List? ?? []).cast<String>(),
    );
  }
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'start': start.toIso8601String(),
    'end': end.toIso8601String(),
    'task': task,
    'allDay': allDay,
    'note': note,
    'category': category,
    'repeat': repeat,
    'priority': priority,
    'color': color,
    'reminders': reminders,
    'completed': completed,
  };
  PlanItem copy({
    String? id,
    String? title,
    DateTime? start,
    DateTime? end,
    bool? task,
    bool? allDay,
    String? note,
    String? category,
    String? repeat,
    int? priority,
    int? color,
    List<int>? reminders,
    List<String>? completed,
  }) => PlanItem(
    id: id ?? this.id,
    title: title ?? this.title,
    start: start ?? this.start,
    end: end ?? this.end,
    task: task ?? this.task,
    allDay: allDay ?? this.allDay,
    note: note ?? this.note,
    category: category ?? this.category,
    repeat: repeat ?? this.repeat,
    priority: priority ?? this.priority,
    color: color ?? this.color,
    reminders: reminders ?? this.reminders,
    completed: completed ?? this.completed,
  );
  bool occursOn(DateTime d) {
    final date = dayOnly(d), base = dayOnly(start);
    if (date.isBefore(base)) return false;
    return switch (repeat) {
      'daily' => true,
      'weekdays' => d.weekday <= 5,
      'weekly' => d.weekday == start.weekday,
      'monthly' =>
        d.day == min(start.day, DateTime(d.year, d.month + 1, 0).day),
      _ => date == base,
    };
  }

  Occurrence? occurrence(DateTime d) {
    if (!occursOn(d)) return null;
    final s = DateTime(d.year, d.month, d.day, start.hour, start.minute);
    final days = DateTime.utc(
      end.year,
      end.month,
      end.day,
    ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
    final e = DateTime(d.year, d.month, d.day + days, end.hour, end.minute);
    return Occurrence(this, s, e);
  }

  List<Occurrence> between(DateTime from, DateTime to) {
    final out = <Occurrence>[];
    final span = dayOnly(end).difference(dayOnly(start)).inDays.abs() + 1;
    for (
      var d = DateTime(from.year, from.month, from.day - span);
      d.isBefore(to);
      d = DateTime(d.year, d.month, d.day + 1)
    ) {
      final o = occurrence(d);
      if (o != null && o.end.isAfter(from) && o.start.isBefore(to)) out.add(o);
    }
    return out;
  }
}

class Occurrence {
  final PlanItem item;
  final DateTime start, end;
  Occurrence(this.item, this.start, this.end);
  String get key => dateKey(start);
  bool get done => item.completed.contains(item.repeat == 'none' ? 'all' : key);
  String get time =>
      item.allDay ? 'Весь день' : '${clockText(start)} – ${clockText(end)}';
}

List<Occurrence> agenda(List<PlanItem> items, DateTime from, DateTime to) =>
    items.expand((i) => i.between(from, to)).toList()..sort((a, b) {
      final c = a.start.compareTo(b.start);
      return c != 0 ? c : b.item.priority.compareTo(a.item.priority);
    });

/// One human-editable task per line. Metadata preserves rich app properties.
class MarkdownCodec {
  static String encode(List<PlanItem> items, {String? previous}) {
    final b = StringBuffer(
      '# Dayline\n\nКалендарь и задачи. Изменяйте название, дату 📅, время и флажок прямо в Obsidian.\n'
      'Интервал: `HH:mm–HH:mm`. Для нового дела добавьте `- [ ] Название 📅 YYYY-MM-DD`.\n'
      'Строки с метаданными dayline сохраняют напоминания, повторы и заметки.\n\n',
    );
    if (previous != null && previous.trim().isNotEmpty) {
      b.clear();
      for (final line in const LineSplitter().convert(previous)) {
        if (!RegExp(r'^\s*- \[([ xX])\] ').hasMatch(line)) b.writeln(line);
      }
    }
    final sorted = [...items]..sort((a, b) => a.start.compareTo(b.start));
    for (final i in sorted) {
      var display = i.start;
      if (i.repeat != 'none') {
        final today = dayOnly(DateTime.now());
        final from = i.start.isAfter(today) ? dayOnly(i.start) : today;
        for (var n = 0; n < 370; n++) {
          final date = DateTime(from.year, from.month, from.day + n);
          final occurrence = i.occurrence(date);
          if (occurrence != null && !occurrence.done) {
            display = occurrence.start;
            break;
          }
        }
      }
      final metadata = {...i.toJson(), 'mdDate': dateKey(display)};
      final done = i.completed.contains('all');
      final title = i.title
          .replaceAll(RegExp(r'[\r\n]'), ' ')
          .replaceAll('<!--', '‹!--');
      b.writeln(
        '- [${done ? 'x' : ' '}] $title 📅 ${dateKey(display)}${i.allDay ? '' : ' ${clockText(i.start)}–${clockText(i.end)}'} ${['🔽', '🔼', '⏫'][i.priority]} <!-- dayline:${base64Url.encode(utf8.encode(jsonEncode(metadata)))} -->',
      );
    }
    return b.toString();
  }

  static List<PlanItem> decode(String text) {
    final result = <PlanItem>[];
    final ids = <String>{};
    for (final line in const LineSplitter().convert(text)) {
      final match = RegExp(r'^\s*- \[([ xX])\] (.+)$').firstMatch(line);
      if (match == null) continue;
      var body = match[2]!;
      final meta = RegExp(
        r'\s*<!-- dayline:([A-Za-z0-9_=\-]+) -->',
      ).firstMatch(body);
      PlanItem? old;
      if (body.contains('<!-- dayline:') && meta == null) {
        throw const FormatException(
          'Повреждены метаданные Dayline. Файл не перезаписан.',
        );
      }
      String? mdDate;
      if (meta != null) {
        try {
          final json =
              jsonDecode(utf8.decode(base64Url.decode(meta[1]!)))
                  as Map<String, dynamic>;
          old = PlanItem.fromJson(json);
          mdDate = json['mdDate'] as String?;
        } catch (_) {
          throw const FormatException(
            'Повреждены метаданные Dayline. Файл не перезаписан.',
          );
        }
        body = body.replaceFirst(meta[0]!, '');
      }
      final date = RegExp(r'📅\s*(\d{4}-\d{2}-\d{2})').firstMatch(body);
      if (date == null && old == null) {
        throw const FormatException(
          'Добавьте дату 📅 YYYY-MM-DD к каждой задаче в Dayline.md.',
        );
      }
      final visibleDate = date == null ? old!.start : DateTime.parse(date[1]!);
      final preserveSeries =
          old != null && old.repeat != 'none' && dateKey(visibleDate) == mdDate;
      final d = preserveSeries ? old.start : visibleDate;
      if (date != null && dateKey(visibleDate) != date[1]) {
        throw const FormatException('Некорректная дата в Markdown');
      }
      if (date != null) body = body.replaceFirst(date[0]!, '');
      final range = RegExp(
        r'\b([0-2]\d):([0-5]\d)\s*[–—-]\s*([0-2]\d):([0-5]\d)\b',
      ).firstMatch(body);
      var s = dayOnly(d), e = DateTime(d.year, d.month, d.day + 1);
      if (range != null) {
        final h1 = int.parse(range[1]!), h2 = int.parse(range[3]!);
        if (h1 > 23 || h2 > 23) {
          throw const FormatException('Некорректное время');
        }
        s = DateTime(d.year, d.month, d.day, h1, int.parse(range[2]!));
        final oldDays = old == null
            ? 0
            : DateTime.utc(old.end.year, old.end.month, old.end.day)
                  .difference(
                    DateTime.utc(
                      old.start.year,
                      old.start.month,
                      old.start.day,
                    ),
                  )
                  .inDays;
        e = DateTime(
          d.year,
          d.month,
          d.day + oldDays,
          h2,
          int.parse(range[4]!),
        );
        if (!e.isAfter(s)) {
          e = DateTime(e.year, e.month, e.day + 1, e.hour, e.minute);
        }
        body = body.replaceFirst(range[0]!, '');
      } else if (old != null && old.allDay) {
        final length = DateTime.utc(old.end.year, old.end.month, old.end.day)
            .difference(
              DateTime.utc(old.start.year, old.start.month, old.start.day),
            )
            .inDays;
        e = DateTime(d.year, d.month, d.day + max(1, length));
      }
      var priority = old?.priority ?? 1;
      for (var n = 0; n < 3; n++) {
        if (body.contains(['🔽', '🔼', '⏫'][n])) {
          priority = n;
          body = body.replaceAll(['🔽', '🔼', '⏫'][n], '');
        }
      }
      final title = body.trim();
      if (title.isEmpty) {
        throw const FormatException('Пустое название в Markdown');
      }
      var item =
          (old ??
                  PlanItem(
                    id: newId(),
                    title: title,
                    start: s,
                    end: e,
                    reminders: const [],
                  ))
              .copy(
                title: title,
                start: s,
                end: e,
                allDay: range == null,
                priority: priority,
              );
      final completed = [...item.completed]..remove('all');
      if (match[1]!.toLowerCase() == 'x') {
        if (item.repeat == 'none') {
          completed.add('all');
        } else {
          completed.add(dateKey(visibleDate));
        }
      }
      item = item.copy(completed: completed.toSet().toList());
      if (!ids.add(item.id)) {
        throw const FormatException('Дублирующийся идентификатор в Markdown');
      }
      result.add(item);
    }
    return result;
  }
}

class MergeResult {
  final List<PlanItem> items;
  final int conflicts;
  MergeResult(this.items, this.conflicts);
}

/// Three-way merge: independent edits combine; divergent edits keep both copies.
MergeResult mergeItems(
  List<PlanItem> base,
  List<PlanItem> local,
  List<PlanItem> remote,
) {
  final b = {for (final i in base) i.id: i},
      l = {for (final i in local) i.id: i},
      r = {for (final i in remote) i.id: i};
  final out = <PlanItem>[];
  var conflicts = 0;
  String? sig(PlanItem? i) => i == null ? null : jsonEncode(i.toJson());
  for (final id in {...b.keys, ...l.keys, ...r.keys}) {
    final bi = b[id], li = l[id], ri = r[id];
    if (sig(li) == sig(ri)) {
      if (li != null) out.add(li);
    } else if (sig(li) == sig(bi)) {
      if (ri != null) out.add(ri);
    } else if (sig(ri) == sig(bi)) {
      if (li != null) out.add(li);
    } else {
      conflicts++;
      if (li != null) out.add(li);
      if (ri != null) {
        out.add(
          li == null
              ? ri
              : ri.copy(id: newId(), title: '${ri.title} (копия из Obsidian)'),
        );
      }
    }
  }
  return MergeResult(out, conflicts);
}
