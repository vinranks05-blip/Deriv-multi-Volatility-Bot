# Deriv Multi-Volatility Android — Flutter source prototype

This is **source code, not an APK**. Flutter/Android build tooling is not installed in the creation environment, so no compiled APK or device/API compatibility test has been performed.

## Build
1. Install Flutter SDK and Android SDK on a development computer.
2. `flutter create --platforms=android .` from this folder (generates standard Android platform files).
3. `flutter pub get`
4. `flutter analyze` and fix any issues from your installed Flutter/package versions.
5. `flutter build apk --release` and install `build/app/outputs/flutter-apk/app-release.apk` on Android.

## Use
Register your own Deriv application ID and create an API token for the selected account. Do not share your token. Tokens are stored using flutter_secure_storage. Demo is selected by default. Real requires two confirmations (select real and start automatic trading); manual buys also require confirmation. Use signal-only mode first.

## Design and risk limitations
- Scans five standard symbols R_10/R_25/R_50/R_75/R_100 using 60-second candles; EMA9/EMA21, RSI14, three closed candles, normalized trend strength. One open trade at a time.
- $0.35 stake, five-minute Rise/Fall, max six trades, stop at two consecutive losses, session P/L <= -$0.35 or >= +$1.00. **These thresholds are not guaranteed maximum losses.** Session counters reset when the app is restarted; there is no daily persistent loss protection.
- Trading should only run while foregrounded. On pause, no new scan cycles are intended; already-purchased contracts cannot be canceled by Stop and may settle after the app is closed. Android OS may terminate network activity and settlement tracking; inspect account history before restarting.
- Real-money support is implemented as a *prototype account selector*, not verified against Deriv API; **do not use with actual funds without independent validation, tests, and stronger persistent risk controls**.
- There is no profitability guarantee; proposal/authorization/market API availability may change. This is not production-ready.
