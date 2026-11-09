# CODEX V14.1 — Matches Prediction Research & Reliability Upgrade

## Mission
Upgrade the existing Flutter/Dart Deriv **public-data-only** Volatility Scanner in place. Prioritize scientifically valid next-tick digit MATCHES evaluation, selective forecasting, reliable data handling, and transparent reporting. Do **not** promise 80–90% hit rates or manufacture a trading edge. Preserve the current UI and existing functionality unless a change is required for correctness.

## Observed starting point (screenshots, not verified source data)
- Ten live public volatility feeds; public endpoint without account token.
- Matches 9, ML softmax; uncalibrated estimate 13.8%; final historical test accuracy 12.7% over 221 ticks; fixed training baseline 13.6%; log loss 2.355; Brier 0.910; scan coverage 100% with zero abstentions; forward Matches 10.3%.
- Historical digit frequencies approximately 9–12%, not evidence of future predictability.
- Previous forward Matches reading 8.9%; different samples, so **do not** describe the difference as a proven improvement.
- Uniform random digit baseline for exact-match accuracy = 10%, assuming uniformly distributed digits. Compare against empirical frequency and recent-history baselines too.

## First: audit the repository
1. Inspect `pubspec.yaml`, `lib/`, `test/`, CI workflows, persistence, WebSocket subscriptions, scanner and paper-trading implementations. Do not assume file names, class names, architecture, or existing tests.
2. Summarize current prediction issuance, timestamping, target labeling, model training, splitting, calibration, forward scoring, and simulated execution.
3. Find any look-ahead leakage, overlapping target windows, future tick contamination, duplicated ticks, reconnect/history overlap, and accidental mixing of different markets or pip sizes.
4. Make incremental, compilable changes; do not replace the app with a prototype. Preserve 10 market feeds, radar, analyzer, journal, signal ledger, alerts, paper mode, CSV export, and local storage.

## Data integrity and label semantics — mandatory
- Use the Deriv quote as received and its **symbol-specific pip size** to extract the final digit; never derive it from binary floating-point string artifacts or an arbitrary decimal count.
- Record symbol, quote, pip size, broker tick epoch, local receipt time, connection generation, source tick ID where available, and strictly increasing per-symbol sequence number.
- A prediction must be immutable and issued using information available **before** its target tick. Target is the first *new* tick of the same symbol after issuance (or mark as expired/missed according to explicit policy). Never retroactively choose a favorable target.
- Ensure at-most-once resolution; no duplicated labels after reconnect or historical backfill. Do not count backfilled historical ticks as forward predictions.
- Keep each market's stream and training state separate. History is for training/evaluation only, not retroactive forward wins.
- Handle dropped ticks, nonmonotonic epochs, gaps, app suspension, reconnection and feed staleness; log exclusions with reason.

## Baselines before complex models
Implement reproducible baselines:
- Uniform 10-way distribution (10% exact-match probability).
- Most-frequent digit in training window (train-only).
- Rolling frequency distribution with Laplace smoothing (train-only).
- First-order Markov transitions with smoothing (train-only).
- Existing softmax model.

Only if baselines are implemented and evaluated correctly, test additional lightweight on-device candidate models (e.g. regularized multinomial logistic regression, shallow tree/gradient model if supported, or compact temporal model) without adding heavy dependencies by default. All model selection must be on validation data only. If a complex model fails to beat baselines out-of-sample, keep the simpler model or abstain.

## Features and leakage prevention
Candidate features: prior 10/20/50/100 digits, rolling per-digit frequencies, transitions, run lengths, entropy, interarrival times when meaningful, and past-only price changes. Features must be constructed with strictly past ticks. Test feature ablations. Avoid claiming synthetic volatility price indicators (RSI, MACD, etc.) can predict next digits without supporting evidence.

## Evaluation protocol
1. Use chronological train / validation / untouched final test splits per symbol; never shuffle time series.
2. Use expanding-window walk-forward validation with purge/embargo where feature or label windows overlap. Fit preprocessing and calibration on training/validation only.
3. Freeze candidate/model/hyperparameters before final test. Do not repeatedly tune on final test.
4. Report sample size, per-market counts, exact-match accuracy, top-2/top-3 accuracy (diagnostic only), log loss, multiclass Brier, calibration error/reliability bins, and confidence intervals.
5. Compare paired forecasts against uniform and frequency baselines on the **same** ticks. Use a suitable paired/bootstrap or exact test, noting serial dependence and multiple-comparison correction across markets/models/thresholds.
6. Report forward results separately from historical tests, with no overlap and clear collection start/end dates.
7. Show both per-market metrics and pooled metrics; do not let pooling mask weak markets.
8. Do not claim a statistically credible edge based on 221 historical ticks or a small difference from 10%.
9. Define Brier score convention explicitly (sum over 10 classes versus average); for uniform 10-class forecasts, summed multiclass Brier is 0.9. Uniform log loss is ln(10) ≈ 2.302585.

## Selective forecasting / abstention
- Calculate calibrated P(next digit = d) for all digits, select the top digit, and show probability only if calibration passes.
- Add configurable thresholds for confidence, model-vs-baseline margin, data freshness, minimum sample size, and drift. Defaults should be conservative and **do not imply** profitable signals.
- When conditions fail, display `NO SIGNAL — INSUFFICIENT EVIDENCE` or `WAITING FOR DATA`; do not force a prediction.
- Show coverage, selective accuracy, abstention count/reasons, and full-coverage baseline on identical evaluation periods. Prevent cherry-picking by choosing thresholds only on validation data.
- Preserve audit records of every candidate, including abstentions and expired/missed forecasts.

## UI changes — minimal, consistent with existing dark theme
On Analyzer: chosen digit, model name/version, calibrated vs uncalibrated probability, baseline probability, evaluation window, sample size, test and forward metrics, coverage, status (`NO DEMONSTRATED EDGE` until supported). Add compact per-market comparison and an explanation of abstention.
On Radar: show `NEXT TICK MATCHES d` only when eligible; otherwise `NO SIGNAL`. Do not display model confidence as guaranteed success probability.
On Ledger: log model version, feature cutoff, prediction timestamp, target tick, digit, probabilities, eligibility, resolution, and exclusion reasons. CSV export includes these fields and schema version.
On Logs: provide connection, reconnect, data quality, training, and prediction diagnostics with no sensitive tokens.

## Paper trading safeguards
- Keep **simulation only**. Never introduce broker order placement or token authorization as part of this upgrade.
- Separate signal hit rate from net simulated P/L. Use actual broker quotes only if available; otherwise mark payouts as **user-entered assumptions**.
- Preserve realistic delayed entry, expiry, reserved stake, one open trade at a time, and risk limits. Never imply historical backtests are executable trades.
- Retain configurable limits (previous defaults: stake $0.35, max 6 trades, max 2 consecutive losses, session P/L bounds -$1 to +$1, daily loss cap $2) if present; do not silently loosen them.
- Show break-even win probability as `1 / gross payout multiplier` when payout multiplier includes returned stake; explain assumption.

## Testing and delivery acceptance
Add automated tests for:
- digit extraction across pip sizes and floating-point edge cases;
- strictly past-only features, correct chronological splits, no target leakage;
- duplicate/reordered/reconnected tick behavior and exact-once resolution;
- calibrated probabilities sum to one and remain in [0,1];
- uniform baseline metrics (accuracy ~10% expectation, log loss ln 10, summed Brier 0.9);
- abstention and threshold behavior, coverage accounting;
- CSV export, schema migration, persistence and no token leakage;
- paper simulation timing, risk gates, and accounting.

Run `dart format`, `flutter analyze`, `flutter test`, and available build/CI checks. If environment lacks Flutter, say so and provide exact commands without claiming tests passed. Do not delete existing tests. Ensure Android build compatibility.

## Codex execution plan
1. Audit repository and list defects with file paths and line references.
2. Implement tick integrity and deterministic target resolution first.
3. Implement baselines and leakage-safe chronological evaluation.
4. Implement calibrated model selection and abstention.
5. Wire minimal UI and export changes.
6. Add tests and run checks.
7. Deliver a concise change log, files modified, tests run/pass/fail, per-market evaluation table, and known limitations.

## Non-negotiable reporting
- Never hardcode or fabricate accuracy figures or backtest results.
- If no out-of-sample edge is demonstrated, show that prominently and default to no signal rather than presenting a misleading confident prediction.
- Do not use test data to choose model, features, market, or threshold.
- Do not claim 80–90% Matches accuracy is achievable without independent evidence.
- Do not change GitHub visibility, upload credentials, or perform live trading.

## Prompt to Codex
Read `CODEX_V14_1_MATCHES_UPGRADE.md` completely. Audit the existing Flutter repository, then implement V14.1 incrementally. Preserve current UI and public-data-only design. Prioritize leak-free next-tick labeling, proper chronological out-of-sample testing, baseline comparisons, calibrated probabilities, selective predictions with abstention, and comprehensive tests. Report measured results honestly and provide an implementation summary with exact files changed and commands executed.
