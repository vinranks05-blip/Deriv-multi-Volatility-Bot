import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

void main() => runApp(const MaterialApp(
  debugShowCheckedModeBanner: false,
  home: TradingScreen(),
));

class TickSample {
  final int epoch, digit;
  final double quote;
  const TickSample(this.epoch, this.digit, this.quote);
}

class Prediction {
  final String market, mode;
  final int digit, start, target;
  final double? agreement;
  int? actual;
  bool? won;
  Prediction(this.market, this.mode, this.digit, this.start, this.target,
      this.agreement);
}

class DerivClient {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _heartbeat;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _id = 0;
  bool connected = false;
  void Function(String)? onDisconnect;

  Future<String> connectDemo(String appId, String pat) async {
    await close();
    final headers = {'Authorization': 'Bearer $pat', 'Deriv-App-ID': appId};
    final accountsResponse = await http.get(
      Uri.parse('https://api.derivws.com/trading/v1/options/accounts'),
      headers: headers,
    ).timeout(const Duration(seconds: 20));
    if (accountsResponse.statusCode != 200) {
      throw StateError('Accounts HTTP ${accountsResponse.statusCode}');
    }
    final root = jsonDecode(accountsResponse.body) as Map<String, dynamic>;
    final data = root['data'];
    final List<dynamic> accounts = data is List
        ? data
        : data is Map && data['accounts'] is List
            ? data['accounts'] as List
            : <dynamic>[];
    Map<String, dynamic>? demo;
    for (final item in accounts) {
      if (item is Map &&
          item['account_type']?.toString().toLowerCase() == 'demo') {
        demo = Map<String, dynamic>.from(item);
        break;
      }
    }
    if (demo == null) throw StateError('No demo Options account found');
    final accountId = (demo['account_id'] ?? demo['id'])?.toString();
    if (accountId == null || accountId.isEmpty) {
      throw StateError('Demo account ID missing');
    }
    final otpResponse = await http.post(
      Uri.parse('https://api.derivws.com/trading/v1/options/accounts/'
          '${Uri.encodeComponent(accountId)}/otp'),
      headers: headers,
    ).timeout(const Duration(seconds: 20));
    if (otpResponse.statusCode != 200) {
      throw StateError('OTP HTTP ${otpResponse.statusCode}');
    }
    final otp = jsonDecode(otpResponse.body) as Map<String, dynamic>;
    final otpData = otp['data'];
    final url = otpData is Map ? otpData['url']?.toString() : null;
    if (url == null) throw StateError('OTP URL missing');
    final uri = Uri.parse(url);
    if (uri.scheme != 'wss' || uri.host != 'api.derivws.com' ||
        uri.path != '/trading/v1/options/ws/demo') {
      throw StateError('Unexpected WebSocket URL; demo only');
    }
    try {
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready.timeout(const Duration(seconds: 15));
      connected = true;
      _subscription = _channel!.stream.listen((event) {
        try {
          final message = jsonDecode(event as String) as Map<String, dynamic>;
          final id = int.tryParse('${message['req_id']}');
          final waiter = id == null ? null : _pending.remove(id);
          if (waiter != null && !waiter.isCompleted) {
            if (message['error'] != null) {
              waiter.completeError(StateError('${message['error']}'));
            } else {
              waiter.complete(message);
            }
          }
        } catch (_) {}
      }, onError: (Object e) => _lost('Socket error'),
          onDone: () => _lost('Socket closed'));
      _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
        if (connected) {
          call({'ping': 1}).catchError((Object e) {
            _lost('Heartbeat failed');
            return <String, dynamic>{};
          });
        }
      });
      return accountId;
    } catch (_) {
      await close();
      rethrow;
    }
  }

  void _lost(String reason) {
    if (!connected) return;
    connected = false;
    _heartbeat?.cancel();
    _fail(StateError(reason));
    onDisconnect?.call(reason);
  }

  void _fail(Object error) {
    for (final waiter in _pending.values) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _pending.clear();
  }

  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async {
    if (!connected || _channel == null) throw StateError('Not connected');
    final id = ++_id;
    final waiter = Completer<Map<String, dynamic>>();
    _pending[id] = waiter;
    try {
      _channel!.sink.add(jsonEncode({...request, 'req_id': id}));
      return await waiter.future.timeout(const Duration(seconds: 20));
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> close() async {
    connected = false;
    _heartbeat?.cancel();
    _heartbeat = null;
    _fail(StateError('Disconnected'));
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
  }
}

class TradingScreen extends StatefulWidget {
  const TradingScreen({super.key});
  @override
  State<TradingScreen> createState() => _TradingScreenState();
}

class _TradingScreenState extends State<TradingScreen>
    with WidgetsBindingObserver {
  static const markets = ['R_10', 'R_25', 'R_50', 'R_75', 'R_100'];
  static const purple = Color(0xFF7135D5);
  static const blue = Color(0xFF1958E9);
  static const modes = ['Even', 'Odd', 'Over', 'Under', 'Matches', 'Differs'];
  final storage = const FlutterSecureStorage();
  final appId = TextEditingController();
  final pat = TextEditingController();
  final client = DerivClient();
  final List<Prediction> records = [];
  List<TickSample> ticks = [];
  String market = 'R_50';
  String mode = 'Matches';
  String status = 'Disconnected';
  String account = '';
  int tab = 0;
  int precision = 2;
  int remaining = 0;
  int generation = 0;
  bool connecting = false;
  bool loading = false;
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
      if (mounted) setState(() {
        active = null;
        remaining = 0;
        status = 'Disconnected: $reason';
      });
    };
  }

  Future<void> _restore() async {
    try {
      final saved = await storage.read(key: 'appId') ?? '';
      if (mounted) setState(() => appId.text = saved);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      generation++;
      countdown?.cancel();
      if (mounted) setState(() {
        active = null;
        remaining = 0;
        status = 'Paused in background; prediction not counted';
      });
    }
  }

  Future<void> connect() async {
    if (connecting) return;
    if (appId.text.trim().isEmpty || pat.text.trim().isEmpty) {
      setState(() => status = 'Enter App ID and PAT in Settings');
      return;
    }
    setState(() {
      connecting = true;
      status = 'Connecting to demo...';
    });
    try {
      await storage.write(key: 'appId', value: appId.text.trim());
      final id = await client.connectDemo(appId.text.trim(), pat.text.trim());
      if (!mounted) return;
      setState(() {
        account = id;
        status = 'Demo connected';
      });
      await refresh();
    } catch (e) {
      if (mounted) setState(() => status = 'Connection failed: $e');
    } finally {
      if (mounted) setState(() => connecting = false);
    }
  }

  Future<void> disconnect() async {
    generation++;
    countdown?.cancel();
    await client.close();
    if (mounted) setState(() {
      account = '';
      active = null;
      remaining = 0;
      status = 'Disconnected';
    });
  }

  int digitOf(dynamic raw, int places) {
    final value = double.tryParse(raw.toString());
    if (value == null || !value.isFinite) throw FormatException('Invalid quote');
    final fixed = value.toStringAsFixed(places);
    return int.parse(fixed.substring(fixed.length - 1));
  }

  Future<List<TickSample>> history({int count = 1000, int? start}) async {
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
    final response = await client.call(request);
    final data = response['history'];
    if (data is! Map || data['prices'] is! List || data['times'] is! List) {
      throw StateError('Tick history unavailable');
    }
    final prices = data['prices'] as List;
    final times = data['times'] as List;
    final samples = <TickSample>[];
    for (var i = 0; i < min(prices.length, times.length); i++) {
      final epoch = int.tryParse('${times[i]}');
      final quote = double.tryParse('${prices[i]}');
      if (epoch != null && quote != null) {
        samples.add(TickSample(epoch, digitOf(prices[i], precision), quote));
      }
    }
    samples.sort((a, b) => a.epoch.compareTo(b.epoch));
    return samples;
  }

  Future<void> refresh() async {
    if (!client.connected || loading) return;
    final selectedMarket = market;
    setState(() {
      loading = true;
      status = 'Refreshing $market live history...';
    });
    try {
      // active_symbols brief does not accept product_type.
      final response = await client.call({'active_symbols': 'brief'});
      final symbols = response['active_symbols'];
      if (symbols is List) {
        for (final item in symbols) {
          if (item is Map && item['symbol'] == selectedMarket) {
            final pip = double.tryParse('${item['pip']}');
            if (pip != null && pip > 0) {
              final parts = pip.toString().split('.');
              precision = parts.length == 2 ? parts.last.length : 0;
            }
            break;
          }
        }
      }
      final result = await history();
      if (!mounted || selectedMarket != market) return;
      if (result.length < 250) throw StateError('Insufficient tick history');
      setState(() {
        ticks = result;
        status = 'Loaded ${ticks.length} $market ticks • demo connected';
      });
    } catch (e) {
      if (mounted) setState(() => status = 'Refresh failed: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  bool resultFor(String selected, int prediction, int actual) {
    switch (selected) {
      case 'Even': return actual.isEven;
      case 'Odd': return actual.isOdd;
      case 'Over': return actual > prediction;
      case 'Under': return actual < prediction;
      case 'Matches': return actual == prediction;
      case 'Differs': return actual != prediction;
      default: return false;
    }
  }

  int chooseDigit(List<TickSample> samples, String selected) {
    final frequency = List<int>.filled(10, 0);
    for (final tick in samples.skip(max(0, samples.length - 250))) {
      frequency[tick.digit]++;
    }
    if (selected == 'Even' || selected == 'Odd') {
      return selected == 'Even' ? 0 : 1;
    }
    if (selected == 'Over') return 4;
    if (selected == 'Under') return 5;
    final digits = List<int>.generate(10, (i) => i);
    digits.sort((a, b) => selected == 'Matches'
        ? frequency[b].compareTo(frequency[a])
        : frequency[a].compareTo(frequency[b]));
    return digits.first;
  }

  double? historicalAgreement(List<TickSample> samples, String selected,
      int digit) {
    // Backtest at 10-second horizons using non-overlapping historical windows.
    if (samples.length < 250) return null;
    var wins = 0;
    var total = 0;
    final start = max(0, samples.length - 900);
    for (var i = start + 100; i < samples.length - 1; i += 10) {
      final target = samples[i].epoch + 10;
      TickSample? actual;
      for (var j = i + 1; j < samples.length; j++) {
        if (samples[j].epoch >= target) {
          actual = samples[j];
          break;
        }
      }
      if (actual == null) continue;
      final past = samples.sublist(max(0, i - 100), i + 1);
      final predicted = chooseDigit(past, selected);
      if (resultFor(selected, predicted, actual.digit)) wins++;
      total++;
    }
    if (total == 0) return null;
    return wins * 100 / total;
  }

  Future<void> predict(String selected) async {
    if (!client.connected) {
      setState(() => status = 'Connect DEMO in Settings first');
      return;
    }
    if (active != null || loading) return;
    setState(() => mode = selected);
    await refresh();
    if (!mounted || !client.connected || ticks.length < 250) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final latest = ticks.last;
    if (now - latest.epoch > 15) {
      setState(() => status = 'Tick history stale; prediction cancelled');
      return;
    }
    final digit = chooseDigit(ticks, selected);
    final agreement = historicalAgreement(ticks, selected, digit);
    final prediction = Prediction(market, selected, digit, now, now + 10,
        agreement);
    final id = ++generation;
    setState(() {
      active = prediction;
      remaining = 10;
      tab = 2;
      status = 'Prediction active • waiting 10 seconds';
    });
    countdown?.cancel();
    countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || id != generation) {
        timer.cancel();
        return;
      }
      final left = max(0, prediction.target -
          DateTime.now().millisecondsSinceEpoch ~/ 1000);
      setState(() => remaining = left);
      if (left == 0) {
        timer.cancel();
        settle(prediction, id);
      }
    });
  }

  Future<void> settle(Prediction prediction, int id) async {
    if (!client.connected || id != generation) return;
    try {
      TickSample? actual;
      for (var attempt = 0; attempt < 6 && actual == null; attempt++) {
        final result = await history(start: prediction.start);
        for (final tick in result) {
          if (tick.epoch >= prediction.target) {
            actual = tick;
            break;
          }
        }
        if (actual == null) await Future.delayed(const Duration(seconds: 2));
      }
      if (!mounted || id != generation) return;
      if (actual == null) throw StateError('Expiry tick unavailable');
      prediction.actual = actual.digit;
      prediction.won = resultFor(prediction.mode, prediction.digit, actual.digit);
      setState(() {
        records.insert(0, prediction);
        active = null;
        status = 'Result: ${prediction.won! ? 'CORRECT' : 'INCORRECT'} • '
            'actual digit ${actual!.digit}';
      });
    } catch (e) {
      if (mounted && id == generation) setState(() {
        active = null;
        status = 'Settlement failed (not counted): $e';
      });
    }
  }

  Widget panel(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      boxShadow: const [BoxShadow(color: Color(0x18000000), blurRadius: 5)],
    ),
    child: child,
  );

  Widget tile(String name, Color color) => GestureDetector(
    onTap: () => predict(name),
    child: Container(
      alignment: Alignment.center,
      height: 78,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
        border: mode == name ? Border.all(color: Colors.black, width: 3) : null,
      ),
      child: Text(name, style: const TextStyle(
          color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
    ),
  );

  Widget analyzer() {
    final p = active;
    final agreement = p?.agreement;
    final values = ticks.skip(max(0, ticks.length - 40))
        .map((e) => e.quote).toList();
    final up = values.length > 1 && values.last >= values.first;
    return ListView(padding: const EdgeInsets.all(18), children: [
      Text('Loaded ${ticks.length} $market ticks • '
          '${client.connected ? 'live refresh available' : 'connect demo'}'),
      const SizedBox(height: 14),
      panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GridView.count(
          crossAxisCount: 2, shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12, mainAxisSpacing: 12,
          childAspectRatio: 2.3,
          children: [
            tile('Even', blue), tile('Odd', purple),
            tile('Over', const Color(0xFF078B4D)),
            tile('Under', const Color(0xFFDC2020)),
            tile('Matches', blue), tile('Differs', purple),
          ],
        ),
      ])),
      const SizedBox(height: 18),
      panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Expert Analysis Tool', style: TextStyle(
            fontSize: 23, fontWeight: FontWeight.bold)),
        const SizedBox(height: 14),
        const Text('QUICK STRATEGY • LIVE MARKET ANALYSIS',
            style: TextStyle(color: purple, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Market: $market • ${client.connected ? 'Demo connected' : 'Disconnected'}'),
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          Expanded(child: tile(mode, blue)),
          const SizedBox(width: 12),
          CircleAvatar(radius: 46, backgroundColor: purple,
            child: Text(p == null ? '–' : '${p.digit}',
              style: const TextStyle(color: Colors.white,
                  fontSize: 44, fontWeight: FontWeight.bold))),
          const SizedBox(width: 12),
          Expanded(child: tile('Differs', blue)),
        ]),
        const SizedBox(height: 12),
        Center(child: Text(p == null ? status : 'Countdown: $remaining seconds')),
        const Divider(height: 32),
        const Text('CURRENT TREND', style: TextStyle(
            fontWeight: FontWeight.bold, color: Colors.black54)),
        Text(up ? 'Uptrend ↗' : 'Downtrend ↘',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        SizedBox(height: 100, width: double.infinity,
          child: CustomPaint(painter: TrendPainter(values, purple))),
        const Divider(height: 32),
        const Text('HISTORICAL AGREEMENT • NOT WIN PROBABILITY',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54)),
        const SizedBox(height: 8),
        Text(agreement == null ? 'Not calculated' : '${agreement.toStringAsFixed(1)}%',
            style: const TextStyle(color: purple, fontSize: 30,
                fontWeight: FontWeight.bold)),
        LinearProgressIndicator(value: agreement == null ? 0 : agreement / 100,
            minHeight: 10, borderRadius: BorderRadius.circular(10),
            color: purple, backgroundColor: const Color(0xFFECE1FA)),
        const SizedBox(height: 12),
        const Text('Agreement is a simple historical backtest. It does not '
            'predict future results or guarantee 90–100% accuracy.',
            style: TextStyle(fontSize: 12, color: Colors.black54)),
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: loading || !client.connected ? null : refresh,
          icon: const Icon(Icons.refresh), label: const Text('Refresh live market')),
      ])),
    ]);
  }

  Widget dashboard() => ListView(padding: const EdgeInsets.all(22), children: [
    const Text('Select volatility market', style: TextStyle(
        fontSize: 24, fontWeight: FontWeight.bold)),
    const SizedBox(height: 18),
    for (final symbol in markets) Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        title: Text(symbol, style: const TextStyle(fontSize: 20)),
        subtitle: Text(market == symbol ? 'Selected' : 'Tap to select'),
        trailing: market == symbol ? const Icon(Icons.check_circle,
            color: purple) : null,
        onTap: () {
          generation++;
          countdown?.cancel();
          setState(() {
            market = symbol;
            ticks = [];
            active = null;
            remaining = 0;
            status = 'Market selected: $symbol';
          });
          refresh();
        },
      )),
    ),
    Text(status),
    const SizedBox(height: 10),
    FilledButton(onPressed: client.connected && !loading ? refresh : null,
        child: const Text('Refresh selected market')),
  ]);

  Widget historyTab() => ListView(padding: const EdgeInsets.all(18), children: [
    Text('Prediction history • ${records.length} results',
        style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
    const SizedBox(height: 12),
    if (records.isEmpty) const Text('No completed predictions yet.'),
    for (final p in records) Card(child: ListTile(
      title: Text('${p.market} • ${p.mode} ${p.digit}'),
      subtitle: Text('Actual digit: ${p.actual ?? '-'} • '
          'Historical agreement: ${p.agreement?.toStringAsFixed(1) ?? '-'}%'),
      trailing: Icon(p.won == true ? Icons.check_circle : Icons.cancel,
          color: p.won == true ? Colors.green : Colors.red),
    )),
  ]);

  Widget settings() => ListView(padding: const EdgeInsets.all(24), children: [
    const Text('Deriv DEMO Connection', style: TextStyle(
        fontSize: 23, fontWeight: FontWeight.bold)),
    const SizedBox(height: 14),
    TextField(controller: appId, keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Deriv App ID')),
    TextField(controller: pat, obscureText: true,
        enableSuggestions: false, autocorrect: false,
        decoration: const InputDecoration(labelText: 'Deriv PAT (not saved)')),
    const SizedBox(height: 14),
    Wrap(spacing: 10, children: [
      FilledButton(onPressed: connecting || client.connected ? null : connect,
          child: const Text('Connect demo')),
      OutlinedButton(onPressed: client.connected ? disconnect : null,
          child: const Text('Disconnect')),
    ]),
    const SizedBox(height: 14),
    Text('Account: $account'),
    Text(status),
    const SizedBox(height: 18),
    const Text('DEMO ONLY • analysis and simulated prediction tracking. '
        'No purchases or automated trades. Keep the app in the foreground.'),
  ]);

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF3EDFF),
    appBar: AppBar(
      toolbarHeight: 88,
      backgroundColor: const Color(0xFFE0D2F2),
      title: const Text('V8 PRO • Expert Trader',
          style: TextStyle(fontSize: 22)),
      actions: [Padding(padding: const EdgeInsets.only(right: 16),
        child: Center(child: Text(client.connected ? '● DEMO' : '○ DEMO',
          style: TextStyle(color: client.connected ? Colors.green : Colors.grey,
              fontWeight: FontWeight.bold))))],
    ),
    body: IndexedStack(index: tab, children: [
      dashboard(), historyTab(), analyzer(), settings(),
    ]),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (value) => setState(() => tab = value),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.dashboard), label: 'Dashboard'),
        NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        NavigationDestination(icon: Icon(Icons.pin), label: 'Analyzer'),
        NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
      ],
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    generation++;
    countdown?.cancel();
    client.close();
    appId.dispose();
    pat.dispose();
    super.dispose();
  }
}

class TrendPainter extends CustomPainter {
  final List<double> values;
  final Color color;
  TrendPainter(this.values, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final low = values.reduce(min);
    final high = values.reduce(max);
    final span = max(high - low, 1e-10);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = size.height - 8 -
          (values[i] - low) / span * (size.height - 16);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke);
  }
  @override
  bool shouldRepaint(covariant TrendPainter oldDelegate) => true;
}
