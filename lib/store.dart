import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'model.dart';
import 'platform_backend.dart';
import 'windows_backend.dart';

class PlannerStore extends ChangeNotifier {
  static const channel = ChannelBackend.channel;
  final PlannerBackend backend;
  PlannerStore({PlannerBackend? backend})
    : backend =
          backend ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows
              ? WindowsBackend()
              : ChannelBackend());
  bool get isDesktop => backend.isDesktop;
  List<PlanItem> items = [];
  List<PlanItem> syncBase = [];
  List<String> vaultFolders = [];
  String folderError = '';
  bool loadingFolders = false;
  bool ready = false, busy = false, connected = false, dark = true;
  bool editing = false;
  String syncStatus = 'Папка Obsidian не подключена', error = '';
  Map<String, dynamic> permissions = {};
  String? launchId;
  bool launchNew = false;
  Timer? _timer;
  Future<void> initialize() async {
    backend.setHandler((call) async {
      if (call.method == 'desktopWidgetChanged') {
        await refreshPermissions();
      }
      if (call.method == 'backgroundError') {
        error = call.arguments.toString();
        notifyListeners();
      }
      if (call.method == 'open') {
        launchId = call.arguments as String?;
        notifyListeners();
      }
      if (call.method == 'new') {
        launchNew = true;
        notifyListeners();
      }
    });
    try {
      final raw = await backend.invoke('load') as String?;
      if (raw != null && raw.isNotEmpty) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        items = (j['items'] as List)
            .map((e) => PlanItem.fromJson(e as Map<String, dynamic>))
            .toList();
        syncBase = (j['syncBase'] as List? ?? [])
            .map((e) => PlanItem.fromJson(e as Map<String, dynamic>))
            .toList();
        dark = j['dark'] as bool? ?? true;
        vaultFolders = (j['vaultFolders'] as List? ?? []).cast<String>();
      }
      await refreshPermissions();
      final launch = await backend.invoke('launch') as Map?;
      launchId = launch?['id'] as String?;
      launchNew = launch?['new'] == true;
    } on MissingPluginException {
      /* Allows Flutter web preview and widget tests. */
    } catch (e) {
      error = 'Не удалось прочитать данные: $e';
    }
    ready = true;
    notifyListeners();
    await sync();
    await refreshFolders();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => sync());
  }

  Future<void> refreshPermissions() async {
    permissions = Map<String, dynamic>.from(
      await backend.invoke('status') as Map? ?? {},
    );
    connected = permissions['vault'] == true;
    notifyListeners();
  }

  Future<void> persist() async {
    final data = jsonEncode({
      'version': 1,
      'items': items.map((i) => i.toJson()).toList(),
      'syncBase': syncBase.map((i) => i.toJson()).toList(),
      'dark': dark,
      'vaultFolders': vaultFolders,
    });
    await backend.invoke('save', data);
  }

  Future<bool> save(PlanItem item) async => _edit(() {
    final index = items.indexWhere((i) => i.id == item.id);
    if (index < 0) {
      items.add(item);
    } else {
      items[index] = item;
    }
  });
  Future<bool> delete(String id) async =>
      _edit(() => items.removeWhere((i) => i.id == id));
  Future<bool> toggle(Occurrence o) async {
    final current = items.firstWhere(
      (i) => i.id == o.item.id,
      orElse: () => o.item,
    );
    final key = current.repeat == 'none' ? 'all' : o.key;
    final done = [...current.completed];
    if (done.contains(key)) {
      done.remove(key);
    } else {
      done.add(key);
    }
    return save(current.copy(completed: done));
  }

  Future<bool> _edit(void Function() edit) async {
    if (busy) return false;
    final before = [...items];
    busy = true;
    error = '';
    try {
      // Never let an edit mutate the three-way sync baseline.
      items = [...items];
      edit();
      await persist();
    } catch (e) {
      items = before;
      error = 'Не удалось сохранить: $e';
      busy = false;
      notifyListeners();
      return false;
    }
    busy = false;
    notifyListeners();
    await sync(force: true);
    return true;
  }

  Future<void> setDark(bool value) async {
    dark = value;
    await persist();
    notifyListeners();
  }

  Future<void> connect() async {
    if (busy) return;
    try {
      final changed = await backend.invoke('connectVault') as bool? ?? false;
      if (changed) {
        syncBase = [];
        vaultFolders = [];
        await persist();
      }
      await refreshPermissions();
      await sync();
      await refreshFolders();
    } catch (e) {
      error = 'Папка недоступна: $e';
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    if (busy) return;
    await backend.invoke('disconnectVault');
    syncBase = [];
    vaultFolders = [];
    folderError = '';
    await persist();
    await refreshPermissions();
    syncStatus = 'Папка Obsidian не подключена';
    notifyListeners();
  }

  Future<void> sync({bool force = false}) async {
    if (!connected || busy || (editing && !force)) return;
    busy = true;
    notifyListeners();
    try {
      final received = await backend.invoke('readVault') as String?;
      if (received == null && syncBase.isNotEmpty) {
        throw const FormatException(
          'Dayline.md исчез из папки. Восстановите файл или переподключите папку. Локальные записи сохранены.',
        );
      }
      final content = received ?? '';
      final remote = MarkdownCodec.decode(content);
      final merged = mergeItems(syncBase, items, remote);
      final output = MarkdownCodec.encode(merged.items, previous: content);
      await backend.invoke('writeVault', {
        'expected': content,
        'content': output,
      });
      // Store the normalized roundtrip as baseline (same precision as Markdown).
      final normalized = MarkdownCodec.decode(output);
      final changed =
          jsonEncode(items.map((i) => i.toJson()).toList()) !=
              jsonEncode(normalized.map((i) => i.toJson()).toList()) ||
          jsonEncode(syncBase.map((i) => i.toJson()).toList()) !=
              jsonEncode(normalized.map((i) => i.toJson()).toList());
      items = [...normalized];
      syncBase = List.unmodifiable(normalized);
      if (changed) await persist();
      syncStatus = merged.conflicts > 0
          ? 'Конфликт: сохранены обе версии (${merged.conflicts})'
          : 'Обновлено в ${clockText(DateTime.now())} · Dayline.md';
      error = '';
    } catch (e) {
      syncStatus = 'Синхронизация приостановлена';
      error = 'Obsidian: $e';
    }
    busy = false;
    notifyListeners();
  }

  Future<void> refreshFolders() async {
    if (!connected || loadingFolders) return;
    loadingFolders = true;
    folderError = '';
    notifyListeners();
    try {
      final folders = (await backend.invoke('listVaultFolders') as List? ?? [])
          .cast<String>();
      vaultFolders =
          folders
              .where(
                (path) =>
                    path.isNotEmpty &&
                    !path.split('/').any((part) => part.startsWith('.')),
              )
              .toSet()
              .toList()
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    } catch (e) {
      folderError = 'Не удалось обновить папки: $e';
    } finally {
      loadingFolders = false;
      notifyListeners();
    }
  }

  Future<void> action(String method) async {
    try {
      await backend.invoke(method);
      await refreshPermissions();
    } catch (e) {
      error = 'Не удалось выполнить действие: $e';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    backend.dispose();
    super.dispose();
  }
}
