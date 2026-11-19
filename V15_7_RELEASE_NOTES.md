# V15.7 — Live signal dashboard refresh

- Updated radar to resemble the provided dark trading-scanner reference, with a prominent validated-entry status panel.
- Shows active validated signals with digit and *uncalibrated model score*, plus number of markets analyzing.
- Shows time until next scan while waiting. It deliberately does not mislabel scan time as trade entry time.
- Market cards now distinguish analyzing from validated signals.
- Preserves V15.6 MATCH hold-out gating, ledger, paper-only controls, and all existing tests.
- Does not claim improved predictive accuracy, automatic profitable trading, or live broker execution.

## Verification
Flutter SDK is unavailable in this environment. Run `flutter pub get`, `flutter analyze`, `flutter test`, `flutter build apk --debug` through the existing GitHub Actions workflow.
