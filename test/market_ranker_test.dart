import 'package:flutter_test/flutter_test.dart';
import 'package:v11_expert_trader/market_ranker.dart';

void main() {
  test('no market selected without observations', () {
    expect(MarketRanker.bestEligible([
      const MarketCandidate(market: 'R_25', contract: 'MATCH', wins: 0,
        observations: 0, baselineProbability: 0.1, netProfitPerUnitStake: 8),
    ]), isNull);
  });

  test('insufficient observations cannot produce eligible ranking', () {
    final ranked = MarketRanker.evaluate([
      const MarketCandidate(market: 'R_50', contract: 'EVEN', wins: 20,
        observations: 20, baselineProbability: 0.5, netProfitPerUnitStake: 1),
    ]);
    expect(ranked.single.eligible, isFalse);
  });

  test('invalid payout cannot produce eligible ranking', () {
    final ranked = MarketRanker.evaluate([
      const MarketCandidate(market: 'R_75', contract: 'EVEN', wins: 290,
        observations: 300, baselineProbability: 0.5, netProfitPerUnitStake: null),
    ]);
    expect(ranked.single.eligible, isFalse);
  });

  test('clearly above-baseline forward evidence is ranked first', () {
    final ranked = MarketRanker.evaluate([
      const MarketCandidate(market: 'R_25', contract: 'EVEN', wins: 150,
        observations: 300, baselineProbability: 0.5, netProfitPerUnitStake: 1),
      const MarketCandidate(market: 'R_50', contract: 'EVEN', wins: 280,
        observations: 300, baselineProbability: 0.5, netProfitPerUnitStake: 1),
    ]);
    expect(ranked.first.candidate.market, 'R_50');
    expect(ranked.first.eligible, isTrue);
    expect(ranked.last.eligible, isFalse);
  });
}
