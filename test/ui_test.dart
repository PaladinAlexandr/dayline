import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dayline/main.dart';
import 'package:dayline/store.dart';
import 'package:dayline/model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String data;
  bool connected = false;
  String? markdown;
  setUp(() {
    connected = false;
    markdown = null;
    data = jsonEncode({'items': [], 'syncBase': []});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlannerStore.channel, (call) async {
          switch (call.method) {
            case 'load':
              return data;
            case 'save':
              data = call.arguments as String;
              return null;
            case 'status':
              return {'vault': connected, 'notifications': true, 'exact': true};
            case 'listVaultFolders':
              return ['Личное', 'Проекты', 'Обучение/Теория'];
            case 'readVault':
              return markdown;
            case 'writeVault':
              markdown = (call.arguments as Map)['content'] as String;
              return null;
            case 'launch':
              return {};
            default:
              return null;
          }
        });
  });
  testWidgets(
    'Connected app selects a vault folder and displays task after restart',
    (tester) async {
      connected = true;
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = PlannerStore();
      await tester.pumpWidget(DaylineApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Создать'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).first,
        'Сохранение с Obsidian',
      );
      final category = find.widgetWithText(
        TextFormField,
        'Категория — папка Obsidian',
      );
      await tester.ensureVisible(category);
      await tester.pumpAndSettle();
      await tester.tap(category);
      await tester.pumpAndSettle();
      expect(find.text('Папки Obsidian'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Найти папку'),
        'теория',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Обучение/Теория'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(find.text('Сохранение с Obsidian'), findsWidgets);
      expect(store.items.single.category, 'Обучение/Теория');
      expect(MarkdownCodec.decode(markdown!).single.category, 'Обучение/Теория');
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      final nextStore = PlannerStore();
      await tester.pumpWidget(DaylineApp(store: nextStore));
      await tester.pumpAndSettle();
      expect(find.text('Сохранение с Obsidian'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      nextStore.dispose();
    },
  );
  testWidgets('Create timed task, persist, complete it and open settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = PlannerStore();
    await tester.pumpWidget(DaylineApp(store: store));
    await tester.pumpAndSettle();
    expect(find.text('Место для ваших планов'), findsOneWidget);
    await tester.tap(find.text('Создать'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).first,
      'Встреча по проекту',
    );
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(store.items.single.title, 'Встреча по проекту');
    expect(store.items.single.end.isAfter(store.items.single.start), true);
    expect(jsonDecode(data)['items'], hasLength(1));
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(store.items.single.completed, contains('all'));
    await tester.tap(find.text('Настройки'));
    await tester.pumpAndSettle();
    expect(find.text('Obsidian'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
  });
  testWidgets('Month and editor render on narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    final originalHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      FlutterError.dumpErrorToConsole(details, forceReport: true);
      originalHandler?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalHandler);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = PlannerStore();
    await tester.pumpWidget(DaylineApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Месяц'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Создать'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
  });
  testWidgets('All day editing preserves inclusive end date', (tester) async {
    final start = DateTime(2026, 9, 23);
    final end = DateTime(2026, 9, 24);
    final item = PlanItem(
      id: 'a',
      title: 'Весь день',
      start: start,
      end: end,
      allDay: true,
    );
    data = jsonEncode({
      'items': [item.toJson()],
      'syncBase': [],
    });
    final store = PlannerStore();
    await tester.pumpWidget(DaylineApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Задачи'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Весь день').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(store.items.single.end, end);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
  });
}
