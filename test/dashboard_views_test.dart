// ignore_for_file: deprecated_member_use
import 'dart:convert';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:v11_expert_trader/main.dart';
import 'package:v11_expert_trader/ledger_storage.dart';
import 'package:v11_expert_trader/paper_ledger.dart';
import 'scanner_test.dart' show FakeMarketData;

Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_UI')) return;
  await tester.pump();
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/ui-review/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets(
      'phone dashboard starts paper trading, records results and exposes export',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 932);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    if (const bool.fromEnvironment('CAPTURE_UI')) {
      await tester.runAsync(() async {
        final font = File('/System/Library/Fonts/Supplemental/Arial.ttf');
        if (await font.exists()) {
          final loader = FontLoader('Roboto')
            ..addFont(font.readAsBytes().then(ByteData.sublistView));
          await loader.load();
        }
      });
    }
    SharedPreferences.setMockInitialValues({
      'paperConfig':
          jsonEncode(const PaperConfig(symbol: 'R_25', delayMs: 0).toJson())
    });
    final data = FakeMarketData(), storage = MemoryLedgerStorage();
    final key = GlobalKey();
    await tester.pumpWidget(
        RepaintBoundary(key: key, child: V13App(data: data, storage: storage)));
    await tester.pump();
    await capture(tester, key, 'radar');
    await tester.tap(find.text('Paper'));
    await tester.pump();
    expect(find.text('Paper Trading'), findsOneWidget);
    await capture(tester, key, 'paper');
    await tester.ensureVisible(find.text('START PAPER'));
    await tester.pump();
    await tester.tap(find.text('START PAPER'));
    await tester.pump();
    data.seed(symbol: 'R_25');
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(storage.events.last['record']['paper'], 'waiting');
    data.emit(301, symbol: 'R_25');
    await tester.pump();
    expect(storage.events.last['record']['paper'], 'open');
    data.emit(302, symbol: 'R_25');
    await tester.pump();
    expect(storage.events.last['record']['paper'], 'won');
    expect(storage.events.last['record']['observation'], 'correct');
    await tester.ensureVisible(find.text('Ledger'));
    await tester.pump();
    await tester.tap(find.text('Ledger'));
    await tester.pump();
    expect(find.text('Signal Ledger'), findsOneWidget);
    expect(find.text('R_25 • MATCH 2'), findsOneWidget);
    final export = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'EXPORT ALL CSV'));
    expect(export.onPressed, isNotNull);
    await capture(tester, key, 'ledger');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('ledger storage failure stops new forecasts visibly',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final data = FakeMarketData();
    await tester.pumpWidget(V13App(data: data, storage: BrokenStorage()));
    await tester.pump();
    data.seed();
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(find.textContaining('Ledger unavailable:'), findsOneWidget);
    expect(find.text('NEXT TICK • MATCH 2'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

class BrokenStorage implements LedgerStorage {
  @override
  Future<List<Map<String, dynamic>>> read() async =>
      throw FileSystemException('Disk unavailable');
  @override
  Future<void> append(Map<String, dynamic> event) async =>
      throw FileSystemException('Disk unavailable');
  @override
  Future<void> flush() async {}
}
