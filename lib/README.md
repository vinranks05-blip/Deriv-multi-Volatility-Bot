# V11 Expert Trader — Android Flutter source prototype

## What works
- Public Deriv WebSocket tick subscriptions for Volatility 10/25/50/75/100 and requested 1-second symbols (availability depends on Deriv).
- Reconnect with exponential backoff, stale feed detection, last-digit precision handling.
- Radar, Analyzer, Trades, History, Journal, Alerts and Settings pages.
- Matches / Even-Odd / Over-Under observation modes; 10-second scan cadence.
- Locally persisted observations and actual measured observation accuracy.
- Simple live tick chart and digit distribution.

## Important limitations
- This is **not** a production-ready trading bot or APK. It is a Flutter source prototype.
- The app uses **public** market data, not authenticated Deriv accounts. It does **not** place broker orders, and no demo or real-money trades are claimed.
- The prediction heuristic is historical digit frequency, not a validated predictive model. The displayed percentage is historical frequency, **not win confidence**.
- The 10-second timer is a scan timer, not a guaranteed contract entry time. Observations are compared to the first subsequent tick, not necessarily a 10-second settlement tick.
- Advanced EMA/RSI/MACD/ADX/ATR, closed-candle analysis, notifications, real order settlement, demo/real switching, true charting, and production-grade performance analytics require further implementation and validation.
- Symbols and pip precision must be verified against active symbols metadata for your Deriv account/region.

## Run
1. Install Flutter SDK and Android SDK.
2. `flutter create . --platforms android`
3. `flutter pub get`
4. `flutter run`

No personal access token is required for public tick subscriptions. Never paste a PAT into source code or public GitHub.
