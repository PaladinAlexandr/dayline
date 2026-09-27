import 'package:flutter_test/flutter_test.dart';
import 'package:dayline/model.dart';

void main() {
  PlanItem item({String repeat = 'none'}) => PlanItem(
    id: 'a',
    title: 'План проекта',
    start: DateTime(2026, 1, 31, 23),
    end: DateTime(2026, 2, 1, 1),
    repeat: repeat,
    note: 'Строка 1\nСтрока 2',
    reminders: [0, 10, 60],
  );
  test('Monthly recurrence clamps to February and returns to 31st', () {
    final i = item(repeat: 'monthly');
    expect(i.occursOn(DateTime(2026, 2, 28)), true);
    expect(i.occursOn(DateTime(2026, 3, 31)), true);
    expect(i.occursOn(DateTime(2026, 3, 28)), false);
  });
  test(
    'Overnight events appear on both days without touching following boundary',
    () {
      final i = item();
      expect(
        i.between(DateTime(2026, 2, 1), DateTime(2026, 2, 2)),
        hasLength(1),
      );
      expect(i.between(DateTime(2026, 2, 1, 1), DateTime(2026, 2, 2)), isEmpty);
    },
  );
  test('Weekdays do not include weekends or dates before start', () {
    final i = item(repeat: 'weekdays');
    expect(i.occursOn(DateTime(2026, 2, 2)), true);
    expect(i.occursOn(DateTime(2026, 2, 1)), false);
    expect(i.occursOn(DateTime(2026, 1, 30)), false);
  });
  test('Rich Markdown roundtrip is lossless including overnight range', () {
    final i = item();
    final decoded = MarkdownCodec.decode(MarkdownCodec.encode([i]));
    expect(decoded.single.toJson(), i.toJson());
  });
  test('Obsidian title, date and completion edits override metadata', () {
    final text = MarkdownCodec.encode([item()])
        .replaceFirst('План проекта', 'Новая задача')
        .replaceFirst('📅 2026-01-31', '📅 2026-02-03')
        .replaceFirst(RegExp(r'^- \[ \]', multiLine: true), '- [x]');
    final i = MarkdownCodec.decode(text).single;
    expect(i.title, 'Новая задача');
    expect(i.start, DateTime(2026, 2, 3, 23));
    expect(i.end, DateTime(2026, 2, 4, 1));
    expect(i.completed, ['all']);
  });
  test('New Markdown task is imported, no unsolicited reminder', () {
    final i = MarkdownCodec.decode('- [ ] Написать текст 📅 2026-10-02').single;
    expect(i.allDay, true);
    expect(i.reminders, isEmpty);
    expect(i.end, DateTime(2026, 10, 3));
  });
  test(
    'Bad dates and malformed metadata fail without silently deleting tasks',
    () {
      expect(
        () => MarkdownCodec.decode('- [ ] X 📅 2026-02-31'),
        throwsFormatException,
      );
      expect(
        () =>
            MarkdownCodec.decode('- [ ] X 📅 2026-02-02 <!-- dayline:bad -->'),
        throwsFormatException,
      );
    },
  );
  test('Conflicting edits preserve both copies', () {
    final i = item();
    final m = mergeItems([i], [i.copy(title: 'Локально')], [
      i.copy(title: 'Удалённо'),
    ]);
    expect(m.conflicts, 1);
    expect(m.items, hasLength(2));
    expect(m.items.map((i) => i.id).toSet(), hasLength(2));
  });
  test('Independent deletion and edit merge', () {
    final i = item();
    final j = i.copy(id: 'b');
    final m = mergeItems([i, j], [i.copy(title: 'Изменено'), j], [i]);
    expect(m.conflicts, 0);
    expect(m.items, hasLength(1));
    expect(m.items.single.title, 'Изменено');
  });
  test('Delete versus edit preserves modified item', () {
    final i = item();
    final m = mergeItems([i], [], [i.copy(title: 'Важное изменение')]);
    expect(m.conflicts, 1);
    expect(m.items.single.title, 'Важное изменение');
  });
  test('Recurring completion only marks that occurrence', () {
    final i = item(repeat: 'daily').copy(completed: ['2026-02-01']);
    expect(i.occurrence(DateTime(2026, 2, 1))!.done, true);
    expect(i.occurrence(DateTime(2026, 2, 2))!.done, false);
  });
  test(
    'Recurring Markdown roundtrip keeps original series and completes displayed occurrence',
    () {
      final i = item(repeat: 'daily');
      final encoded = MarkdownCodec.encode([i]);
      expect(MarkdownCodec.decode(encoded).single.toJson(), i.toJson());
      final checked = encoded.replaceFirst(
        RegExp(r'^- \[ \]', multiLine: true),
        '- [x]',
      );
      final completed = MarkdownCodec.decode(checked).single;
      expect(completed.start, i.start);
      expect(completed.completed, contains(dateKey(DateTime.now())));
      final next = MarkdownCodec.encode([completed]);
      final tomorrow = DateTime.now();
      expect(
        next,
        contains(
          '📅 ${dateKey(DateTime(tomorrow.year, tomorrow.month, tomorrow.day + 1))}',
        ),
      );
    },
  );
  test('User prose in shared file is retained', () {
    final text = MarkdownCodec.encode(
      [item()],
      previous:
          '# Мои планы\n\nВажная заметка\n- [ ] Старая задача 📅 2026-01-01\n',
    );
    expect(text, contains('Важная заметка'));
    expect(text, contains('# Мои планы'));
    expect(text, isNot(contains('Старая задача')));
  });
}
