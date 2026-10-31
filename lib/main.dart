import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

void main() => runApp(
  const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: TradingScreen(),
  ),
);

class DerivClient {
  WebSocketChannel? channel;
  StreamSubscription? subscription;
  Timer? heartbeat;

  final pending = <int, Completer<Map<String, dynamic>>>{};
  int nextId = 0;
  bool connected = false;
  void Function(String)? onDisconnect;

  Future<String> connectDemo(String appId, String pat) async {
    await close();

    final headers = {
      'Authorization': 'Bearer $pat',
      'Deriv-App-ID': appId,
    };

    final response = await http.get(
      Uri.parse(
        'https://api.derivws.com/trading/v1/options/accounts',
      ),
      headers: headers,
    ).timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw StateError(
        'Accounts HTTP ${response.statusCode}',
      );
    }

    final root =
        jsonDecode(response.body) as Map<String, dynamic>;
    final data = root['data'];

    final List<dynamic> accounts = data is List
        ? data
        : data is Map && data['accounts'] is List
            ? data['accounts'] as List
            : <dynamic>[];

    Map<String, dynamic>? demo;

    for (final item in accounts) {
      if (item is Map &&
          item['account_type']
                  ?.toString()
                  .toLowerCase() ==
              'demo') {
        demo = Map<String, dynamic>.from(item);
        break;
      }
    }

    if (demo == null) {
      throw StateError('No demo Options account found');
    }

    final accountId =
        (demo['account_id'] ?? demo['id'])?.toString();

    if (accountId == null || accountId.isEmpty) {
      throw StateError('Demo account ID missing');
    }

    final otp = await http.post(
      Uri.parse(
        'https://api.derivws.com/trading/v1/options/'
        'accounts/${Uri.encodeComponent(accountId)}/otp',
      ),
      headers: headers,
    ).timeout(const Duration(seconds: 20));

    if (otp.statusCode != 200) {
      throw StateError('OTP HTTP ${otp.statusCode}');
    }

    final otpData =
        (jsonDecode(otp.body) as Map<String, dynamic>)['data'];

    final url =
        otpData is Map ? otpData['url']?.toString() : null;

    if (url == null || url.isEmpty) {
      throw StateError('OTP URL missing');
    }

    final uri = Uri.parse(url);

    if (uri.scheme != 'wss' ||
        uri.host != 'api.derivws.com' ||
        uri.path != '/trading/v1/options/ws/demo') {
      throw StateError(
        'Unexpected non-demo WebSocket URL',
      );
    }

    try {
      channel = WebSocketChannel.connect(uri);

      await channel!.ready.timeout(
        const Duration(seconds: 15),
      );

      connected = true;

      subscription = channel!.stream.listen(
        (event) {
          try {
            final msg =
                jsonDecode(event as String)
                    as Map<String, dynamic>;

            final id =
                int.tryParse('${msg['req_id']}');

            final waiter =
                id == null ? null : pending.remove(id);

            if (waiter != null &&
                !waiter.isCompleted) {
              if (msg['error'] != null) {
                waiter.completeError(
                  StateError('${msg['error']}'),
                );
              } else {
                waiter.complete(msg);
              }
            }
          } catch (_) {}
        },
        onError: (Object e) =>
            _lost('Connection error'),
        onDone: () =>
            _lost('Connection closed'),
      );

      heartbeat = Timer.periodic(
        const Duration(seconds: 30),
        (_) {
          if (connected) {
            call({'ping': 1}).catchError(
              (Object e) {
                _lost('Heartbeat failed');
                return <String, dynamic>{};
              },
            );
          }
        },
      );

      return accountId;
    } catch (_) {
      await close();
      rethrow;
    }
  }

  void _lost(String reason) {
    if (!connected) return;

    connected = false;
    heartbeat?.cancel();
    _fail(StateError(reason));
    onDisconnect?.call(reason);
  }

  void _fail(Object error) {
    for (final waiter in pending.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(error);
      }
    }
    pending.clear();
  }

  Future<Map<String, dynamic>> call(
    Map<String, dynamic> payload,
  ) async {
    if (!connected || channel == null) {
      throw StateError('Not connected');
    }

    final id = ++nextId;
    final waiter =
        Completer<Map<String, dynamic>>();

    pending[id] = waiter;

    try {
      channel!.sink.add(
        jsonEncode({...payload, 'req_id': id}),
      );

      return await waiter.future.timeout(
        const Duration(seconds: 20),
      );
    } finally {
      pending.remove(id);
    }
  }

  Future<void> close() async {
    connected = false;
    heartbeat?.cancel();
    heartbeat = null;
    _fail(StateError('Disconnected'));

    await subscription?.cancel();
    subscription = null;

    await channel?.sink.close();
    channel = null;
  }
}

class TickSample {
  final int epoch;
  final int digit;
  final double quote;

  TickSample(
    this.epoch,
    this.digit,
    this.quote,
  );
}

class Prediction {
  final String market;
  final String mode;
  final int digit;
  final int started;
  final int target;
  final double estimate;
  final int sampleSize;

  int? actual;
  bool? won;

  Prediction(
    this.market,
    this.mode,
    this.digit,
    this.started,
    this.target,
    this.estimate,
    this.sampleSize,
  );
}

class TradingScreen extends StatefulWidget {
  const TradingScreen({super.key});

  @override
  State<TradingScreen> createState() =>
      _TradingScreenState();
}

class _TradingScreenState
    extends State<TradingScreen>
    with WidgetsBindingObserver {
  static const markets = [
    'R_10',
    'R_25',
    'R_50',
    'R_75',
    'R_100',
  ];

  static const purple = Color(0xFF7135D5);
  static const blue = Color(0xFF1859E9);

  final storage =
      const FlutterSecureStorage();

  final appId = TextEditingController();
  final pat = TextEditingController();

  final client = DerivClient();
  final records = <Prediction>[];

  List<TickSample> ticks = [];

  String market = 'R_50';
  String mode = 'Matches';
  String status = 'Disconnected';
  String account = '';

  int tab = 2;
  int remaining = 0;
  int precision = 2;
  int generation = 0;
  int backtestSamples = 0;

  double? analysisConfidence;

  String analysisDetail =
      'Awaiting analysis';

  bool connecting = false;
  bool loading = false;
  bool lastRefreshOk = false;

  Prediction? active;
  Timer? countdown;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    _restore();

    client.onDisconnect = (reason) {
      generation++;
      countdown?.cancel();

      if (mounted) {
        setState(() {
          status = 'Disconnected: $reason';
          remaining = 0;
          active = null;
        });
      }
    };
  }

  Future<void> _restore() async {
    final saved =
        await storage.read(key: 'appId') ?? '';

    if (mounted) {
      setState(() => appId.text = saved);
    }
  }

  @override
  void didChangeAppLifecycleState(
    AppLifecycleState state,
  ) {
    if (state != AppLifecycleState.resumed) {
      generation++;
      countdown?.cancel();

      if (mounted) {
        setState(() {
          active = null;
          remaining = 0;
          status =
              'Paused: app backgrounded; prediction not counted';
        });
      }
    }
  }

  Future<void> connect() async {
    if (connecting) return;

    if (appId.text.trim().isEmpty ||
        pat.text.trim().isEmpty) {
      setState(
        () => status =
            'Enter App ID and PAT in Settings',
      );
      return;
    }

    setState(() {
      connecting = true;
      status = 'Connecting to DEMO…';
    });

    try {
      await storage.write(
        key: 'appId',
        value: appId.text.trim(),
      );

      final demoAccount =
          await client.connectDemo(
        appId.text.trim(),
        pat.text.trim(),
      );

      if (!mounted) return;

      setState(() {
        account = demoAccount;
        status = 'Demo connected';
      });

      await refresh();
    } catch (e) {
      if (mounted) {
        setState(
          () => status = 'Connection failed: $e',
        );
      }
    } finally {
      if (mounted) {
        setState(() => connecting = false);
      }
    }
  }

  Future<void> disconnect() async {
    generation++;
    countdown?.cancel();

    await client.close();

    if (mounted) {
      setState(() {
        account = '';
        active = null;
        remaining = 0;
        status = 'Disconnected';
      });
    }
  }

  int digitOf(dynamic raw, int places) {
    final value =
        double.tryParse(raw.toString());

    if (value == null) {
      throw const FormatException(
        'Invalid quote',
      );
    }

    final fixed =
        value.toStringAsFixed(places);

    return int.parse(
      fixed.substring(fixed.length - 1),
    );
  }

  Future<List<TickSample>> history({
    int count = 1000,
    int? start,
  }) async {
    final request = <String, dynamic>{
      'ticks_history': market,
      'style': 'ticks',
      'end': 'latest',
      'count': count,
    };

    if (start != null) {
      request.remove('count');
      request['start'] = start;
    }

    final result =
        await client.call(request);

    final data = result['history'];

    if (data is! Map ||
        data['prices'] is! List ||
        data['times'] is! List) {
      throw StateError(
        'Missing tick history',
      );
    }

    final prices = data['prices'] as List;
    final times = data['times'] as List;

    final countAvailable =
        min(prices.length, times.length);

    final samples = <TickSample>[];

    for (var i = 0;
        i < countAvailable;
        i++) {
      final epoch =
          int.tryParse('${times[i]}');

      final quote =
          double.tryParse('${prices[i]}');

      if (epoch != null && quote != null) {
        samples.add(
          TickSample(
            epoch,
            digitOf(prices[i], precision),
            quote,
          ),
        );
      }
    }

    samples.sort(
      (a, b) =>
          a.epoch.compareTo(b.epoch),
    );

    return samples;
  }

  Future<void> refresh() async {
    if (!client.connected || loading) {
      return;
    }

    final requestedMarket = market;

    setState(() {
      loading = true;
      lastRefreshOk = false;
      status =
          'Refreshing $market live history…';
    });

    try {
      // Removed unsupported product_type field.
      final response =
          await client.call({
        'active_symbols': 'brief',
      });

      final symbols =
          response['active_symbols'];

      if (symbols is List) {
        for (final symbol in symbols) {
          if (symbol is Map &&
              symbol['symbol'] == market) {
            final pip =
                double.tryParse(
              '${symbol['pip']}',
            );

            if (pip != null && pip > 0) {
              final decimals =
                  pip.toString().split('.').last;

              precision =
                  decimals == '0'
                      ? 0
                      : decimals.length;
            }
            break;
          }
        }
      }

      final result = await history();

      if (result.length < 250) {
        throw StateError(
          'Insufficient ticks for analysis',
        );
      }

      if (mounted &&
          market == requestedMarket) {
        setState(() {
          ticks = result;
          lastRefreshOk = true;
          status =
              'Loaded ${result.length} $market ticks';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => status =
              'Refresh failed: $e',
        );
      }
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  int chooseDigit(
    List<TickSample> sample,
    String selected,
  ) {
    final frequency =
        List<int>.filled(10, 0);

    for (final tick in sample.skip(
      max(0, sample.length - 200),
    )) {
      frequency[tick.digit]++;
    }

    if (selected == 'Even' ||
        selected == 'Odd') {
      final allowed =
          selected == 'Even'
              ? [0, 2, 4, 6, 8]
              : [1, 3, 5, 7, 9];

      allowed.sort(
        (a, b) =>
            frequency[b].compareTo(
              frequency[a],
            ),
      );

      return allowed.first;
    }

    if (selected == 'Over') {
      return 5;
    }

    if (selected == 'Under') {
      return 4;
    }

    if (selected == 'Differs') {
      final digits =
          List<int>.generate(
        10,
        (i) => i,
      );

      digits.sort(
        (a, b) =>
            frequency[a].compareTo(
              frequency[b],
            ),
      );

      return digits.first;
    }

    final digits =
        List<int>.generate(
      10,
      (i) => i,
    );

    digits.sort(
      (a, b) =>
          frequency[b].compareTo(
            frequency[a],
          ),
    );

    return digits.first;
  }

  bool resultFor(
    String selected,
    int prediction,
    int actual,
  ) {
    switch (selected) {
      case 'Even':
        return actual.isEven;

      case 'Odd':
        return actual.isOdd;

      case 'Over':
        return actual > prediction;

      case 'Under':
        return actual < prediction;

      case 'Differs':
        return actual != prediction;

      default:
        return actual == prediction;
    }
  }

  double baseline(
    String selected,
    int digit,
  ) {
    switch (selected) {
      case 'Even':
      case 'Odd':
        return .5;

      case 'Over':
        return (9 - digit) / 10;

      case 'Under':
        return digit / 10;

      case 'Differs':
        return .9;

      default:
        return .1;
    }
  }

  // Walk-forward historical agreement.
  // This is not a validated future win probability.
  double? historicalAgreement(
    List<TickSample> sample,
    String selected,
  ) {
    if (sample.length < 250) {
      backtestSamples = 0;
      return null;
    }

    final start =
        max(200, sample.length - 400);

    var correct = 0;
    var total = 0;

    for (var i = start;
        i < sample.length;
        i++) {
      final prior =
          sample.sublist(0, i);

      final predicted =
          chooseDigit(prior, selected);

      if (resultFor(
        selected,
        predicted,
        sample[i].digit,
      )) {
        correct++;
      }

      total++;
    }

    backtestSamples = total;

    if (total == 0) {
      return null;
    }

    return 100.0 * correct / total;
  }

  Future<void> predict(
    String selected,
  ) async {
    if (!client.connected) {
      setState(
        () => status =
            'Connect DEMO in Settings first',
      );
      return;
    }

    if (active != null || loading) {
      return;
    }

    setState(() => mode = selected);

    await refresh();

    if (!mounted ||
        loading ||
        !client.connected ||
        !lastRefreshOk ||
        ticks.length < 250) {
      return;
    }

    final latest = ticks.last;

    final now =
        DateTime.now()
                .millisecondsSinceEpoch ~/
            1000;

    if (now - latest.epoch > 15) {
      setState(
        () => status =
            'Tick history stale; prediction cancelled',
      );
      return;
    }

    final digit =
        chooseDigit(ticks, selected);

    final confidence =
        historicalAgreement(
      ticks,
      selected,
    );

    if (confidence == null) {
      setState(
        () => status =
            'Not enough historical data',
      );
      return;
    }

    final prediction = Prediction(
      market,
      selected,
      digit,
      now,
      now + 10,
      confidence,
      backtestSamples,
    );

    final id = ++generation;

    setState(() {
      active = prediction;
      analysisConfidence = confidence;
      analysisDetail =
          'Historical agreement over '
          '$backtestSamples one-tick tests';
      remaining = 10;
      status =
          'Prediction active • 10-second countdown';
    });

    countdown?.cancel();

    countdown = Timer.periodic(
      const Duration(seconds: 1),
      (timer) {
        if (!mounted ||
            id != generation) {
          timer.cancel();
          return;
        }

        final current =
            DateTime.now()
                    .millisecondsSinceEpoch ~/
                1000;

        setState(() {
          remaining = max(
            0,
            prediction.target - current,
          );
        });

        if (remaining == 0) {
          timer.cancel();
          settle(prediction, id);
        }
      },
    );
  }

  Future<void> settle(
    Prediction prediction,
    int id,
  ) async {
    if (!client.connected) {
      if (mounted) {
        setState(() {
          active = null;
          status =
              'Connection lost; not counted';
        });
      }
      return;
    }

    try {
      TickSample? actual;

      for (var attempt = 0;
          attempt < 5 &&
              actual == null;
          attempt++) {
        if (market != prediction.market) {
          throw StateError(
            'Market changed',
          );
        }

        final result = await history(
          start: prediction.started,
        );

        for (final tick in result) {
          if (tick.epoch >=
              prediction.target) {
            actual = tick;
            break;
          }
        }

        if (actual == null) {
          await Future.delayed(
            const Duration(seconds: 2),
          );
        }
      }

      if (id != generation || !mounted) {
        return;
      }

      if (actual == null) {
        throw StateError(
          'Expiry tick unavailable',
        );
      }

      prediction.actual =
          actual.digit;

      prediction.won = resultFor(
        prediction.mode,
        prediction.digit,
        actual.digit,
      );

      setState(() {
        records.insert(
          0,
          prediction,
        );

        active = null;

        status =
            'Result: '
            '${prediction.won! ? 'CORRECT' : 'INCORRECT'}'
            ' • actual digit ${prediction.actual}';
      });
    } catch (e) {
      if (id == generation &&
          mounted) {
        setState(() {
          active = null;
          status =
              'Settlement failed (not counted): $e';
        });
      }
    }
  }

  Widget tile(
    String name,
    Color color,
  ) {
    final selected =
        mode == name;

    return GestureDetector(
      onTap: () => predict(name),
      child: Container(
        height: 78,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          borderRadius:
              BorderRadius.circular(18),
          border: selected
              ? Border.all(
                  color: Colors.black,
                  width: 3,
                )
              : null,
        ),
        child: Text(
          name,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }


Widget panel(Widget child) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(30),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.12),
          blurRadius: 5,
          offset: const Offset(0, 2),
        ),
      ],
    ),
    child: child,
  );
}
  
