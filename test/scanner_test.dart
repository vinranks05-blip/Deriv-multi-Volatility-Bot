// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:v11_expert_trader/ledger_storage.dart';
import 'package:v11_expert_trader/deriv_v13_market_data.dart';
import 'package:v11_expert_trader/main.dart';

class FakeMarketData extends V13MarketData {
  final tickEvents = StreamController<V13Tick>.broadcast();
  final historyEvents = StreamController<String>.broadcast();
  @override
  Stream<V13Tick> get ticks => tickEvents.stream;
  @override
  Stream<String> get historyUpdates => historyEvents.stream;
  @override
  Future<void> connect() async {
    connected = true;
  }

  @override
  void watch(String symbol) {}

  void seed({String symbol = 'R_10'}) {
    history[symbol] = List.generate(300, (i) => V13Tick(symbol, 100.002, i, 3));
    historyEvents.add(symbol);
    emit(300, symbol: symbol);
  }

  void emit(int epoch, {String symbol = 'R_10'}) {
    final tick = V13Tick(symbol, 100.002, epoch, 3);
    history[symbol]!.add(tick);
    tickEvents.add(tick);
  }

  @override
  Future<void> dispose() async {
    await tickEvents.close();
    await historyEvents.close();
    await super.dispose();
  }
}

void main() {
  testWidgets(
      'canonical app abstains when Under score fails the configured threshold',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final data = FakeMarketData();
    final storage = MemoryLedgerStorage();
    await tester.pumpWidget(V13App(data: data, storage: storage));
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Under'));
    data.seed();
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    // Constant-digit synthetic history must not force an unqualified signal.
    expect(storage.events.where((e) => e['paper'] == 'opened' || e['paper'] == 'settled'), isEmpty);
    data.emit(301);
    await tester.pump();
    await tester.pump();
    expect(storage.events.where((e) => e['paper'] == 'opened' || e['paper'] == 'settled'), isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'pausing without an eligible MATCH forecast does not create a missed tick',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final data = FakeMarketData();
    final storage = MemoryLedgerStorage();
    await tester.pumpWidget(V13App(data: data, storage: storage));
    await tester.pump();
    data.seed();
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    // MATCH must abstain on the short, constant-digit synthetic history.
    expect(find.text('NEXT TICK • MATCH 2'), findsNothing);
    expect(storage.events, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    data.emit(301);
    await tester.pump();
    // A pause must not manufacture a missed forecast when none was issued.
    expect(storage.events, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
