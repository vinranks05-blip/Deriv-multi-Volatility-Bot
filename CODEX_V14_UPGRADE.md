# Codex Implementation Guide — Volatility Scanner V14

## Mission
Upgrade the existing **Flutter/Dart V13 Volatility Scanner** to **V14** in the current repository. Improve scientific validity, reliability, observability, and evaluation of next-tick digit forecasts. **Do not claim or target guaranteed 80–90% accuracy.** A model that cannot beat a simple baseline on untouched forward data must be labeled as such.

## Ground truth from V13 screenshots (observations, not acceptance targets)
- Public WebSocket live; 10/10 feeds; 49,429 ticks received.
- Even/Odd observed accuracy around 49.1–49.4% across ~871–891 observations; random uniform-digit baseline 50%.
- Softmax model: uncalibrated estimate 53.9%; final held-out test 45.0% on 240 ticks; fixed training baseline 49.6%.
- Forward Matches 8.9%; uniform-digit baseline 10%.
- Paper trading: $100 initial balance, $98.50 remaining, -$1.50 simulated P/L, $5.87 maximum realized drawdown, 32 outcomes.
- Ten tracked markets: R_10, R_25, R_50, R_75, R_100, 1HZ10V, 1HZ25V, 1HZ50V, 1HZ75V, 1HZ100V.
- V13 uses public data only, no PAT/account token and no broker execution. **Preserve this security boundary.**

## Operating instructions for Codex
1. Inspect repository structure, `pubspec.yaml`, Dart sources, tests, and GitHub Actions before editing. Determine the real entry point and current storage/connection/model architecture; do not assume filenames or invent existing APIs.
2. Work in small, testable changes. Keep existing screens and navigation: Radar, Analyzer, Paper, Ledger, Journal, Alerts, Settings, Logs. Preserve dark navy/cyan visual styling and existing user data.
3. Make a short implementation plan, then implement. Do not stop at mockups or pseudocode.
4. Do not replace working functionality with placeholders. Preserve offline handling, reconnection, live tick subscriptions, history, exports, and observation logs.
5. Use Dart/Flutter-compatible packages already present where practical. Add dependencies only when justified and update lockfiles.
6. Run `dart format`, `flutter analyze`, and `flutter test` where available; document any environment limitations and unresolved errors. Do not claim APK compilation without an actual successful build.

## Priority 1 — Data correctness and prediction timing
- Use the **exact symbol-specific pip precision** provided by the feed when extracting the last digit. Never rely on unformatted floating-point string representations.
- Keep independent timestamp-ordered streams and feature buffers per symbol. Handle duplicate, stale, missing, and out-of-order ticks. Log subscription gaps and reconnect events.
- Prevent future-data leakage: freeze feature state and forecast **before** the target tick arrives. Record source tick ID/epoch, issuance timestamp, target tick ID/epoch, forecast horizon, expiration, predicted class, confidence, model version, and actual outcome.
- A one-tick forecast must settle against the **first eligible subsequent tick of the same symbol**, not an arbitrary later tick. Expired/skipped/missed signals must remain visible and must not count as correct.
- On reconnect, do not silently pair old predictions with new ticks. Define and test a clear invalidation policy.
- Preserve distinction between market-data observations and broker-executed outcomes.

## Priority 2 — Baselines and leakage-safe ML
- Support four forecast conditions: **Matches, Even/Odd, Over, Under**. Clearly show digit/barrier definitions and their correct uniform-digit baselines. For Over barrier b, baseline is `(9-b)/10`; Under barrier b is `b/10`; Matches a specified digit is 10%; Even/Odd is 50%.
- Keep a simple baseline (uniform distribution and optionally empirical frequency) alongside existing softmax. Investigate other lightweight models only if they can be implemented, validated, and run efficiently on Android; avoid unjustified complex frameworks.
- For exact-digit forecasting, output a normalized probability distribution for digits 0–9 and the most likely digit. Derive condition probabilities from that distribution where appropriate; do not confuse a predicted digit with an Even/Odd forecast.
- Use chronological train/validation/test partitions. Fit scalers, transforms, feature selection, and hyperparameters on training data only. Choose models using validation only, then evaluate **once** on an untouched final test set.
- Add rolling walk-forward evaluation with strictly chronological, non-overlapping evaluation targets. Clearly distinguish rolling backtests from truly new live forward observations.
- Track sample size, class balance, hit rate, baseline delta, log loss, Brier score, and calibration by confidence bin. Provide uncertainty intervals where appropriate.
- Never interpret model score as a probability until calibrated on disjoint data and verified on held-out observations. Label raw scores **uncalibrated**.
- Include a no-signal/abstain option with a configurable confidence threshold. Report both **coverage** and **accuracy conditional on issued signals**; prevent cherry-picked performance claims.
- Record metrics per symbol and condition, plus aggregate results. Do not pool correlated overlapping observations as though independent.
- If no out-of-sample advantage exists, display **No demonstrated predictive edge** instead of increasing model confidence artificially.

## Priority 3 — Matches research
- Show exact predicted digit, predicted probability, observed frequency, sample count, and 10% baseline for each market.
- Analyze last-digit frequency, short-window transitions, lag features, and stability over time, but treat any apparent pattern as a hypothesis requiring independent testing.
- Evaluate Matches separately from Even/Odd, Over, and Under. Show rolling windows (last 50/100/300) and cumulative forward accuracy.
- Never optimize on the final test set or report training accuracy as live prediction accuracy.

## Priority 4 — Paper simulation and risk controls
- Keep **simulation only**; no authenticated account access, PAT collection, or real orders.
- Retain configured default stake $0.35 and allow user-adjustable assumptions; payouts are hypothetical, **not live broker quotes**.
- Simulate entry/exit on explicitly defined subsequent received ticks with configurable entry delay, entry window, and tick duration. Record missed entries, expiration, reserve/release, gross payout, net P/L, and drawdown.
- Ensure no double settlement, negative reserve, or duplicated trade after reconnect. Keep at most one active paper position if that is the existing design.
- Add configurable safeguards with suggested defaults: max 6 paper entries/session, stop after 2 consecutive losses, session P/L bounds -$1.00 to +$1.00, daily simulated loss limit $2.00. Make reset semantics explicit and persist them.
- Display paper win rate, expected net value under stated payout, realized net P/L, sample size, maximum drawdown, and break-even win rate. For gross return multiplier `m`, break-even hit rate is `1/m` before additional costs.
- Do not present high digit-prediction accuracy as proof of profitability.

## Priority 5 — Interface and diagnostics
- **Radar:** show next-tick predicted digit, condition, barrier, raw/calibrated confidence label, timestamp, expiration, live status, and no-signal state. Do not show contradictory digit and Even/Odd labels.
- **Analyzer:** per-market distribution 0–9, model vs baseline, held-out and live-forward results, confidence calibration, drift indicators, and sample sizes.
- **Ledger:** immutable signal lifecycle with filters for market, condition, forecast outcome, and paper status; preserve CSV export.
- **Journal:** distinguish observational accuracy from paper-trade P/L; preserve user notes.
- **Alerts:** configurable in-app observation notifications; avoid implying a profitable trade signal.
- **Logs:** socket lifecycle, per-symbol subscriptions, tick counts, model version, prediction/settlement events, and clear error diagnostics. Redact secrets if any exist in old code.
- **Settings:** model selection, window sizes, confidence threshold, paper assumptions, export/backup, and data retention controls.
- Keep screens responsive on small Android phones; prevent clipped labels and inaccessible bottom navigation.

## Persistence and migration
- Inspect the existing storage mechanism before changing schemas. Version records and provide a non-destructive migration path.
- Keep exported CSV backward-compatible where feasible; add explicit columns for model version, baseline, horizon, source/target tick, calibration status, and result.
- Preserve existing history and notes through upgrades. Do not wipe user data or reset performance metrics silently.

## Tests to add
1. Last-digit extraction for varying pip precision, trailing zeros, and floating-point edge cases.
2. All four contract-condition evaluations and baseline formulas, including barrier boundaries.
3. Forecast issued at tick N can only be evaluated on eligible tick N+1; no lookahead, duplicate settlement, or cross-symbol pairing.
4. Chronological splitting, scaler fitting only on training, and non-overlapping forward evaluations.
5. Probability normalization, calibration labels, and abstention/coverage accounting.
6. Reconnect handling, stale ticks, interrupted subscriptions, and persistence recovery.
7. Paper payout arithmetic, stake reservation, loss limits, session resets, and drawdown.
8. CSV export and migration retaining existing records.
9. Widget smoke tests for navigation and critical metrics.

## Definition of done
- Existing V13 functions and visual identity remain operational.
- All 10 markets subscribe and process independently, with reconnection diagnostics.
- V14 displays next-digit predictions and condition probabilities **without misleading confidence claims**.
- Historical test and forward accuracy are separated, with correct baselines and sample sizes.
- Matches and all other conditions have independently evaluated performance.
- Paper trading remains entirely simulated and risk-limited.
- Tests/analyzer pass, or any blockers are explicitly identified with logs.
- Provide a concise summary of changed files, architecture, metrics, test results, and known limitations.

## Final instruction
**Prioritize correctness and measurable evidence over a headline accuracy percentage.** If predictions remain at chance, say so plainly. Do not add real-money trading or token authentication as part of this upgrade.
