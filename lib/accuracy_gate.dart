/// V14.2: evidence-based 70% accuracy target for every prediction strategy.
/// A target is not a guarantee. Never count withheld signals as wins.
enum SignalStrategy { matches, evenOdd, over, under }

class AccuracySnapshot {
  final int wins;
  final int losses;
  const AccuracySnapshot(this.wins, this.losses);
  int get observations => wins + losses;
  double? get accuracy => observations == 0 ? null : wins / observations;
  bool get meetsTarget => observations >= 1000 && (accuracy ?? 0) >= 0.70;
}

class AccuracyGate {
  static const double target = 0.70;
  static const int minimumObservations = 1000;
  final Map<String, List<bool>> _outcomes = {};

  String _key(String symbol, SignalStrategy strategy) => '$symbol:${strategy.name}';

  void record({required String symbol, required SignalStrategy strategy,
    required bool won}) {
    final key = _key(symbol, strategy);
    _outcomes.putIfAbsent(key, () => <bool>[]).add(won);
  }

  AccuracySnapshot snapshot(String symbol, SignalStrategy strategy) {
    final outcomes = _outcomes[_key(symbol, strategy)] ?? const <bool>[];
    return AccuracySnapshot(outcomes.where((v) => v).length,
        outcomes.where((v) => !v).length);
  }

  /// Signal selection is based on estimated probability, not historical hit rate.
  /// This threshold alone does not establish a predictive advantage.
  bool allowSignal({required double estimatedProbability,
    required int calibrationObservations,
    required double calibrationAccuracy}) {
    return estimatedProbability.isFinite &&
        estimatedProbability >= target &&
        calibrationObservations >= minimumObservations &&
        calibrationAccuracy >= target;
  }

  bool allMeetTarget(String symbol) => SignalStrategy.values.every(
      (strategy) => snapshot(symbol, strategy).meetsTarget);
}
