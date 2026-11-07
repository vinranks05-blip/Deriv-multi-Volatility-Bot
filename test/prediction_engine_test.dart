import 'package:flutter_test/flutter_test.dart';
import 'package:v11_expert_trader/prediction_engine.dart';

void main() {
  test('ML uses current features for every prediction', () {
    final weights = List.generate(10, (_) => List<double>.filled(31, 0));
    weights[3][1 + 2] = 8;
    weights[7][1 + 6] = 8;
    final model = DigitModel(3, weights);
    final first = model.probabilities([1, 2]);
    final next = model.probabilities([1, 2, 6]);
    expect(chooseDigit(first, PredictionMode.matches, 5).digit, 3);
    expect(chooseDigit(next, PredictionMode.matches, 5).digit, 7);
    expect(next.reduce((a, b) => a + b), closeTo(1, 1e-12));
  });

  test('evaluation continues after the 5000-tick buffer fills', () {
    expect(needsEvaluation(5000, null), isTrue);
    expect(needsEvaluation(5099, 5000), isFalse);
    expect(needsEvaluation(5100, 5000), isTrue);
    expect(needsEvaluation(5200, 5100), isTrue);
  });

  test('Even/Odd sums all parity probabilities', () {
    final p = [.30, .14, .02, .14, .02, .14, .02, .10, .02, .10];
    final choice = chooseDigit(p, PredictionMode.evenOdd, 5);
    expect(choice.digit.isOdd, isTrue);
    expect(choice.score, closeTo(.62, 1e-12));
    expect(digitWins(PredictionMode.evenOdd, choice.digit, 9), isTrue);
    expect(digitWins(PredictionMode.evenOdd, choice.digit, 8), isFalse);
  });

  test('Over and Under use strict explicit barrier conditions', () {
    final p = List<double>.filled(10, .1);
    expect(chooseDigit(p, PredictionMode.over, 5).score, closeTo(.4, 1e-12));
    expect(chooseDigit(p, PredictionMode.under, 5).score, closeTo(.5, 1e-12));
    expect(digitWins(PredictionMode.over, 5, 6), isTrue);
    expect(digitWins(PredictionMode.over, 5, 5), isFalse);
    expect(digitWins(PredictionMode.under, 5, 4), isTrue);
    expect(digitWins(PredictionMode.under, 5, 5), isFalse);
    expect(() => chooseDigit(p, PredictionMode.over, 9), throwsArgumentError);
    expect(() => chooseDigit(p, PredictionMode.under, 0), throwsArgumentError);
    expect(uniformBaseline(PredictionMode.over, 5), .4);
    expect(uniformBaseline(PredictionMode.under, 5), .5);
  });

  test('changing final test labels cannot change model selection or weights',
      () {
    final history = List.generate(600, (i) => (i * 7 + i ~/ 11) % 10);
    final altered = List<int>.of(history);
    for (var i = 480; i < altered.length; i++) {
      altered[i] = 9;
    }
    final before = evaluateDigits(history, PredictionMode.matches, 5);
    final after = evaluateDigits(altered, PredictionMode.matches, 5);
    expect(before.validationCount, 120);
    expect(before.testCount, 120);
    expect(after.model.method, before.model.method);
    expect(after.model.weights, before.model.weights);
    expect(before.testAccuracy, inInclusiveRange(0.0, 1.0));
    expect(after.baselineAccuracy, inInclusiveRange(0.0, 1.0));
  });

  test(
      'fixed predictors score a deterministic stream and its baseline correctly',
      () {
    for (final mode in PredictionMode.values) {
      final result = evaluateDigits(List<int>.filled(300, 2), mode, 5);
      final expected = mode == PredictionMode.over ? 0.0 : 1.0;
      expect(result.testCount, 60);
      expect(result.testAccuracy, expected);
      expect(result.baselineAccuracy, expected);
    }
  });
}
