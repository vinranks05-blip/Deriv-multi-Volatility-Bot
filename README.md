# Deriv Volatility Scanner

An experimental, read-only Flutter app for Volatility 10/25/50/75/100 and their one-second variants. It uses public tick data, keeps an exportable signal ledger and simulates paper trades. It does not authenticate accounts or place broker orders.

## Run and verify

Install Flutter, then run:

```sh
flutter pub get
python3 tool/check_source_paths.py
flutter analyze
flutter test
# Optional public-feed smoke check (requires internet):
dart run tool/check_market_feed.dart
```

The canonical entry point is `lib/main.dart`. The root `main.dart` only forwards to it. To generate an Android project and build:

```sh
flutter create --empty --no-pub --platforms=android --project-name v11_expert_trader .
flutter pub get
flutter build apk --debug
```

The Android main manifest must include `<uses-permission android:name="android.permission.INTERNET" />`. The GitHub Actions workflow adds and verifies it, runs analysis and regression tests, and uploads a debug APK. Android tooling is required for a local APK build. This repository does not include generated platform directories.

## Prediction behavior

Automatic scans run every ten seconds while the app is foregrounded, after at least 250 ticks are available. A forecast is scored on the first subsequent received live tick, not a ten-second or ten-tick broker settlement. Pending forecasts are recorded as missed/cancelled on feed errors or lifecycle changes, and as expired when their validity window elapses. Issued records remain in the ledger. No forecast is issued for the impossible Over 9 or Under 0 conditions.

- Matches selects the digit with the largest model score.
- Even/Odd compares the total probability mass of each parity.
- Over and Under are separate strict comparisons against the user-selected barrier; equality loses.
- EMA, tick RSI and MACD are informational displays, not inputs to digit forecasting.

Candidates are overall frequency, recent-50 frequency, a smoothed transition model, and a small softmax classifier. Evaluation uses up to 1,200 recent ticks: the oldest 60% trains the classifier, the middle 20% selects a candidate, and the final 20% reports historical test accuracy. Each scored prediction uses only preceding ticks. The fixed baseline chooses its condition from training data and does not adapt to test labels. The final test does not select the winning candidate or whether to use ML.

The selected model is reevaluated after 100 received ticks per market, including when the 5,000-tick history buffer is full, or when the selected mode/barrier changes. ML weights remain fixed between evaluations, but every forecast computes features from current ticks. Historical windows overlap; repeated test scores are not independent experiments.

## Interpreting results

Scores are uncalibrated model estimates, not verified win probabilities. Forward accuracy is filtered by mode and barrier. Uniform-digit reference rates are 10% for Matches, 50% for parity, `(9 - barrier) / 10` for Over, and `barrier / 10` for Under. These are reference assumptions, not claims about market behavior.

The app has a forward paper simulator using user-entered payouts, not a payout-aware historical backtest or broker reconciliation. There is no evidence of positive expected trading returns. Next-tick forecast observations and delayed paper results are separate measurements.

## Paper trading

1. Choose Matches, Even/Odd, Over or Under (and its barrier) on **Radar**.
2. Open **Paper** and select a market. Review the stake, assumed gross return multiplier, entry delay, duration in ticks, and entry validity window.
3. Press **START PAPER**. Automatic scanning must also be enabled, or issue a forecast manually in Analyzer.
4. Review the available balance, reserved stake, simulated P/L, realized drawdown, and per-setup breakdown.

Paper trading starts disabled after every restart. The starting paper balance is 100 USD. The default 9.24× gross return is an illustrative assumption based on the supplied video, not a broker quote or a suggested payout for other contracts. Saving/starting applies assumptions only to the selected market and condition. Other signals are still recorded, with paper entries marked skipped. Existing records retain their original assumptions when settings change.

Entry occurs on the first received live tick after the configured delay, within the validity window. Settlement occurs after the specified number of subsequent received ticks; a one-tick trade never settles on its entry tick. The first subsequent tick after signal issuance independently determines next-tick forecast accuracy. Receipt times are device UTC timestamps; this model does not reproduce broker processing, network latency, unavailable quotes or slippage.

Only one paper trade can be waiting/open at a time, and its stake is reserved immediately. Insufficient balance blocks a new entry without dropping the signal. **STOP ENTRIES** cancels waiting entries and blocks new ones; open paper trades continue on an uninterrupted feed. Feed gaps, app pauses and restarts mark open trades unresolved and keep their stakes reserved. The Paper page allows an explicit conservative full-loss booking; this is labelled `assumed_lost`, not an observed settlement. Unresolved trades are excluded from realized drawdown and remain visible separately.

## Signal ledger and export

**Ledger** shows every issued forecast, including pending, incorrect, missed, expired and cancelled records, plus skipped/waiting/open/settled/unresolved paper entries. Filter by market, condition/barrier, forecast outcome and paper status. The screen paginates 30 records; **EXPORT ALL CSV** exports the entire ledger through the native share/save sheet, regardless of screen filters.

An append-only `signal-ledger-v1.jsonl` file lives in application support storage. Issuance snapshots are queued before later outcome snapshots; serialized writes are flushed to disk. Original issue fields and settings remain unchanged, and no 300-record pruning occurs. Restart recovery marks incomplete records rather than assuming missing ticks. An incomplete final write is backed up and repaired; corruption inside the file blocks new scanning with a visible storage error. Export flushes pending writes first. Keep exported backups: app-data clearing/uninstallation removes local data. Storage and replay memory grow with usage; the log is not encrypted or tamper-proof.

The previous `v14_results` preferences are preserved but excluded: they lack issuance, expiry and execution metadata, so they cannot be presented as complete ledger records.

Performance is grouped by market, condition, duration, delay, payout and stake. Approximate Wilson 95% intervals accompany next-tick accuracy; these intervals assume independent observations, while shared ticks and overlapping windows can be dependent. Uniform-digit rates are reference assumptions, not proven market probabilities.

## Market dashboard

Radar provides compact cards, pinned markets, a ready-market filter, recent digit strips, issue/source timestamps and explicit collection/readiness/forecast states. Scores are labelled uncalibrated. The analysis scan timer is not a contract-entry guarantee.

## Previous versions

`archive/` preserves the previous sources, ZIPs, and documentation as reference material. Older Dart files are stored as `.dart.txt` so Flutter does not analyze or execute them. The preexisting V13 working file was preserved before changes. The former uppercase `Lib/Main.dart` index entry was a separate conflicting source and has also been preserved as text.

Legacy V11 demo-order code is not part of the runnable app. Its volatile session limits and missing open-contract recovery are not suitable for reuse. Enabling broker orders would require a separately implemented and tested authenticated execution service with persistent limits and reconciliation. The current app has no order path, so it cannot submit or lose track of broker trades.
