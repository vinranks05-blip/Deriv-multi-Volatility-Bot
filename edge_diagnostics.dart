import 'dart:math';

/// Read-only statistical diagnostics. No diagnostic authorizes a live trade.
class EdgeDiagnostics {
  final int wins;
  final int observations;
  final double nullProbability;
  final double? netProfitPerUnitStake;

  const EdgeDiagnostics({
    required this.wins,
    required this.observations,
    required this.nullProbability,
    this.netProfitPerUnitStake,
  });

  bool get valid => observations > 0 && wins >= 0 &&
      wins <= observations && nullProbability >= 0 &&
      nullProbability <= 1 && nullProbability.isFinite;

  double? get observedRate => valid ? wins / observations : null;

  /// One-sided Wilson lower confidence bound, with z=2.576 (conservative).
  double? get lowerBound99 {
    if (!valid) return null;
    const z = 2.576;
    final n = observations.toDouble();
    final p = wins / n;
    final denominator = 1 + z * z / n;
    return max(0, (p + z * z / (2 * n) -
        z * sqrt((p * (1 - p) + z * z / (4 * n)) / n)) / denominator);
  }

  /// Statistical screening only, not a profitability or independence claim.
  bool get beatsNullConservatively => observations >= 300 &&
      (lowerBound99 ?? 0) > nullProbability;

  /// netProfitPerUnitStake is profit paid on a win, excluding returned stake.
  /// A loss costs one stake. Requires a verified broker quote.
  double? get breakEvenProbability {
    final payout = netProfitPerUnitStake;
    if (payout == null || !payout.isFinite || payout <= 0) return null;
    return 1 / (payout + 1);
  }

  double? get expectedNetPerUnitStake {
    final p = observedRate;
    final payout = netProfitPerUnitStake;
    if (p == null || payout == null || !payout.isFinite || payout <= 0) {
      return null;
    }
    return p * payout - (1 - p);
  }

  bool get passesConservativePayoutScreen => beatsNullConservatively &&
      breakEvenProbability != null &&
      (lowerBound99 ?? 0) > breakEvenProbability!;
}
