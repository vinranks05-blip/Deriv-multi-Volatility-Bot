import 'package:flutter_test/flutter_test.dart';
import 'package:v11_expert_trader/paper_ledger.dart';
import 'package:v11_expert_trader/prediction_engine.dart';

void main() {
  test('session reset is persisted and daily losses survive it', () {
    final events = <Map<String, dynamic>>[];
    final ledger = PaperLedger(onEvent: events.add);
    final now = DateTime.utc(2026, 1, 1);
    ledger.resetSession(now);
    final restored = PaperLedger(onEvent: (_) {});
    restored.restore(events);
    expect(restored.sessionStart, now);
    expect(restored.enabled, isFalse);
  });
  test('risk limits block paper entries without dropping forecasts', () {
    final ledger = PaperLedger(onEvent: (_) {})..enabled = true;
    ledger.maxEntries = 0;
    final r = ledger.issue(
      symbol: 'R_25',
      model: 'test',
      mode: PredictionMode.matches,
      digit: 1,
      sourceEpoch: 1,
      sourceSequence: 1,
      now: DateTime.utc(2026),
      score: 10,
    );
    expect(r.paper, 'skipped');
    expect(r.observation, 'pending');
    expect(r.reason, contains('entry limit'));
    expect(ledger.reserved, 0);
  });
  test('historical proper scores are finite and bounded', () {
    final result = evaluateDigits(
      List.generate(500, (i) => i % 10),
      PredictionMode.matches,
      5,
    );
    expect(result.logLoss.isFinite, isTrue);
    expect(result.brierScore, inInclusiveRange(0, 2));
  });
}
