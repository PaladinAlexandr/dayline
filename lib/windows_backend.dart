import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'desktop_files.dart';
import 'desktop_widget.dart';
import 'model.dart';
import 'platform_backend.dart';

class WindowsBackend extends PlannerBackend {
  static const channel = MethodChannel('app.dayline/windows');
  final DesktopFiles files;
  final Future<Object?> Function(String, Object?) native;
  final bool startTimer;
  List<PlanItem> _items = [];
  final Map<String, int> _sent = {};
  Timer? _timer, _testTimer;
  bool _loaded = false, _ticking = false, _disposed = false;
  DateTime _lastCheck = DateTime.now().subtract(const Duration(minutes: 1));
  Future<void> Function(MethodCall call)? _handler;
  Map<String, Object?> _widget = {'enabled': true, 'pinned': false};
  String? _lastWidgetPayload;
  WindowsBackend({
    Directory? dataDir,
    Future<Object?> Function(String, Object?)? nativeCall,
    this.startTimer = true,
  }) : files = DesktopFiles(
         dataDir ??
             Directory(
               Platform.environment['DAYLINE_DATA_DIR'] ??
                   '${Platform.environment['LOCALAPPDATA'] ?? Directory.current.path}${Platform.pathSeparator}Dayline',
             ),
       ),
       native =
           nativeCall ??
           ((method, args) => channel.invokeMethod<Object?>(method, args));

  @override
  bool get isDesktop => true;
  @override
  void setHandler(Future<void> Function(MethodCall call)? handler) {
    _handler = handler;
    channel.setMethodCallHandler(handler == null ? null : _handleNative);
  }

  Future<void> _handleNative(MethodCall call) async {
    if (call.method == 'widgetState') {
      _widget = Map<String, Object?>.from(call.arguments as Map);
      _lastWidgetPayload = null;
      try {
        await DesktopFiles.atomicWrite(
          files.dataFile('desktop-widget.json'),
          jsonEncode(_widget),
        );
      } catch (e) {
        await _handler?.call(MethodCall('backgroundError', 'Виджет: $e'));
      }
      await _handler?.call(const MethodCall('desktopWidgetChanged'));
      return;
    }
    await _handler?.call(call);
  }

  Future<void> refreshWidget({DateTime? at, bool reportFailure = false}) async {
    final now = at ?? DateTime.now();
    final payload = <String, Object?>{
      ..._widget,
      'entries': desktopWidgetEntries(_items, now),
      'date':
          '${now.day.toString().padLeft(2, '0')}.${now.month.toString().padLeft(2, '0')}.${now.year}',
    };
    final encoded = jsonEncode(payload);
    if (encoded == _lastWidgetPayload) return;
    try {
      await native('updateWidget', payload);
      _lastWidgetPayload = encoded;
    } catch (e) {
      if (reportFailure) rethrow;
      await _handler?.call(MethodCall('backgroundError', 'Виджет: $e'));
    }
  }

  @override
  Future<Object?> invoke(String method, [Object? arguments]) async {
    switch (method) {
      case 'load':
        await files.initialize();
        final widgetFile = files.dataFile('desktop-widget.json');
        if (await widgetFile.exists()) {
          try {
            _widget.addAll(
              Map<String, Object?>.from(
                jsonDecode(await widgetFile.readAsString()) as Map,
              ),
            );
          } catch (_) {
            /* Restore defaults if window preferences are damaged. */
          }
        }
        final file = files.dataFile('planner.json');
        final raw = await file.exists() ? await file.readAsString() : null;
        if (raw != null) {
          final j = jsonDecode(raw) as Map;
          _items = (j['items'] as List)
              .map(
                (i) => PlanItem.fromJson(Map<String, dynamic>.from(i as Map)),
              )
              .toList();
        }
        final sentFile = files.dataFile('reminders.json');
        if (await sentFile.exists()) {
          try {
            _sent.addAll(
              (jsonDecode(await sentFile.readAsString()) as Map)
                  .cast<String, int>(),
            );
          } catch (_) {
            /* A damaged reminder log must not hide the calendar. */
          }
        }
        _loaded = true;
        await refreshWidget();
        if (startTimer) {
          _timer ??= Timer.periodic(const Duration(seconds: 15), (_) => tick());
        }
        return raw;
      case 'save':
        if (!_loaded) {
          throw const FileSystemException(
            'Данные не загружены. Исправьте ошибку чтения перед сохранением.',
          );
        }
        final raw = arguments as String;
        final j = jsonDecode(raw) as Map;
        final items = (j['items'] as List)
            .map((i) => PlanItem.fromJson(Map<String, dynamic>.from(i as Map)))
            .toList();
        final file = files.dataFile('planner.json');
        if (await file.exists()) {
          await DesktopFiles.atomicWrite(
            files.dataFile('planner.previous.json'),
            await file.readAsString(),
          );
        }
        await DesktopFiles.atomicWrite(file, raw);
        _items = items;
        await refreshWidget();
        return null;
      case 'status':
        return {
          'vault': files.vaultPath != null,
          'vaultPath': files.vaultPath,
          'dataPath': files.dataDir.path,
          'desktop': true,
          'widgetEnabled': _widget['enabled'] == true,
          'widgetPinned': _widget['pinned'] == true,
        };
      case 'showDesktopWidget':
      case 'hideDesktopWidget':
        _widget['enabled'] = method == 'showDesktopWidget';
        await refreshWidget(reportFailure: true);
        await DesktopFiles.atomicWrite(
          files.dataFile('desktop-widget.json'),
          jsonEncode(_widget),
        );
        return null;
      case 'launch':
        return <String, Object?>{};
      case 'connectVault':
        final selected = await native('selectFolder', files.vaultPath);
        if (selected == null) return false;
        await files.connect(selected as String);
        return true;
      case 'disconnectVault':
        await files.connect(null);
        return null;
      case 'listVaultFolders':
        return files.folders();
      case 'readVault':
        return files.readVault();
      case 'writeVault':
        final args = arguments as Map;
        await files.writeVault(
          args['expected'] as String,
          args['content'] as String,
        );
        return null;
      case 'testNotification':
        _testTimer?.cancel();
        _testTimer = Timer(const Duration(seconds: 10), () async {
          try {
            await native('notify', {
              'title': 'Dayline работает',
              'body':
                  'Напоминания работают, пока приложение открыто или находится в трее.',
            });
          } catch (e) {
            await _handler?.call(
              MethodCall('backgroundError', 'Уведомление: $e'),
            );
          }
        });
        return null;
      case 'openVault':
        await native('openFolder', files.vaultPath);
        return null;
      case 'hideWindow':
      case 'exitApp':
        return native(method, null);
      default:
        throw MissingPluginException('Неизвестное действие: $method');
    }
  }

  Future<void> tick({DateTime? at}) async {
    if (!_loaded || _disposed || _ticking) return;
    _ticking = true;
    try {
      final now = at ?? DateTime.now();
      await refreshWidget(at: now);
      final oldest = now.subtract(const Duration(days: 1));
      final from = _lastCheck.isBefore(oldest) ? oldest : _lastCheck;
      final due = dueReminders(_items, from, now, _sent.keys.toSet());
      for (final reminder in due) {
        if (_disposed) break;
        await native('notify', {
          'title': reminder.item.title,
          'body':
              '${clockText(reminder.item.start)} · ${reminder.item.category}',
          'id': reminder.item.id,
        });
        _sent[reminder.key] = now.millisecondsSinceEpoch;
      }
      _lastCheck = now;
      _sent.removeWhere(
        (_, time) =>
            time <
            now.subtract(const Duration(days: 32)).millisecondsSinceEpoch,
      );
      if (due.isNotEmpty) {
        await DesktopFiles.atomicWrite(
          files.dataFile('reminders.json'),
          jsonEncode(_sent),
        );
      }
    } catch (e) {
      await _handler?.call(MethodCall('backgroundError', 'Напоминания: $e'));
    } finally {
      _ticking = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _testTimer?.cancel();
    channel.setMethodCallHandler(null);
  }
}
