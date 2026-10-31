# V8 Expert Trader

Flutter Android demo-only market analyzer. UI follows supplied Expert Trader reference: header, Deriv Connector, market and contract controls, live price, six strategy buttons, AI Market Analyzer, confidence, pattern, digit countdown, and 0–9 digit distribution.

## Build without installing Flutter locally
1. Create a GitHub repository and upload the files in this folder, including `.github/workflows/build-apk.yml`.
2. Open **Actions** → **Build Deriv Android APK** → **Run workflow**.
3. Download **V8-Expert-Trader-APK** from the successful run's artifacts and install the APK.

The build workflow creates Android platform scaffolding on GitHub. No credentials are embedded. The app uses Deriv's public market tick WebSocket and does not place orders. Scores are descriptive, not predicted win probabilities.
