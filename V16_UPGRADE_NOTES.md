# V16.0 — Evidence Diagnostics Foundation

Based on the supplied V15.7.6 Android build fix. The existing dashboard, scanner and GitHub Actions build workflow are preserved.

## Added
- `lib/edge_diagnostics.dart`: one-sided conservative Wilson lower bound against a configurable null probability.
- Explicit break-even probability and expected net return per unit stake when a verified **net win profit** quote is supplied.
- Separate conservative payout screen: does not conflate accuracy with profitability.
- `test/edge_diagnostics_test.dart`: five regression cases.
- Version updated to 16.0.0+3.

## Limitations
- These diagnostics are a reusable foundation, **not yet wired to the dashboard or signal issuance**. Existing trading/signal behavior remains unchanged.
- Historical samples, repeated model selection and overlapping windows can invalidate naive significance interpretations.
- No claim of a proven trading advantage, production readiness, or successful APK compilation.
- Flutter/Dart toolchains are not installed in the authoring environment; run the GitHub workflow to validate the build and tests.
