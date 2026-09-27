import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dayline/main.dart';
import 'package:dayline/model.dart';
import 'package:dayline/store.dart';

void main() {
  testWidgets('Render Pixel-sized preview and verify populated layout', (
    tester,
  ) async {
    final fonts = Platform.environment['FLUTTER_ROOT'];
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    if (fonts != null) {
      final file = File(
        '$fonts/bin/cache/artifacts/material_fonts/roboto-regular.ttf',
      );
      if (file.existsSync() && file.lengthSync() > 100) {
        final loader = FontLoader('Roboto')
          ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
        await loader.load();
      }
      final icons = File(
        '$fonts/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      );
      final iconLoader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
      await iconLoader.load();
    }
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime.now();
    DateTime at(int h, int m) => DateTime(now.year, now.month, now.day, h, m);
    final items = [
      PlanItem(
        id: 'a',
        title: 'Сфокусироваться на главном',
        start: at(23, 0),
        end: at(23, 45),
        category: 'Работа',
        priority: 2,
      ),
      PlanItem(
        id: 'b',
        title: 'Встреча с командой',
        start: at(14, 0),
        end: at(15, 0),
        task: false,
        category: 'Проект',
        color: 1,
      ),
      PlanItem(
        id: 'c',
        title: 'Прочитать новую главу',
        start: at(19, 0),
        end: at(19, 30),
        category: 'Личное',
        color: 2,
      ),
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlannerStore.channel, (call) async {
          switch (call.method) {
            case 'load':
              return jsonEncode({
                'items': items.map((i) => i.toJson()).toList(),
                'syncBase': [],
              });
            case 'status':
              return {'vault': false, 'notifications': true, 'exact': true};
            case 'launch':
              return {};
            default:
              return null;
          }
        });
    final key = GlobalKey();
    final store = PlannerStore();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: DaylineApp(store: store),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '../preview-app.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox());
    store.dispose();
    debugDisableShadows = true;
  });
}
