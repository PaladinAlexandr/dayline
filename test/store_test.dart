import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dayline/store.dart';
import 'package:dayline/model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Connected vault preserves creates, edits, completion and deletion across reload',
    () async {
      String? disk;
      String? markdown;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PlannerStore.channel, (call) async {
            switch (call.method) {
              case 'load':
                return disk;
              case 'status':
                return {'vault': true};
              case 'launch':
                return {};
              case 'listVaultFolders':
                return ['Личное', 'Проекты', 'Проекты/Dayline'];
              case 'readVault':
                return markdown;
              case 'writeVault':
                final args = call.arguments as Map;
                expect(args['expected'], markdown ?? '');
                markdown = args['content'] as String;
                return null;
              case 'save':
                disk = call.arguments as String;
                return null;
            }
            return null;
          });
      final store = PlannerStore();
      await store.initialize();
      expect(identical(store.items, store.syncBase), false);
      expect(store.vaultFolders, contains('Проекты/Dayline'));
      final task = PlanItem(
        id: 'connected-task',
        title: 'Сегодня',
        start: DateTime(2026, 9, 23, 20),
        end: DateTime(2026, 9, 23, 21),
        category: 'Проекты/Dayline',
      );
      expect(await store.save(task), true);
      expect(store.items.map((i) => i.id), contains(task.id));
      expect(MarkdownCodec.decode(markdown!).single.title, task.title);
      final event = task.copy(
        id: 'connected-event',
        title: 'Завтра',
        task: false,
        start: DateTime(2026, 9, 24, 10),
        end: DateTime(2026, 9, 24, 11),
      );
      expect(await store.save(event), true);
      expect(MarkdownCodec.decode(markdown!), hasLength(2));
      expect(await store.save(task.copy(title: 'Исправлено')), true);
      expect(MarkdownCodec.decode(markdown!).first.title, 'Исправлено');
      await store.toggle(store.items.first.occurrence(task.start)!);
      expect(MarkdownCodec.decode(markdown!).first.completed, contains('all'));
      await store.delete(event.id);
      expect(MarkdownCodec.decode(markdown!), hasLength(1));
      await store.sync();
      store.dispose();
      final reloaded = PlannerStore();
      await reloaded.initialize();
      expect(reloaded.items.single.title, 'Исправлено');
      expect(reloaded.items.single.category, 'Проекты/Dayline');
      expect(reloaded.items.single.completed, contains('all'));
      reloaded.dispose();
    },
  );
  test(
    'Sync imports remote edit, persists base, is idempotent and protects missing file',
    () async {
      final item = PlanItem(
        id: 'a',
        title: 'Первая версия',
        start: DateTime(2026, 9, 23, 9),
        end: DateTime(2026, 9, 23, 10),
      );
      var disk = jsonEncode({
        'items': [item.toJson()],
        'syncBase': [item.toJson()],
      });
      String? markdown = MarkdownCodec.encode([
        item,
      ]).replaceFirst('Первая версия', 'Из Obsidian');
      var saves = 0, writes = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PlannerStore.channel, (call) async {
            switch (call.method) {
              case 'load':
                return disk;
              case 'status':
                return {'vault': true, 'notifications': true, 'exact': true};
              case 'launch':
                return {};
              case 'readVault':
                return markdown;
              case 'writeVault':
                final args = call.arguments as Map;
                if (args['expected'] != (markdown ?? '')) {
                  throw PlatformException(code: 'CONFLICT');
                }
                markdown = args['content'] as String;
                writes++;
                return null;
              case 'save':
                disk = call.arguments as String;
                saves++;
                return null;
            }
            return null;
          });
      final store = PlannerStore();
      await store.initialize();
      expect(store.items.single.title, 'Из Obsidian');
      expect(saves, 1);
      await store.sync();
      expect(saves, 1);
      final before = writes;
      markdown = null;
      await store.sync();
      expect(writes, before);
      expect(store.items.single.title, 'Из Obsidian');
      expect(store.error, contains('исчез'));
      store.dispose();
    },
  );
  test(
    'Folder refresh excludes service directories and keeps cache on error',
    () async {
      var failing = false;
      var folders = [
        'Проекты',
        '.obsidian',
        'Обучение/Теория',
        'Проекты',
        'Личное/.trash',
      ];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PlannerStore.channel, (call) async {
            switch (call.method) {
              case 'status':
                return {'vault': true};
              case 'listVaultFolders':
                if (failing) {
                  throw PlatformException(
                    code: 'FOLDERS',
                    message: 'Нет доступа',
                  );
                }
                return folders;
              default:
                return null;
            }
          });
      final store = PlannerStore();
      await store.refreshPermissions();
      await store.refreshFolders();
      expect(store.vaultFolders, ['Обучение/Теория', 'Проекты']);
      folders = ['Учеба'];
      await store.refreshFolders();
      expect(store.vaultFolders, ['Учеба']);
      failing = true;
      await store.refreshFolders();
      expect(store.vaultFolders, ['Учеба']);
      expect(store.folderError, contains('Нет доступа'));
      await store.disconnect();
      expect(store.vaultFolders, isEmpty);
      store.dispose();
    },
  );
  test('A failed vault write leaves local edits intact', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlannerStore.channel, (call) async {
          switch (call.method) {
            case 'status':
              return {'vault': true};
            case 'load':
              return null;
            case 'launch':
              return {};
            case 'readVault':
              return '';
            case 'writeVault':
              throw PlatformException(code: 'WRITE', message: 'Read only');
            default:
              return null;
          }
        });
    final store = PlannerStore();
    await store.initialize();
    final item = PlanItem(
      id: 'b',
      title: 'Сохрани меня',
      start: DateTime(2026, 9, 23, 9),
      end: DateTime(2026, 9, 23, 10),
    );
    final saved = await store.save(item);
    expect(saved, true);
    expect(store.items.single.id, 'b');
    expect(store.error, contains('Read only'));
    store.dispose();
  });
}
