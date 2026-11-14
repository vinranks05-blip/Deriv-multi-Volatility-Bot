import 'package:flutter_test/flutter_test.dart';
import 'package:v11_expert_trader/deriv_v13_market_data.dart';
import 'package:v11_expert_trader/prediction_engine.dart';

void main() {
  test('exact quote digits preserve broker precision', () {
    expect(digitFromQuote('123.450', 3), 0);
    expect(digitFromQuote('123.45', 3), 0);
    expect(digitFromQuote('0.00009', 5), 9);
    expect(digitFromQuote('12', 0), 2);
    expect(() => digitFromQuote('1.234', 2), throwsFormatException);
    expect(V13Tick('R_10', 123.45, 1, 3, '123.450').lastDigit, 0);
  });
  test('validation statistics are available separately from final test', () {
    final xs = List<int>.generate(600, (i) => (i * 3 + i ~/ 17) % 10);
    final result = evaluateDigits(xs, PredictionMode.matches, 5);
    expect(result.validationCount, 120);
    expect(result.validationAccuracy, inInclusiveRange(0, 1));
    expect(result.validationBaselineAccuracy, inInclusiveRange(0, 1));
  });
}
