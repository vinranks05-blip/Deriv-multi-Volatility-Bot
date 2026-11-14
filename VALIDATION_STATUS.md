# V15.2 validation status

## Applied corrections
- Reject unknown symbol events before dashboard market lookup.
- Ignore stale socket messages after a reconnect generation changes.
- Prevent reconnect timers from reopening disposed/stale connections.
- Allow source-path verification in extracted ZIPs without `.git`.
- Synchronize the uploaded V15.2 regression test and accuracy gate.
- Set application version to 15.2.0+1.

## Not verified locally
Flutter and Dart SDK executables are not installed in this execution environment. Therefore `flutter analyze`, `flutter test`, and APK compilation have **not** been executed locally. GitHub Actions must pass all three before this package is considered build-verified. No prediction accuracy target is guaranteed.
