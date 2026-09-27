import 'dart:convert';
import 'dart:io';
import 'model.dart';

/// The Windows adapter uses the same Dayline.md format as Android.
class DesktopFiles {
  final Directory dataDir;
  String? vaultPath;
  DesktopFiles(this.dataDir);
  File dataFile(String name) =>
      File('${dataDir.path}${Platform.pathSeparator}$name');
  Future<void> initialize() async {
    await dataDir.create(recursive: true);
    final config = dataFile('settings.json');
    if (await config.exists()) {
      vaultPath =
          (jsonDecode(await config.readAsString()) as Map)['vault'] as String?;
    }
  }

  static Future<void> atomicWrite(File file, String value) async {
    final pending = File('${file.path}.${newId()}.tmp');
    try {
      await pending.writeAsString(value, flush: true);
      await pending.rename(file.path);
    } finally {
      if (await pending.exists()) await pending.delete();
    }
  }

  Future<void> connect(String? path) async {
    if (path != null && !await Directory(path).exists()) {
      throw const FileSystemException('Выбранная папка не существует');
    }
    await atomicWrite(dataFile('settings.json'), jsonEncode({'vault': path}));
    vaultPath = path;
  }

  Future<Directory> vault() async {
    final path = vaultPath;
    if (path == null) {
      throw const FileSystemException('Папка Obsidian не подключена');
    }
    final directory = Directory(path);
    if (!await directory.exists()) {
      throw const FileSystemException('Папка Obsidian недоступна');
    }
    return directory;
  }

  Future<File> vaultFile() async =>
      File('${(await vault()).path}${Platform.pathSeparator}Dayline.md');
  Future<String?> readVault() async {
    final file = await vaultFile();
    if (!await file.exists()) return null;
    if (await file.length() > 2 * 1024 * 1024) {
      throw const FormatException('Dayline.md больше 2 МБ');
    }
    return file.readAsString();
  }

  Future<void> writeVault(String expected, String value) async {
    final file = await vaultFile();
    if ((await readVault() ?? '') != expected) {
      throw const FileSystemException(
        'Файл изменился в Obsidian. Повторите синхронизацию.',
      );
    }
    if (value == expected) return;
    await atomicWrite(dataFile('Dayline-before-sync.md'), expected);
    // Stage the complete contents before replacing the shared file.
    final pending = File('${file.path}.${newId()}.tmp');
    try {
      await pending.writeAsString(value, flush: true);
      if ((await readVault() ?? '') != expected) {
        throw const FileSystemException(
          'Файл изменился в Obsidian. Повторите синхронизацию.',
        );
      }
      await pending.rename(file.path);
    } finally {
      if (await pending.exists()) await pending.delete();
    }
  }

  Future<List<String>> folders() async {
    final root = await vault();
    final found = <String>[];
    Future<void> visit(Directory folder, String prefix) async {
      await for (final child in folder.list(followLinks: false)) {
        if (child is! Directory) continue;
        // Skip junctions as well as links, to stay inside the selected vault.
        if (await FileSystemEntity.isLink(child.path)) continue;
        final name = child.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last;
        if (name.startsWith('.')) continue;
        final relative = prefix.isEmpty ? name : '$prefix/$name';
        found.add(relative);
        if (found.length > 10000) {
          throw const FileSystemException('В хранилище больше 10 000 папок');
        }
        await visit(child, relative);
      }
    }

    await visit(root, '');
    return found..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }
}

class DesktopReminder {
  final PlanItem item;
  final DateTime when;
  final String key;
  DesktopReminder(this.item, this.when, this.key);
}

List<DesktopReminder> dueReminders(
  List<PlanItem> items,
  DateTime from,
  DateTime now,
  Set<String> sent,
) {
  final due = <DesktopReminder>[];
  for (final item in items) {
    for (final offset in item.reminders) {
      final shiftedFrom = from.add(Duration(minutes: offset));
      final shiftedTo = now.add(Duration(minutes: offset));
      for (
        var day = dayOnly(shiftedFrom);
        !day.isAfter(dayOnly(shiftedTo));
        day = DateTime(day.year, day.month, day.day + 1)
      ) {
        final o = item.occurrence(day);
        if (o == null || o.done) continue;
        final reference = item.allDay
            ? DateTime(day.year, day.month, day.day, 9)
            : o.start;
        final when = reference.subtract(Duration(minutes: offset));
        final key = '${item.id}|${o.key}|$offset|${when.toIso8601String()}';
        if (when.isAfter(from) && !when.isAfter(now) && !sent.contains(key)) {
          due.add(DesktopReminder(item, when, key));
        }
      }
    }
  }
  return due..sort((a, b) => a.when.compareTo(b.when));
}
