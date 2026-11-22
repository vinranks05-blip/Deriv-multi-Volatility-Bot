import 'edge_diagnostics.dart';

/// An independently evaluated market/contract combination.
/// Input observations must be forward-recorded and out of sample.
class MarketCandidate {
  final String market;
  final String contract;
  final int wins;
  final int observations;
  final double baselineProbability;
  final double? netProfitPerUnitStake;

  const MarketCandidate({
    required this.market,
    required this.contract,
    required this.wins,
    required this.observations,
    required this.baselineProbability,
    required this.netProfitPerUnitStake,
  });

  EdgeDiagnostics get diagnostics => EdgeDiagnostics(
    wins: wins,
    observations: observations,
    nullProbability: baselineProbability,
    netProfitPerUnitStake: netProfitPerUnitStake,
  );
}

class RankedMarket {
  final MarketCandidate candidate;
  final bool eligible;
  final double? conservativeExpectedNet;
  final String reason;

  const RankedMarket(this.candidate, this.eligible,
      this.conservativeExpectedNet, this.reason);
}

/// Screening and ranking only: does not execute or authorize trades.
/// Conservative bounds are not adjusted for selection across many markets.
class MarketRanker {
  static List<RankedMarket> evaluate(List<MarketCandidate> candidates) {
    final results = candidates.map((candidate) {
      final d = candidate.diagnostics;
      if (!d.valid) return RankedMarket(candidate, false, null, 'Invalid evidence');
      if (candidate.observations < 300) {
        return RankedMarket(candidate, false, null, 'Insufficient forward observations');
      }
      final payout = candidate.netProfitPerUnitStake;
      if (payout == null || !payout.isFinite || payout <= 0) {
        return RankedMarket(candidate, false, null, 'Missing valid payout quote');
      }
      final conservativeNet = d.lowerBound99! * (payout + 1) - 1;
      if (!d.beatsNullConservatively) {
        return RankedMarket(candidate, false, conservativeNet, 'No demonstrated edge over baseline');
      }
      if (conservativeNet <= 0) {
        return RankedMarket(candidate, false, conservativeNet, 'No conservative payout-adjusted edge');
      }
      return RankedMarket(candidate, true, conservativeNet, 'Passed preliminary statistical screen');
    }).toList();
    results.sort((a, b) {
      if (a.eligible != b.eligible) return a.eligible ? -1 : 1;
      final scoreA = a.conservativeExpectedNet ?? double.negativeInfinity;
      final scoreB = b.conservativeExpectedNet ?? double.negativeInfinity;
      final scoreComparison = scoreB.compareTo(scoreA);
      if (scoreComparison != 0) return scoreComparison;
      final marketComparison = a.candidate.market.compareTo(b.candidate.market);
      return marketComparison != 0 ? marketComparison : a.candidate.contract.compareTo(b.candidate.contract);
    });
    return results;
  }

  static RankedMarket? bestEligible(List<MarketCandidate> candidates) {
    final results = evaluate(candidates);
    return results.isNotEmpty && results.first.eligible ? results.first : null;
  }
}
