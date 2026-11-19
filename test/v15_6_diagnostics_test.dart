import 'package:flutter_test/flutter_test.dart';
import '../lib/prediction_engine.dart';

void main() {
  test('MATCH eligibility reports missing held-out observations', () {
    expect(matchesAbstentionReason(testCount: 202, testAccuracy: .109),
        contains('202/300'));
  });
  test('MATCH eligibility does not mistake baseline accuracy for an edge', () {
    expect(matchesAbstentionReason(testCount: 400, testAccuracy: .10),
        contains('No statistically supported'));
  });
  test('MATCH eligibility rejects invalid accuracy', () {
    expect(matchesAbstentionReason(testCount: 400, testAccuracy: double.nan),
        contains('Invalid'));
  });
}
