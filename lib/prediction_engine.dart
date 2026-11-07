import 'dart:math';

enum PredictionMode { matches, evenOdd, over, under }

const predictionLabels = ['Matches', 'Even/Odd', 'Over', 'Under'];

class DigitChoice {
  final int digit;
  final double score;
  const DigitChoice(this.digit, this.score);
}

DigitChoice chooseDigit(
    List<double> probabilities, PredictionMode mode, int barrier) {
  if (barrier < 0 || barrier > 9) throw ArgumentError.value(barrier);
  switch (mode) {
    case PredictionMode.matches:
      var best = 0;
      for (var d = 1; d < 10; d++) {
        if (probabilities[d] > probabilities[best]) best = d;
      }
      return DigitChoice(best, probabilities[best]);
    case PredictionMode.evenOdd:
      var even = 0.0;
      for (var d = 0; d < 10; d += 2) {
        even += probabilities[d];
      }
      return even >= 0.5 ? DigitChoice(0, even) : DigitChoice(1, 1 - even);
    case PredictionMode.over:
      if (barrier == 9) throw ArgumentError('Over 9 cannot win');
      return DigitChoice(
          barrier, probabilities.skip(barrier + 1).fold(0.0, (a, b) => a + b));
    case PredictionMode.under:
      if (barrier == 0) throw ArgumentError('Under 0 cannot win');
      return DigitChoice(
          barrier, probabilities.take(barrier).fold(0.0, (a, b) => a + b));
  }
}

bool digitWins(PredictionMode mode, int predicted, int actual) =>
    switch (mode) {
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
  for (var j = start; j <= i; j++) {
    x[21 + xs[j]] += 1 / (i - start + 1);
  }
  return x;
}

class DigitModel {
  final int method;
  final List<List<double>>? weights;
  const DigitModel(this.method, [this.weights]);
  String get name =>
      ['Frequency', 'Recent 50', 'Transition blend', 'ML softmax'][method];

  factory DigitModel.trainML(List<int> training) {
    final w = List.generate(10, (_) => List<double>.filled(31, 0));
    for (var pass = 0; pass < 5; pass++) {
      for (var i = 50; i < training.length - 1; i += 2) {
        final x = _features(training, i);
        final p = _softmax(w, x);
        for (var d = 0; d < 10; d++) {
          final delta = .035 * ((d == training[i + 1] ? 1.0 : 0.0) - p[d]);
          for (var k = 0; k < 31; k++) {
            w[d][k] += delta * x[k];
          }
        }
      }
    }
    return DigitModel(3, w);
  }

  static List<double> _softmax(List<List<double>> w, List<double> x) {
    final z = List.generate(10, (d) {
      var v = 0.0;
      for (var k = 0; k < 31; k++) {
        v += w[d][k] * x[k];
      }
      return v;
    });
    final top = z.reduce(max);
    final exps = z.map((v) => exp(v - top)).toList();
    final total = exps.reduce((a, b) => a + b);
    return exps.map((v) => v / total).toList();
  }

  // Weights stay fixed, but features always come from the latest input ticks.
  List<double> probabilities(List<int> history) {
    if (history.length < 2) throw ArgumentError('Need at least two digits');
    if (weights != null)
      return _softmax(weights!, _features(history, history.length - 1));
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
  final double testAccuracy, baselineAccuracy;
  const ModelEvaluation(this.model, this.validationCount, this.testCount,
      this.testAccuracy, this.baselineAccuracy);
}

// Select on the middle 20%; report performance only on the final 20%.
// Every prediction sees only ticks preceding its label. The final test never
// selects the model, including the decision whether to use ML.
ModelEvaluation evaluateDigits(
    List<int> all, PredictionMode mode, int barrier) {
  if (all.length < 250) throw ArgumentError('Need at least 250 ticks');
  final xs = all.skip(max(0, all.length - 1200)).toList();
  final trainEnd = (xs.length * .6).floor();
  final testStart = (xs.length * .8).floor();
  final training = xs.sublist(0, trainEnd);
  final candidates = [
    const DigitModel(0),
    const DigitModel(1),
    const DigitModel(2),
    DigitModel.trainML(training)
  ];
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
    if (score > best) {
      best = score;
      chosen = candidate;
    }
  }
  final baseline =
      chooseDigit(const DigitModel(0).probabilities(training), mode, barrier);
  var baseWins = 0;
  for (var i = testStart; i < xs.length; i++) {
    if (digitWins(mode, baseline.digit, xs[i])) baseWins++;
  }
  final count = xs.length - testStart;
  return ModelEvaluation(chosen, testStart - trainEnd, count,
      wins(chosen, testStart, xs.length) / count, baseWins / count);
}

bool needsEvaluation(int tickSequence, int? previousSequence) =>
    previousSequence == null || tickSequence - previousSequence >= 100;
