import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dayline/desktop_files.dart';
import 'package:dayline/desktop_widget.dart';
import 'package:dayline/windows_backend.dart';
import 'package:dayline/platform_backend.dart';
import 'package:dayline/store.dart';
import 'package:dayline/main.dart';
import 'package:dayline/model.dart';

class DesktopMock extends ChannelBackend {
  @override
  bool get isDesktop => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('dayline-windows-test-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'Windows folder scan preserves unicode nesting and skips hidden directories',
    () async {
      final vault = Directory('${root.path}/Хранилище');
      for (final name in [
        'Проекты/Разработка',
        'Личное',
        '.obsidian/plugins',
        '.trash/old',
      ]) {
        await Directory('${vault.path}/$name').create(recursive: true);
      }
      final files = DesktopFiles(Directory('${root.path}/data'));
      await files.initialize();
      await files.connect(vault.path);
      expect(await files.folders(), [
        'Личное',
        'Проекты',
        'Проекты/Разработка',
      ]);
      final reloaded = DesktopFiles(files.dataDir);
      await reloaded.initialize();
      expect(reloaded.vaultPath, vault.path);
    },
  );

  test(
    'Vault atomic replace detects concurrent edit, backs up and handles disappearance',
    () async {
      final vault = await Directory('${root.path}/vault').create();
      final files = DesktopFiles(Directory('${root.path}/data'));
      await files.initialize();
      await files.connect(vault.path);
      expect(await files.readVault(), isNull);
      await files.writeVault('', 'Первая версия');
      expect(await files.readVault(), 'Первая версия');
      await (await files.vaultFile()).writeAsString('Правка извне');
      await expectLater(
        files.writeVault('Первая версия', 'Устаревшая запись'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await files.readVault(), 'Правка извне');
      await files.writeVault('Правка извне', 'Новая версия');
      expect(
        await files.dataFile('Dayline-before-sync.md').readAsString(),
        'Правка извне',
      );
      expect(await files.readVault(), 'Новая версия');
      expect(await vault.list().length, 1);
      await vault.delete(recursive: true);
      await expectLater(files.readVault(), throwsA(isA<FileSystemException>()));
    },
  );

  test(
    'Windows store syncs Android Markdown through real files and survives restart',
    () async {
      final vault = await Directory('${root.path}/Общий vault').create();
      await Directory('${vault.path}/Проекты').create();
      final item = PlanItem(
        id: 'android-id',
        title: 'С телефона',
        start: DateTime(2026, 10, 1, 9),
        end: DateTime(2026, 10, 1, 10),
        category: 'Проекты',
      );
      final md = File('${vault.path}/Dayline.md');
      await md.writeAsString(MarkdownCodec.encode([item]));
      final data = Directory('${root.path}/data');
      WindowsBackend backend() => WindowsBackend(
        dataDir: data,
        startTimer: false,
        nativeCall: (method, args) async =>
            method == 'selectFolder' ? vault.path : null,
      );
      final store = PlannerStore(backend: backend());
      await store.initialize();
      await store.connect();
      expect(store.items.single.id, 'android-id');
      expect(store.vaultFolders, ['Проекты']);
      await store.save(
        item.copy(id: 'windows-id', title: 'С компьютера', task: false),
      );
      expect(MarkdownCodec.decode(await md.readAsString()), hasLength(2));
      await md.writeAsString(
        (await md.readAsString()).replaceFirst(
          'С телефона',
          'Исправлено в Obsidian',
        ),
      );
      await store.sync();
      expect(store.items.first.title, 'Исправлено в Obsidian');
      await store.toggle(store.items.first.occurrence(item.start)!);
      expect(
        MarkdownCodec.decode(await md.readAsString()).first.completed,
        contains('all'),
      );
      store.dispose();
      final next = PlannerStore(backend: backend());
      await next.initialize();
      expect(next.items, hasLength(2));
      expect(next.items.first.completed, contains('all'));
      await md.delete();
      await next.sync();
      expect(next.items, hasLength(2));
      expect(next.error, contains('исчез'));
      next.dispose();
    },
  );

  test(
    'Corrupt local desktop state cannot be overwritten with an empty calendar',
    () async {
      final data = await Directory('${root.path}/data').create();
      final file = File('${data.path}/planner.json');
      await file.writeAsString('broken');
      final backend = WindowsBackend(dataDir: data, startTimer: false);
      await expectLater(
        backend.invoke('load'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        backend.invoke('save', '{"items":[]}'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsString(), 'broken');
      backend.dispose();
    },
  );

  test(
    'Desktop reminders cover offsets, all-day, recurrence and completion without duplicates',
    () {
      final start = DateTime(2026, 10, 1, 9);
      final item = PlanItem(
        id: 'due',
        title: 'Дело',
        start: start,
        end: start.add(const Duration(hours: 1)),
        reminders: [10, 0],
      );
      final due = dueReminders(
        [item],
        DateTime(2026, 10, 1, 8, 49),
        DateTime(2026, 10, 1, 8, 50),
        {},
      );
      expect(due, hasLength(1));
      expect(
        dueReminders(
          [item],
          DateTime(2026, 10, 1, 8, 49),
          DateTime(2026, 10, 1, 8, 50),
          {due.single.key},
        ),
        isEmpty,
      );
      expect(
        dueReminders(
          [
            item.copy(completed: ['all']),
          ],
          DateTime(2026, 10, 1, 8, 49),
          start,
          {},
        ),
        isEmpty,
      );
      final allDay = item.copy(
        start: dayOnly(start),
        end: DateTime(2026, 10, 2),
        allDay: true,
        reminders: [0],
        repeat: 'daily',
      );
      expect(
        dueReminders(
          [allDay],
          DateTime(2026, 10, 2, 8, 59),
          DateTime(2026, 10, 2, 9),
          {},
        ),
        hasLength(1),
      );
    },
  );

  test(
    'Desktop widget filters finished and past entries, keeps overnight and repeats',
    () {
      final now = DateTime(2026, 10, 1, 12);
      PlanItem item(String id, DateTime start, DateTime end) =>
          PlanItem(id: id, title: id, start: start, end: end, reminders: []);
      final entries = desktopWidgetEntries([
        item('future', DateTime(2026, 10, 2, 10), DateTime(2026, 10, 2, 11)),
        item('past', DateTime(2026, 10, 1, 9), DateTime(2026, 10, 1, 10)),
        item('overnight', DateTime(2026, 9, 30, 22), DateTime(2026, 10, 1, 13)),
        item(
          'all-day',
          DateTime(2026, 10, 1),
          DateTime(2026, 10, 2),
        ).copy(allDay: true),
        item(
          'done',
          DateTime(2026, 10, 1, 13),
          DateTime(2026, 10, 1, 14),
        ).copy(completed: ['all']),
        item('far', DateTime(2026, 11, 5, 10), DateTime(2026, 11, 5, 11)),
        item(
          'repeat',
          DateTime(2026, 10, 1, 15),
          DateTime(2026, 10, 1, 16),
        ).copy(repeat: 'daily', completed: ['2026-10-01']),
      ], now);
      expect(entries.take(3).map((e) => e['id']), [
        'overnight',
        'all-day',
        'future',
      ]);
      expect(
        entries.where(
          (e) => e['id'] == 'past' || e['id'] == 'done' || e['id'] == 'far',
        ),
        isEmpty,
      );
      expect(
        entries.where((e) => e['id'] == 'repeat').first['detail'],
        startsWith('Завтра'),
      );
      expect(
        entries.firstWhere((e) => e['id'] == 'all-day')['detail'],
        'Сегодня · Весь день',
      );
      final many = List.generate(
        80,
        (i) => item(
          'task-$i',
          now.add(Duration(minutes: i)),
          now.add(Duration(minutes: i + 60)),
        ),
      );
      expect(desktopWidgetEntries(many, now), hasLength(50));
    },
  );

  test(
    'Desktop widget receives saved data, excludes completion and restores visibility',
    () async {
      final data = Directory('${root.path}/widget-data');
      final updates = <Map<String, Object?>>[];
      Future<Object?> native(String method, Object? args) async {
        if (method == 'updateWidget') {
          updates.add(Map<String, Object?>.from(args as Map));
        }
        return null;
      }

      final backend = WindowsBackend(
        dataDir: data,
        nativeCall: native,
        startTimer: false,
      );
      await backend.invoke('load');
      final now = DateTime.now();
      final item = PlanItem(
        id: 'widget-task',
        title: 'Для виджета',
        start: now.add(const Duration(hours: 1)),
        end: now.add(const Duration(hours: 2)),
      );
      await backend.invoke(
        'save',
        jsonEncode({
          'items': [item.toJson()],
        }),
      );
      expect((updates.last['entries'] as List).single['title'], 'Для виджета');
      await backend.invoke(
        'save',
        jsonEncode({
          'items': [
            item.copy(completed: ['all']).toJson(),
          ],
        }),
      );
      expect(updates.last['entries'], isEmpty);
      await backend.invoke('hideDesktopWidget');
      expect(updates.last['enabled'], false);
      backend.dispose();
      final reloaded = WindowsBackend(
        dataDir: data,
        nativeCall: native,
        startTimer: false,
      );
      await reloaded.invoke('load');
      expect(updates.last['enabled'], false);
      await reloaded.invoke('showDesktopWidget');
      expect((await reloaded.invoke('status') as Map)['widgetEnabled'], true);
      reloaded.dispose();
    },
  );

  testWidgets(
    'Desktop layout supports creation and hides Android-only settings',
    (tester) async {
      final reportError = FlutterError.onError;
      FlutterError.onError = (details) {
        debugPrint(details.toString());
        reportError?.call(details);
      };
      addTearDown(() => FlutterError.onError = reportError);
      tester.view.physicalSize = const Size(1180, 790);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? raw;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PlannerStore.channel, (call) async {
            switch (call.method) {
              case 'load':
                return raw;
              case 'save':
                raw = call.arguments as String;
                return null;
              case 'status':
                return {'vault': false};
              case 'launch':
                return {};
              default:
                return null;
            }
          });
      final store = PlannerStore(backend: DesktopMock());
      await tester.pumpWidget(DaylineApp(store: store));
      await tester.pumpAndSettle();
      expect(find.text('Ваш календарь'), findsOneWidget);
      await tester.tap(find.text('Создать'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).first,
        'Задача Windows',
      );
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(store.items.single.title, 'Задача Windows');
      expect(jsonDecode(raw!)['items'], hasLength(1));
      for (final size in [
        const Size(1000, 700),
        const Size(900, 650),
        const Size(760, 650),
        const Size(540, 600),
        const Size(1180, 790),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Window $size');
      }
      await tester.tap(find.text('Настройки'));
      await tester.pumpAndSettle();
      expect(find.text('Виджет ближайших дел'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
    },
  );
}
