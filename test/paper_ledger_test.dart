import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:v11_expert_trader/paper_ledger.dart';
import 'package:v11_expert_trader/prediction_engine.dart';
import 'package:v11_expert_trader/ledger_storage.dart';

void main() {
  final start = DateTime.utc(2026, 11, 7, 12);
  late List<Map<String, dynamic>> events;
  late PaperLedger ledger;
  SignalRecord issue({int digit = 1, String symbol = 'R_10'}) => ledger.issue(
      symbol: symbol,
      model: 'Frequency',
      mode: PredictionMode.matches,
      digit: digit,
      sourceEpoch: 100,
      sourceSequence: 10,
      now: start,
      score: 12);
  void tick(int sequence, int ms, int digit) => ledger.tick(
      symbol: 'R_10',
      epoch: 100 + sequence,
      sequence: sequence,
      price: 100 + digit / 1000,
      digit: digit,
      now: start.add(Duration(milliseconds: ms)));

  setUp(() {
    events = [];
    ledger = PaperLedger(onEvent: events.add);
    ledger.config =
        const PaperConfig(symbol: 'R_10', stake: 2, grossMultiplier: 9.24);
    ledger.enabled = true;
  });

  test('a correct next-tick signal can lose after a delayed entry', () {
    final r = issue();
    expect(events.first['record']['observation'], 'pending');
    expect(ledger.reserved, 2);
    tick(11, 500, 1);
    expect(r.observation, 'correct');
    expect(r.paper, 'waiting');
    tick(12, 1000, 9);
    expect(r.paper, 'open');
    expect(r.entryPrice, 100.009);
    expect(r.profit, isNull);
    tick(13, 1500, 2);
    expect(r.paper, 'lost');
    expect(r.profit, -2);
    expect(r.actual, 1);
    expect(r.exitDigit, 2);
    expect(ledger.available, 98);
    expect(ledger.reserved, 0);
    expect(events.first['record']['observation'], 'pending');
  });

  test('zero delay never enters retrospectively or settles on entry tick', () {
    ledger.config = const PaperConfig(symbol: 'R_10', stake: 2, delayMs: 0);
    final r = issue();
    expect(r.paper, 'waiting');
    tick(11, 1, 1);
    expect(r.paper, 'open');
    expect(r.profit, isNull);
    tick(11, 2, 1);
    expect(r.paper, 'open'); // duplicate tick
    tick(12, 3, 1);
    expect(r.paper, 'won');
    expect(r.profit, closeTo(16.48, 1e-10));
    expect(ledger.available, closeTo(116.48, 1e-10));
  });

  test('expiry keeps a complete missed entry and does not invent an outcome',
      () {
    final r = issue();
    ledger.expire(start.add(const Duration(milliseconds: 5000)));
    expect(r.observation, 'expired');
    expect(r.paper, 'expired');
    tick(11, 6000, 1);
    expect(r.actual, isNull);
    expect(r.profit, isNull);
    expect(ledger.available, 100);
  });

  test('stopping entries preserves open trade until its configured exit', () {
    final r = issue();
    tick(11, 1000, 2);
    ledger.stopEntries();
    expect(r.paper, 'open');
    tick(12, 2000, 1);
    expect(r.paper, 'won');
    expect(issue().paper, 'skipped');
  });

  test(
      'feed gap and restart keep unresolved stakes reserved until booked as loss',
      () {
    final r = issue();
    tick(11, 1000, 2);
    final replay = PaperLedger(onEvent: (_) {});
    replay.restore(events);
    expect(replay.records[r.id]!.paper, 'unresolved');
    expect(replay.available, 98);
    expect(replay.reserved, 2);
    expect(replay.realized, 0);
    expect(replay.enabled, isFalse);
    replay.resolveUncertainLoss(r.id, start.add(const Duration(seconds: 30)));
    expect(replay.reserved, 0);
    expect(replay.realized, -2);
    expect(replay.available, 98);
    expect(replay.records[r.id]!.paper, 'assumed_lost');
    replay.resolveUncertainLoss(r.id, start);
    expect(replay.realized, -2);
  });

  test(
      'only configured market enters and settings remain frozen on issued records',
      () {
    expect(issue(symbol: 'R_25').paper, 'skipped');
    final r = issue();
    ledger.config = const PaperConfig(
        symbol: 'R_10', stake: 20, grossMultiplier: 2, delayMs: 0);
    tick(11, 500, 2);
    expect(r.paper, 'waiting');
    tick(12, 1000, 2);
    tick(13, 2000, 1);
    expect(r.config.stake, 2);
    expect(r.profit, closeTo(16.48, 1e-10));
  });

  test('insufficient cash blocks paper entry without dropping the signal', () {
    ledger.initialBalance = 1;
    final r = issue();
    expect(r.paper, 'skipped');
    expect(r.observation, 'pending');
    tick(11, 1, 1);
    expect(r.observation, 'correct');
    expect(ledger.records, hasLength(1));
  });

  test('CSV exports every signal beyond the old 300-result cap', () {
    ledger.enabled = false;
    for (var i = 0; i < 350; i++) {
      issue();
    }
    expect(ledger.records, hasLength(350));
    final csv = ledger.csv();
    expect(csv.split('\r\n'), hasLength(352));
    expect(csv, contains('assumed_gross_multiplier'));
    expect(csv, contains('"pending"'));
  });

  test(
      'statistics separate observations from paper results and compute drawdown',
      () {
    issue();
    tick(11, 1000, 1);
    tick(12, 2000, 2);
    final stats = LedgerStats(ledger.records.values);
    expect(stats.accuracy, 1);
    expect(stats.profit, -2);
    expect(stats.drawdown, 2);
    expect(stats.interval!.$1, lessThan(1));
    expect(stats.interval!.$2, closeTo(1, 1e-10));
  });

  test('invalid assumptions reject nonfinite values and delay beyond validity',
      () {
    expect(() => const PaperConfig(stake: double.nan).validate(),
        throwsArgumentError);
    expect(() => const PaperConfig(grossMultiplier: double.infinity).validate(),
        throwsArgumentError);
    expect(() => const PaperConfig(delayMs: 5000, expiryMs: 5000).validate(),
        throwsArgumentError);
  });

  test(
      'file storage preserves event order and repairs only an incomplete final append',
      () async {
    final dir = await Directory.systemTemp.createTemp('paper-ledger-test-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/ledger.jsonl');
    final store = FileLedgerStorage(location: file);
    await Future.wait(List.generate(10, (i) => store.append({'n': i})));
    expect((await store.read()).map((e) => e['n']),
        orderedEquals(List.generate(10, (i) => i)));
    await file.writeAsString('{"partial":', mode: FileMode.append);
    expect(await store.read(), hasLength(10));
    expect(
        await dir.list().length, 2); // original tail preserved in recovery copy
    await store.append({'n': 10});
    expect(await store.read(), hasLength(11));
    expect(jsonDecode((await file.readAsLines()).last)['n'], 10);
  });
}
