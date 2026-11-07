import 'dart:async';
import 'dart:io';

import '../lib/deriv_v13_market_data.dart';

// Optional read-only integration check. No account token or orders are used.
Future<void> main() async {
  final data = V13MarketData();
  final errors = data.errors.listen((message) => stderr.writeln(message));
  final firstTick = data.ticks.first.timeout(const Duration(seconds: 25));
  data.watch('R_10');
  await data.connect();
  try {
    final tick = await firstTick;
    stdout.writeln('Received ${tick.symbol}: price=${tick.price}, '
        'precision=${tick.pipSize}, digit=${tick.lastDigit}');
  } catch (error) {
    stderr.writeln('Market feed check failed: $error');
    exitCode = 1;
  } finally {
    await errors.cancel();
    await data.dispose();
  }
}
