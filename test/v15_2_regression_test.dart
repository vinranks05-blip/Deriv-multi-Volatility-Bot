import 'package:flutter_test/flutter_test.dart';
import 'package:v11_expert_trader/deriv_v13_market_data.dart';
import 'package:v11_expert_trader/prediction_engine.dart';

void main() {
  test('quote text preserves precision and rejects unsupported forms', () {
    expect(digitFromQuote('12.340', 3), 0);
    expect(digitFromQuote('12.34', 3), 0);
    expect(digitFromQuote('12.349', 3), 9);
    expect(() => digitFromQuote('NaN', 3), throwsFormatException);
    expect(() => digitFromQuote('12.3499', 3), throwsFormatException);
  });

  test('test baseline is rolling and never uses test labels ahead', () {
    final digits = List<int>.generate(600, (i) => (i ~/ 50) % 10);
    final result = evaluateDigits(digits, PredictionMode.matches, 5);
    var correct = 0;
    for (var i = 480; i < 600; i++) {
      final history = digits.sublist(i - 200, i);
      final choice = chooseDigit(
        const DigitModel(0).probabilities(history),
        PredictionMode.matches, 5,
      );
      if (choice.digit == digits[i]) correct++;
    }
    expect(result.baselineAccuracy, closeTo(correct / 120, 1e-12));
  });

  test('evaluation labels are bounded and do not guarantee target accuracy', () {
    final digits = List<int>.generate(600, (i) => (i * 7 + i ~/ 13) % 10);
    final result = evaluateDigits(digits, PredictionMode.matches, 5);
    expect(result.validationCount, 120);
    expect(result.testCount, 120);
    expect(result.testAccuracy, inInclusiveRange(0, 1));
  });
}
