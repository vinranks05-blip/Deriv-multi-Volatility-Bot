import 'package:flutter_test/flutter_test.dart';
import 'package:v11_expert_trader/edge_diagnostics.dart';

void main() {
  test('empty observations never qualify', () {
    final x = EdgeDiagnostics(wins: 0, observations: 0, nullProbability: .1);
    expect(x.observedRate, isNull);
    expect(x.beatsNullConservatively, isFalse);
  });
  test('small samples cannot establish an edge', () {
    final x = EdgeDiagnostics(wins: 7, observations: 10, nullProbability: .6);
    expect(x.beatsNullConservatively, isFalse);
  });
  test('chance-level results do not qualify', () {
    final x = EdgeDiagnostics(wins: 30, observations: 300, nullProbability: .1);
    expect(x.beatsNullConservatively, isFalse);
  });
  test('payout threshold and net expectation use net win profit', () {
    final x = EdgeDiagnostics(wins: 180, observations: 300,
      nullProbability: .5, netProfitPerUnitStake: .8);
    expect(x.breakEvenProbability!, closeTo(1 / 1.8, 1e-10));
    expect(x.expectedNetPerUnitStake!, closeTo(.08, 1e-10));
  });
  test('missing payout does not imply profit', () {
    final x = EdgeDiagnostics(wins: 250, observations: 300, nullProbability: .5);
    expect(x.passesConservativePayoutScreen, isFalse);
  });
}
