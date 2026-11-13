import 'dart:math';

enum PredictionMode { matches, evenOdd, over, under }
const predictionLabels = ['Matches', 'Even/Odd', 'Over', 'Under'];

class DigitChoice {
  final int digit;
  final double score;
  const DigitChoice(this.digit, this.score);
}

DigitChoice chooseDigit(List<double> probabilities, PredictionMode mode, int barrier) {
  if (barrier < 0 || barrier > 9) throw ArgumentError.value(barrier);
  if (probabilities.length != 10 || probabilities.any((p) => !p.isFinite || p < 0) ||
      (probabilities.reduce((a, b) => a + b) - 1).abs() > 1e-6) {
    throw ArgumentError('Expected ten normalized nonnegative probabilities');
  }
  switch (mode) {
    case PredictionMode.matches:
      var best = 0;
      for (var d = 1; d < 10; d++) { if (probabilities[d] > probabilities[best]) best = d; }
      return DigitChoice(best, probabilities[best]);
    case PredictionMode.evenOdd:
      var even = 0.0;
      for (var d = 0; d < 10; d += 2) { even += probabilities[d]; }
      return even >= .5 ? DigitChoice(0, even) : DigitChoice(1, 1 - even);
    case PredictionMode.over:
      if (barrier == 9) throw ArgumentError('Over 9 cannot win');
      return DigitChoice(barrier, probabilities.skip(barrier + 1).fold(0.0, (a, b) => a + b));
    case PredictionMode.under:
      if (barrier == 0) throw ArgumentError('Under 0 cannot win');
      return DigitChoice(barrier, probabilities.take(barrier).fold(0.0, (a, b) => a + b));
  }
}

bool digitWins(PredictionMode mode, int predicted, int actual) => switch (mode) {
  PredictionMode.matches => actual == predicted,
  PredictionMode.evenOdd => actual.isEven == predicted.isEven,
  PredictionMode.over => actual > predicted,
  PredictionMode.under => actual < predicted,
};

double uniformBaseline(PredictionMode mode, int barrier) => switch (mode) {
  PredictionMode.matches => .1,
  PredictionMode.evenOdd => .5,
  PredictionMode.over => (9 - barrier) / 10,
  PredictionMode.under => barrier / 10,
};

List<double> _features(List<int> xs, int i) {
  final x = List<double>.filled(31, 0);
  x[0] = 1;
  x[1 + xs[i]] = 1;
  x[11 + xs[i - 1]] = 1;
  final start = max(0, i - 49);
  for (var j = start; j <= i; j++) { x[21 + xs[j]] += 1 / (i - start + 1); }
  return x;
}

class DigitModel {
  final int method;
  final List<List<double>>? weights;
  const DigitModel(this.method, [this.weights]);
  String get name => ['Frequency', 'Recent 50', 'Transition blend', 'ML softmax'][method];

  factory DigitModel.trainML(List<int> training) {
    final w = List.generate(10, (_) => List<double>.filled(31, 0));
    for (var pass = 0; pass < 5; pass++) {
      for (var i = 50; i < training.length - 1; i += 2) {
        final x = _features(training, i);
        final p = _softmax(w, x);
        for (var d = 0; d < 10; d++) {
          final delta = .035 * ((d == training[i + 1] ? 1.0 : 0.0) - p[d]);
          for (var k = 0; k < 31; k++) { w[d][k] += delta * x[k]; }
        }
      }
    }
    return DigitModel(3, w);
  }

  static List<double> _softmax(List<List<double>> w, List<double> x) {
    final z = List.generate(10, (d) {
      var v = 0.0;
      for (var k = 0; k < 31; k++) { v += w[d][k] * x[k]; }
      return v;
    });
    final top = z.reduce(max);
    final exps = z.map((v) => exp(v - top)).toList();
    final total = exps.reduce((a, b) => a + b);
    return exps.map((v) => v / total).toList();
  }

  List<double> probabilities(List<int> history) {
    if (history.length < 2) throw ArgumentError('Need at least two digits');
    if (weights != null) return _softmax(weights!, _features(history, history.length - 1));
    final xs = history.skip(max(0, history.length - 200)).toList();
    final counts = List<double>.filled(10, 1);
    final recent = List<double>.filled(10, 1);
    final transitions = List<double>.filled(10, 1);
    for (var i = 0; i < xs.length; i++) {
      counts[xs[i]]++;
      if (i >= xs.length - 50) recent[xs[i]]++;
      if (i > 0 && xs[i - 1] == xs.last) transitions[xs[i]]++;
    }
    List<double> norm(List<double> a) {
      final total = a.reduce((x, y) => x + y);
      return a.map((v) => v / total).toList();
    }
    final global = norm(counts);
    if (method == 0) return global;
    if (method == 1) return norm(recent);
    final conditional = norm(transitions);
    final n = transitions.reduce((a, b) => a + b) - 10;
    final w = n / (n + 50);
    return List.generate(10, (d) => w * conditional[d] + (1 - w) * global[d]);
  }
}

class ModelEvaluation {
  final DigitModel model;
  final int validationCount, testCount;
  final double testAccuracy, baselineAccuracy, logLoss, brierScore;
  // Diagnostics only: repeatedly inspecting rolling tests invalidates a fresh holdout.
  final double meanPredictedProbability, calibrationGap;
  final int testWins;
  final bool matchesEvidence;
  const ModelEvaluation(this.model, this.validationCount, this.testCount,
      this.testAccuracy, this.baselineAccuracy,
      {this.logLoss = 0, this.brierScore = 0,
      this.meanPredictedProbability = 0, this.calibrationGap = 0,
      this.testWins = 0, this.matchesEvidence = false});
}

// Exact one-sided binomial upper-tail under independent Bernoulli(p) null.
// A research diagnostic only: does not correct for model/market selection,
// overlapping rolling windows, serial dependence, or repeated peeking.
double binomialUpperTail(int wins, int trials, {double p = .1}) {
  if (trials < 0 || wins < 0 || wins > trials || p < 0 || p > 1) {
    throw ArgumentError('Invalid binomial parameters');
  }
  if (wins == 0) return 1;
  if (p == 0) return 0;
  if (p == 1) return 1;
  // Sum from the smaller tail direction using log probabilities to avoid overflow.
  double logTerm(int k) => _logFactorial(trials) - _logFactorial(k) -
      _logFactorial(trials - k) + k * log(p) + (trials - k) * log(1 - p);
  final terms = <double>[];
  for (var k = wins; k <= trials; k++) { terms.add(logTerm(k)); }
  final top = terms.reduce(max);
  return min(1.0, exp(top) * terms.map((x) => exp(x - top)).reduce((a, b) => a + b));
}

double _logFactorial(int n) {
  var value = 0.0;
  for (var i = 2; i <= n; i++) { value += log(i); }
  return value;
}

ModelEvaluation evaluateDigits(List<int> all, PredictionMode mode, int barrier) {
  if (all.length < 250) throw ArgumentError('Need at least 250 ticks');
  if (all.any((d) => d < 0 || d > 9)) throw ArgumentError('Digits must be 0–9');
  final xs = all.skip(max(0, all.length - 1200)).toList();
  final trainEnd = (xs.length * .6).floor();
  final testStart = (xs.length * .8).floor();
  final training = xs.sublist(0, trainEnd);
  final candidates = [const DigitModel(0), const DigitModel(1),
    const DigitModel(2), DigitModel.trainML(training)];
  int wins(DigitModel model, int start, int end) {
    var right = 0;
    for (var label = start; label < end; label++) {
      final input = xs.sublist(max(0, label - 200), label);
      final choice = chooseDigit(model.probabilities(input), mode, barrier);
      if (digitWins(mode, choice.digit, xs[label])) right++;
    }
    return right;
  }
  var chosen = candidates.first;
  var best = -1;
  for (final candidate in candidates) {
    final score = wins(candidate, trainEnd, testStart);
    if (score > best) { best = score; chosen = candidate; }
  }
  final baseline = chooseDigit(const DigitModel(0).probabilities(training), mode, barrier);
  var baseWins = 0;
  for (var i = testStart; i < xs.length; i++) {
    if (digitWins(mode, baseline.digit, xs[i])) baseWins++;
  }
  var logLoss = 0.0, brier = 0.0, confidenceSum = 0.0;
  for (var i = testStart; i < xs.length; i++) {
    final p = chosen.probabilities(xs.sublist(max(0, i - 200), i));
    final choice = chooseDigit(p, mode, barrier);
    confidenceSum += choice.score;
    logLoss -= log(max(1e-15, p[xs[i]]));
    for (var d = 0; d < 10; d++) {
      brier += pow(p[d] - (d == xs[i] ? 1 : 0), 2).toDouble();
    }
  }
  final count = xs.length - testStart;
  final correct = wins(chosen, testStart, xs.length);
  final accuracy = correct / count;
  final meanConfidence = confidenceSum / count;
  // A conservative research gate, NOT independent proof of a trading edge.
  final evidence = mode == PredictionMode.matches && count >= 200 &&
      accuracy > .1 && accuracy > baseWins / count &&
      binomialUpperTail(correct, count) < .01;
  return ModelEvaluation(chosen, testStart - trainEnd, count,
      accuracy, baseWins / count, logLoss: logLoss / count,
      brierScore: brier / count, meanPredictedProbability: meanConfidence,
      calibrationGap: (meanConfidence - accuracy).abs(),
      testWins: correct, matchesEvidence: evidence);
}

bool needsEvaluation(int tickSequence, int? previousSequence) =>
    previousSequence == null || tickSequence - previousSequence >= 100;
