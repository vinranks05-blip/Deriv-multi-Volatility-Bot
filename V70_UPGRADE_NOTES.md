# V70.0 — Market Ranking Foundation

Adds `lib/market_ranker.dart` and `test/market_ranker_test.dart`.

The ranker compares independently forward-recorded market/contract evidence, rejects inadequate samples or missing payout quotes, and ranks eligible candidates by conservative payout-adjusted expected return.

**Not yet integrated with the live scanner UI or market feed.** No automated trading, retraining, or market selection is active. The screen is statistical only and not multiple-comparison adjusted. It does not establish actual trading profitability.

Run `flutter test` and `flutter analyze` through the existing GitHub Actions workflow.
