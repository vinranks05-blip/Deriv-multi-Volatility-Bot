import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

void main() => runApp(const ScannerApp());

class ScannerApp extends StatelessWidget {
  const ScannerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'VOLATILITY V8 PRO',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF7239DC),
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: const Color(0xFFF5EDFF),
          cardTheme: CardThemeData(color: Colors.white, elevation: 2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
        ),
        home: const ScannerHome(),
      );
}

class Signal {
  final String symbol, side, reason;
  final double score, rsi, adx, atr;
  final int epoch;
  const Signal(this.symbol, this.side, this.reason, this.score, this.rsi,
      this.adx, this.atr, this.epoch);
}

class DigitStats {
  final String symbol;
  final List<int> counts;
  final int total, lastDigit;
  const DigitStats(this.symbol, this.counts, this.total, this.lastDigit);
  double frequency(int digit) => total == 0 ? 0 : counts[digit] * 100 / total;
  double get even => [0, 2, 4, 6, 8].fold<double>(0, (s, i) => s + frequency(i));
  double get odd => 100 - even;
}

class DerivClient {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _nextId = 0;
  bool connected = false;
  void Function(String)? onDisconnect;

  Future<String> connectDemo(String appId, String pat) async {
    await close();
    const base = 'https://api.derivws.com';
    final headers = {'Authorization': 'Bearer $pat', 'Deriv-App-ID': appId};
    final response = await http.get(
      Uri.parse('$base/trading/v1/options/accounts'), headers: headers,
    ).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('Account lookup HTTP ${response.statusCode}. Check credentials and permissions.');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw StateError('Unexpected account response');
    final payload = decoded['data'];
    final accounts = payload is List
        ? payload
        : payload is Map && payload['accounts'] is List
            ? payload['accounts'] as List
            : null;
    if (accounts == null) throw StateError('Account list unavailable');
    Map<String, dynamic>? demo;
    for (final entry in accounts) {
      if (entry is! Map) continue;
      final a = Map<String, dynamic>.from(entry);
      if (a['account_type']?.toString().toLowerCase() == 'demo') {
        demo = a;
        break;
      }
    }
    if (demo == null) throw StateError('No demo Options account found');
    final accountId = (demo['account_id'] ?? demo['id'])?.toString();
    if (accountId == null || accountId.isEmpty) throw StateError('Demo account ID missing');
    final otpResponse = await http.post(
      Uri.parse('$base/trading/v1/options/accounts/${Uri.encodeComponent(accountId)}/otp'),
      headers: headers,
    ).timeout(const Duration(seconds: 20));
    if (otpResponse.statusCode != 200) {
      throw StateError('Demo OTP request HTTP ${otpResponse.statusCode}');
    }
    final otpJson = jsonDecode(otpResponse.body);
    final otpData = otpJson is Map ? otpJson['data'] : null;
    final url = otpData is Map ? otpData['url']?.toString() : null;
    if (url == null) throw StateError('Missing demo WebSocket URL');
    final uri = Uri.parse(url);
    if (uri.scheme != 'wss' || uri.host != 'api.derivws.com' ||
        uri.path != '/trading/v1/options/ws/demo') {
      throw StateError('Unexpected WebSocket destination');
    }
    try {
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready.timeout(const Duration(seconds: 15));
      connected = true;
      _subscription = _channel!.stream.listen((event) {
        try {
          final message = jsonDecode(event as String);
          if (message is! Map) return;
          final data = Map<String, dynamic>.from(message);
          final id = int.tryParse('${data['req_id']}');
          final waiter = id == null ? null : _pending.remove(id);
          if (waiter == null || waiter.isCompleted) return;
          if (data['error'] != null) {
            waiter.completeError(StateError('${data['error']}'));
          } else {
            waiter.complete(data);
          }
        } catch (_) {
          // Ignore malformed and unsolicited events.
        }
      }, onError: (Object _) => _lost('WebSocket error'),
          onDone: () => _lost('WebSocket closed'));
      _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) async {
        if (!connected) return;
        try {
          await call({'ping': 1});
        } catch (_) {
          _lost('Heartbeat timed out');
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
    _failPending(StateError(reason));
    onDisconnect?.call(reason);
  }

  void _failPending(Object error) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _pending.clear();
  }

  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async {
    if (!connected || _channel == null) throw StateError('Not connected');
    final id = ++_nextId;
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
    _failPending(StateError('Disconnected'));
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
  }
}

double _ema(List<double> values, int period) {
  var e = values.first;
  final a = 2 / (period + 1);
  for (final v in values.skip(1)) {
    e = a * v + (1 - a) * e;
  }
  return e;
}

double _rsi(List<double> closes) {
  var gain = 0.0, loss = 0.0;
  for (var i = closes.length - 14; i < closes.length; i++) {
    final delta = closes[i] - closes[i - 1];
    gain += max(0, delta);
    loss += max(0, -delta);
  }
  if (loss == 0) return gain == 0 ? 50 : 100;
  return 100 - 100 / (1 + gain / loss);
}

List<double> _wilder(List<double> values, int period) {
  var average = values.take(period).reduce((a, b) => a + b) / period;
  final out = <double>[average];
  for (final v in values.skip(period)) {
    average = (average * (period - 1) + v) / period;
    out.add(average);
  }
  return out;
}

Signal? evaluateSignal(String symbol, List<dynamic> data) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final bars = data.whereType<Map>().map((x) => Map<String, dynamic>.from(x))
      .where((x) {
        final epoch = int.tryParse('${x['epoch']}');
        return epoch != null && epoch + 60 <= now - 2;
      }).toList()
    ..sort((a, b) => (int.tryParse('${a['epoch']}') ?? 0)
        .compareTo(int.tryParse('${b['epoch']}') ?? 0));
  if (bars.length < 110) return null;
  List<double> series(String key) => bars.map((b) => double.tryParse('${b[key]}') ?? double.nan).toList();
  final c = series('close'), o = series('open'), h = series('high'), l = series('low');
  if ([...c, ...o, ...h, ...l].any((v) => !v.isFinite)) return null;
  final fast = _ema(c, 20), slow = _ema(c, 50);
  final prevFast = _ema(c.sublist(0, c.length - 1), 20);
  final prevSlow = _ema(c.sublist(0, c.length - 1), 50);
  final momentum = _rsi(c);
  final macd = _ema(c, 12) - _ema(c, 26);
  final prevMacd = _ema(c.sublist(0, c.length - 1), 12) -
      _ema(c.sublist(0, c.length - 1), 26);
  final tr = <double>[], plus = <double>[], minus = <double>[];
  for (var i = 1; i < c.length; i++) {
    tr.add(max(h[i] - l[i], max((h[i] - c[i - 1]).abs(), (l[i] - c[i - 1]).abs())));
    final up = h[i] - h[i - 1], down = l[i - 1] - l[i];
    plus.add(up > down && up > 0 ? up : 0);
    minus.add(down > up && down > 0 ? down : 0);
  }
  final atrs = _wilder(tr, 14), p = _wilder(plus, 14), m = _wilder(minus, 14);
  final dx = <double>[];
  for (var i = 0; i < atrs.length; i++) {
    final pd = atrs[i] == 0 ? 0.0 : 100 * p[i] / atrs[i];
    final md = atrs[i] == 0 ? 0.0 : 100 * m[i] / atrs[i];
    dx.add(pd + md == 0 ? 0 : 100 * (pd - md).abs() / (pd + md));
  }
  final adx = _wilder(dx, 14).last, atr = atrs.last;
  if (atr <= 0 || adx < 22 || adx > 65) return null;
  final up = fast > slow && prevFast > prevSlow && fast > prevFast && c.last > fast;
  final down = fast < slow && prevFast < prevSlow && fast < prevFast && c.last < fast;
  final call = up && momentum >= 53 && momentum <= 67 &&
      macd > 0 && macd > prevMacd && c.last > o.last;
  final put = down && momentum >= 33 && momentum <= 47 &&
      macd < 0 && macd < prevMacd && c.last < o.last;
  if (!call && !put) return null;
  final range = h.last - l.last;
  final separation = (fast - slow).abs() / atr;
  if (range > 2.5 * atr || range < 0.25 * atr || separation < 0.15 || separation > 3) {
    return null;
  }
  final score = (60 + min(15.0, (adx - 22) * .6) +
      min(15.0, separation * 8) + min(10.0, (momentum - 50).abs() * .6))
      .clamp(0.0, 100.0).toDouble();
  return Signal(symbol, call ? 'CALL' : 'PUT',
      'EMA20/50 aligned • MACD confirmed', score, momentum, adx, atr,
      int.parse('${bars.last['epoch']}'));
}

// Digit statistics are descriptive, not a predictive trading model.
DigitStats? analyzeDigits(String symbol, Map<String, dynamic> response) {
  final history = response['history'];
  if (history is! Map || history['prices'] is! List) return null;
  final prices = history['prices'] as List;
  final counts = List<int>.filled(10, 0);
  final pip = int.tryParse('${response['pip_size'] ?? history['pip_size'] ?? ''}');
  // Pip size must be supplied by the API to avoid counting the wrong digit.
  if (pip == null || pip < 0 || pip > 10) return null;
  var last = 0, total = 0;
  for (final raw in prices) {
    final value = num.tryParse('$raw');
    if (value == null) continue;
    final formatted = value.toStringAsFixed(pip);
    final digit = int.tryParse(formatted.substring(formatted.length - 1));
    if (digit == null) continue;
    counts[digit]++;
    last = digit;
    total++;
  }
  return total == 0 ? null : DigitStats(symbol, counts, total, last);
}

class ScannerHome extends StatefulWidget {
  const ScannerHome({super.key});
  @override
  State<ScannerHome> createState() => _ScannerHomeState();
}

class _ScannerHomeState extends State<ScannerHome> with WidgetsBindingObserver {
  static const symbols = ['R_10', 'R_25', 'R_50', 'R_75', 'R_100'];
  final storage = const FlutterSecureStorage();
  final appId = TextEditingController(), pat = TextEditingController();
  DerivClient? client;
  int tab = 0, cycle = 0, interval = 60, minScore = 75;
  double demoStake = 0.35;
  String status = 'Disconnected', account = '', digitMarket = 'R_10', selectedStrategy = 'Even';
  bool connecting = false, scanning = false, busy = false, digitsBusy = false;
  final market = <String, String>{for (final s in symbols) s: 'Waiting for scan'};
  final signals = <Signal>[], seen = <String>{};
  DigitStats? digits;
  DateTime? lastScan;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restore();
  }

  Future<void> _restore() async {
    try {
      final id = await storage.read(key: 'appId') ?? '';
      if (mounted) setState(() => appId.text = id);
    } catch (_) {
      if (mounted) setState(() => status = 'Could not read saved App ID');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) stop('Paused while app is in background');
  }

  Future<void> connect() async {
    if (connecting || client?.connected == true) return;
    final id = appId.text.trim(), token = pat.text.trim();
    if (id.isEmpty || token.isEmpty) {
      setState(() => status = 'Enter App ID and demo PAT');
      return;
    }
    setState(() { connecting = true; status = 'Connecting to demo account…'; });
    final c = DerivClient();
    try {
      await storage.write(key: 'appId', value: id);
      final demoId = await c.connectDemo(id, token);
      if (!mounted) { await c.close(); return; }
      client = c;
      c.onDisconnect = (reason) {
        stop('Disconnected: $reason');
      };
      setState(() { account = demoId; status = 'Connected: demo $demoId'; });
    } catch (e) {
      await c.close();
      if (mounted) setState(() => status = 'Connection failed: $e');
    } finally {
      if (mounted) setState(() => connecting = false);
    }
  }

  void stop([String reason = 'Scan stopped']) {
    generation++;
    scanning = false;
    if (mounted) setState(() => status = reason);
  }

  Future<void> disconnect() async {
    stop('Disconnecting…');
    await client?.close();
    client = null;
    if (mounted) setState(() { account = ''; status = 'Disconnected'; });
  }

  Future<void> start() async {
    if (scanning || busy || client?.connected != true) return;
    final run = ++generation;
    setState(() { scanning = true; status = 'Scanning five markets…'; });
    while (mounted && scanning && generation == run && client?.connected == true) {
      busy = true;
      try {
        final found = <Signal>[];
        for (final symbol in symbols) {
          if (!scanning || generation != run || client?.connected != true) break;
          try {
            final data = await client!.call({
              'ticks_history': symbol, 'end': 'latest',
              'style': 'candles', 'granularity': 60, 'count': 180,
            });
            if (!scanning || generation != run) break;
            final candles = data['candles'];
            if (candles is! List) throw StateError('No candle data');
            final signal = evaluateSignal(symbol, candles);
            if (signal != null && signal.score >= minScore) {
              found.add(signal);
              final key = '${signal.symbol}:${signal.epoch}:${signal.side}';
              if (seen.add(key)) signals.insert(0, signal);
              if (signals.length > 100) signals.removeLast();
            }
            market[symbol] = signal == null ? 'No qualifying setup' :
                '${signal.side} • ${signal.score.toStringAsFixed(0)}/100 agreement';
          } catch (e) {
            market[symbol] = 'Data error: $e';
          }
          if (mounted) setState(() {});
        }
        if (generation != run || !scanning) break;
        found.sort((a, b) => b.score.compareTo(a.score));
        lastScan = DateTime.now();
        cycle++;
        status = found.isEmpty ? 'Scan complete: no qualifying setup' :
            'Top setup: ${found.first.symbol} ${found.first.side}';
      } catch (e) {
        stop('Scan failed: $e');
      } finally {
        busy = false;
        if (mounted) setState(() {});
      }
      if (!scanning || generation != run) break;
      // Check every second so Stop responds promptly.
      for (var i = 0; i < interval; i++) {
        if (!mounted || !scanning || generation != run) break;
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    if (generation == run) scanning = false;
    if (mounted) setState(() {});
  }

  Future<void> refreshDigits() async {
    if (digitsBusy || client?.connected != true) return;
    setState(() => digitsBusy = true);
    try {
      final response = await client!.call({
        'ticks_history': digitMarket, 'end': 'latest', 'style': 'ticks', 'count': 1000,
      });
      final stats = analyzeDigits(digitMarket, response);
      if (!mounted) return;
      setState(() {
        digits = stats;
        status = stats == null
            ? 'Digit precision unavailable: no percentages calculated'
            : 'Digit sample refreshed: ${stats.total} ticks';
      });
    } catch (e) {
      if (mounted) setState(() => status = 'Digit request failed: $e');
    } finally {
      if (mounted) setState(() => digitsBusy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    generation++;
    scanning = false;
    client?.close();
    appId.dispose();
    pat.dispose();
    super.dispose();
  }

  Widget card(String title, Widget body) => Card(
        margin: const EdgeInsets.symmetric(vertical: 7),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12), body,
          ]),
        ),
      );

  Widget statBox(String label, String value, IconData icon, Color accent) =>
      Container(width: 150, padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: const Color(0xFFEFE6FF),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: accent.withValues(alpha: .28))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: accent, size: 22), const SizedBox(height: 12),
          Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4), Text(label, style: const TextStyle(color: Color(0xFF675F77), fontSize: 12)),
        ]));

  Future<void> previewApproval(Signal s) async {
    if (client?.connected != true) return;
    if (DateTime.now().millisecondsSinceEpoch ~/ 1000 - s.epoch > 180) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Signal expired; wait for a fresh scan.')));
      return;
    }
    await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Trade approval • preview'),
      content: Text('Market: ${s.symbol}\nDirection: ${s.side}\n'
          'Indicator agreement: ${s.score.toStringAsFixed(0)}/100\n'
          'Suggested demo stake: \$${demoStake.toStringAsFixed(2)}\n\n'
          'This build cannot submit orders yet. Approval is disabled until '
          'the demo trading API and contract risk checks are validated.'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('SKIP')),
        FilledButton(onPressed: null, child: const Text('APPROVE • LOCKED'))],
    ));
  }

  Widget opportunity(Signal? best) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      gradient: const LinearGradient(colors: [Color(0xFF11334B), Color(0xFF10243A)]),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFF2ADBB8).withValues(alpha: .35))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [Icon(Icons.bolt, color: Color(0xFF36E3BC)), SizedBox(width: 7),
        Text('BEST TRADE OPPORTUNITY', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: .8))]),
      const SizedBox(height: 16),
      if (best == null) ...[
        const Text('SCANNING FOR A SETUP', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(scanning ? 'Analyzing markets • Waiting for confirmation' :
          'Connect your demo account and start scanning',
          style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 12),
        const LinearProgressIndicator(value: null, minHeight: 3),
      ] else ...[
        Text('${best.symbol}  •  ${best.side == 'CALL' ? 'RISE' : 'FALL'}',
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        Text('Indicator agreement ${best.score.toStringAsFixed(0)}/100  •  RSI ${best.rsi.toStringAsFixed(1)}'),
        const SizedBox(height: 14),
        FilledButton.icon(onPressed: client?.connected == true ? () => previewApproval(best) : null,
          icon: const Icon(Icons.verified_user_outlined),
          label: const Text('REVIEW DEMO TRADE')),
      ],
      const SizedBox(height: 10),
      const Text('No order is placed without approval. Execution locked in this preview.',
        style: TextStyle(color: Color(0xFFB9CBD8), fontSize: 11)),
    ]));

  static const violet = Color(0xFF7035DC);
  static const blue = Color(0xFF1258ED);
  static const turquoise = Color(0xFF05B7C9);

  Widget strategyButton(String name, Color color) => Expanded(
    child: Padding(padding: const EdgeInsets.all(4), child: ElevatedButton(
      onPressed: () => setState(() => selectedStrategy = name),
      style: ElevatedButton.styleFrom(
        backgroundColor: color, foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
        side: BorderSide(color: selectedStrategy == name ? Colors.black : Colors.transparent, width: 2),
      ),
      child: Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
    )),
  );

  Widget digitBubble(int number) {
    final percent = digits?.frequency(number);
    final isLast = digits?.lastDigit == number;
    return Container(
      decoration: BoxDecoration(
        color: isLast ? const Color(0xFFDCC5FF) : const Color(0xFFF0EBF7),
        shape: BoxShape.circle,
        border: Border.all(color: isLast ? violet : const Color(0xFFD5C9E9), width: isLast ? 3 : 1),
      ),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text('$number', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        Text(percent == null ? '—' : '${percent.toStringAsFixed(1)}%',
          style: const TextStyle(fontSize: 10, color: Color(0xFF5D5670))),
      ]),
    );
  }

  Widget digitGrid() => GridView.count(
    crossAxisCount: 5, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
    mainAxisSpacing: 9, crossAxisSpacing: 9, childAspectRatio: 1,
    children: [for (var i = 0; i < 10; i++) digitBubble(i)],
  );

  Widget analyzerPanel({bool compact = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('AI Market Analyzer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
      const SizedBox(height: 12),
      Container(padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(color: const Color(0xFFF5F0FC), borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Current trend', style: TextStyle(fontSize: 12, color: Color(0xFF625C6D))),
          Text(scanning ? 'Scanning 5 volatility markets…' : 'Awaiting market analysis',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        ])),
      const SizedBox(height: 8),
      Container(padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(color: const Color(0xFFF5F0FC), borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Pattern detected', style: TextStyle(fontSize: 12, color: Color(0xFF625C6D))),
          Text(digits == null ? 'Load live ticks to view digit distribution.' :
            'Sample loaded: ${digits!.total} ticks. Review frequencies below.',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        ])),
      const SizedBox(height: 12),
      Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
        _pill('Matches'),
        Container(width: compact ? 72 : 90, height: compact ? 72 : 90,
          alignment: Alignment.center,
          decoration: const BoxDecoration(shape: BoxShape.circle,
            gradient: LinearGradient(colors: [Color(0xFFB645F2), Color(0xFF693BE5)])),
          child: Text(digits == null ? '–' : '${digits!.lastDigit}',
            style: const TextStyle(color: Colors.white, fontSize: 35, fontWeight: FontWeight.bold))),
        _pill('Differs'),
      ]),
      const Center(child: Text('Last observed digit • not a prediction',
        style: TextStyle(fontSize: 11, color: Color(0xFF746C83)))),
    ],
  );

  Widget _pill(String label) => Container(padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
    decoration: BoxDecoration(color: turquoise, borderRadius: BorderRadius.circular(28),
      border: Border.all(color: blue, width: 2)),
    child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)));

  void openFloatingAnalyzer() => showModalBottomSheet<void>(
    context: context, isScrollControlled: true, showDragHandle: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
    builder: (ctx) => SafeArea(child: Padding(padding: const EdgeInsets.all(22), child: SingleChildScrollView(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [const Expanded(child: Text('Expert Analysis Tool',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900))),
          IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close))]),
        analyzerPanel(compact: true),
        const SizedBox(height: 15),
        FilledButton.icon(onPressed: client?.connected == true ? () { Navigator.pop(ctx); refreshDigits(); } : null,
          icon: const Icon(Icons.refresh), label: const Text('Refresh live digit sample')),
      ]),
    ))),
  );

  Widget overview() {
    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final sorted = signals.where((s) => nowEpoch - s.epoch <= 180).toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    final best = sorted.isEmpty ? null : sorted.first;
    return ListView(padding: const EdgeInsets.all(14), children: [
      const Text('Expert Trader', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: violet)),
      const SizedBox(height: 4),
      Text(client?.connected == true ? '● DEMO CONNECTED • $account' : '○ DEMO DISCONNECTED',
        style: const TextStyle(color: Color(0xFF168B74), fontWeight: FontWeight.w700)),
      card('Market & strategy', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        DropdownButton<String>(value: digitMarket, isExpanded: true,
          items: [for (final s in symbols) DropdownMenuItem(value: s, child: Text('Volatility ${s.substring(2)} Index'))],
          onChanged: (s) => setState(() { digitMarket = s!; digits = null; })),
        const SizedBox(height: 8),
        Row(children: [strategyButton('Even', blue), strategyButton('Odd', violet)]),
        Row(children: [strategyButton('Over', const Color(0xFF119F5C)), strategyButton('Under', const Color(0xFFE52D34))]),
        const SizedBox(height: 6),
        Text('Selected: $selectedStrategy • informational only',
          style: const TextStyle(fontSize: 12, color: Color(0xFF756A80))),
      ])),
      card('Live Analysis', Column(children: [
        Text(digitMarket, style: const TextStyle(fontWeight: FontWeight.bold)),
        Text(digits == null ? '—' : 'Last digit: ${digits!.lastDigit}',
          style: const TextStyle(fontSize: 27, color: blue, fontWeight: FontWeight.w900)),
        Text(status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 12),
        Wrap(spacing: 7, runSpacing: 7, alignment: WrapAlignment.center, children: [
          FilledButton.icon(onPressed: client?.connected == true && !scanning && !busy ? start : null,
            icon: const Icon(Icons.play_arrow), label: const Text('Start analysis')),
          OutlinedButton.icon(onPressed: scanning ? () => stop() : null,
            icon: const Icon(Icons.stop_circle_outlined), label: const Text('Stop')),
          FilledButton.tonalIcon(onPressed: client?.connected == true && !digitsBusy ? refreshDigits : null,
            icon: const Icon(Icons.refresh), label: const Text('Live ticks')),
        ]),
      ])),
      card('AI Market Analyzer', analyzerPanel()),
      card('Number Distribution Percentages', Column(children: [
        Text(digits == null ? 'Connect demo and tap Live ticks' : 'Observed ${digits!.total} ticks • $digitMarket',
          style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 12), digitGrid(),
        const SizedBox(height: 10),
        Text(digits == null ? 'No sample loaded' :
          'Even ${digits!.even.toStringAsFixed(1)}%  •  Odd ${digits!.odd.toStringAsFixed(1)}%',
          style: const TextStyle(fontWeight: FontWeight.bold)),
      ])),
      card('Recommended trade • manual approval', Column(children: [
        Text(best == null ? 'Waiting for a qualified signal' :
          '${best.symbol}  ${best.side == 'CALL' ? 'RISE' : 'FALL'} • ${best.score.toStringAsFixed(0)}/100 indicator agreement',
          style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        FilledButton.icon(onPressed: best == null ? null : () => previewApproval(best),
          icon: const Icon(Icons.verified_user_outlined), label: const Text('Review demo trade')),
        const Text('Order execution locked until API checks are validated.',
          style: TextStyle(fontSize: 11, color: Colors.deepOrange)),
      ])),
      card('Live market radar', Column(children: [for (final symbol in symbols)
        ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(symbol),
          subtitle: Text(market[symbol] ?? 'Waiting'))])),
      card('Connect Deriv demo', Column(children: [
        TextField(controller: appId, keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Deriv App ID')),
        TextField(controller: pat, obscureText: true, enableSuggestions: false, autocorrect: false,
          decoration: const InputDecoration(labelText: 'Demo PAT • never saved')),
        const SizedBox(height: 9),
        Row(children: [
          Expanded(child: FilledButton(onPressed: connecting || client?.connected == true ? null : connect,
            child: Text(connecting ? 'Connecting…' : 'Connect demo'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton(onPressed: client?.connected == true ? disconnect : null,
            child: const Text('Disconnect'))),
        ]),
      ])),
      const Padding(padding: EdgeInsets.all(8), child: Text(
        'Research preview. Digit frequencies are descriptive, not predictive. '
        'No real-money trading. No trades execute in this build.',
        style: TextStyle(color: Color(0xFF9D5417), fontSize: 12))),
    ]);
  }

  Widget signalTile(Signal s) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: CircleAvatar(child: Icon(s.side == 'CALL' ? Icons.trending_up : Icons.trending_down)),
        title: Text('${s.symbol}  ${s.side}  ${s.score.toStringAsFixed(0)}/100'),
        subtitle: Text('${s.reason}\nRSI ${s.rsi.toStringAsFixed(1)} • ADX ${s.adx.toStringAsFixed(1)} • '
            'ATR ${s.atr.toStringAsPrecision(4)}\n'
            'Candle: ${DateTime.fromMillisecondsSinceEpoch(s.epoch * 1000).toLocal()}'),
        isThreeLine: true,
      );

  Widget signalHistory() => ListView(padding: const EdgeInsets.all(14), children: [
    card('Signal history (current session)', Column(children: [
      const Text('Recorded signals are not completed trades or verified wins.'),
      if (signals.isEmpty) const Padding(padding: EdgeInsets.all(18), child: Text('No signals yet')),
      for (final s in signals) ...[signalTile(s), const Divider()],
    ])),
  ]);

  Widget digitPage() => ListView(padding: const EdgeInsets.all(14), children: [
    card('Last-digit distribution', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      DropdownButton<String>(value: digitMarket, isExpanded: true,
          items: [for (final s in symbols) DropdownMenuItem(value: s, child: Text(s))],
          onChanged: (s) => setState(() { digitMarket = s!; digits = null; })),
      FilledButton(onPressed: client?.connected == true && !digitsBusy ? refreshDigits : null,
          child: Text(digitsBusy ? 'Loading…' : 'Analyze 1,000 ticks')),
      const SizedBox(height: 8),
      if (digits == null) const Text('Connect demo and load tick data. API pip precision is required.'),
      if (digits != null) ...[
        Text('Sample: ${digits!.total} ticks • Last digit: ${digits!.lastDigit}'),
        const SizedBox(height: 12),
        for (var i = 0; i < 10; i++) Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            SizedBox(width: 26, child: Text('$i')),
            Expanded(child: LinearProgressIndicator(value: digits!.frequency(i) / 100, minHeight: 13)),
            SizedBox(width: 68, child: Text(' ${digits!.frequency(i).toStringAsFixed(1)}%')),
          ]),
        ),
        const SizedBox(height: 12),
        Text('Even ${digits!.even.toStringAsFixed(1)}%  •  Odd ${digits!.odd.toStringAsFixed(1)}%'),
      ],
    ])),
    card('Digit contract reference', const Text(
      'Matches: last digit equals chosen digit. Differs: last digit differs. '
      'Even/Odd: parity of last digit. Over/Under: digit above/below a selected barrier. '
      'These statistics describe the sample only and do not predict the next tick.',
    )),
  ]);

  Widget settingsPage() => ListView(padding: const EdgeInsets.all(14), children: [
    card('Scanner settings', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Scan interval: $interval seconds'),
      Slider(value: interval.toDouble(), min: 30, max: 180, divisions: 5,
          label: '${interval}s', onChanged: scanning ? null : (v) => setState(() => interval = v.round())),
      Text('Minimum indicator agreement: $minScore/100'),
      Slider(value: minScore.toDouble(), min: 60, max: 95, divisions: 7,
          label: '$minScore', onChanged: (v) => setState(() => minScore = v.round())),
      const SizedBox(height: 8),
      Text('Proposed demo stake: \$${demoStake.toStringAsFixed(2)} (preview only)'),
      Slider(value: demoStake, min: 0.35, max: 1.0, divisions: 13,
        label: '\$${demoStake.toStringAsFixed(2)}', onChanged: (v) => setState(() => demoStake = v)),
      OutlinedButton(onPressed: () => setState(() { signals.clear(); seen.clear(); cycle = 0; }),
          child: const Text('Clear session history')),
    ])),
    card('Safety & limitations', const Text(
      'V8 preview is a research dashboard. It does not place trades or calculate actual win rates. '
      'Stake selection is a preview; order execution is disabled. '
      'Signals are not backtested. Session history is cleared when the app restarts. '
      'The demo PAT is held in memory only; never paste it into GitHub.',
    )),
  ]);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('V8 PRO • Expert Trader'),
        backgroundColor: const Color(0xFFF5EDFF),
        actions: [Padding(padding: const EdgeInsets.only(right: 14),
          child: Center(child: Text(client?.connected == true ? '● DEMO' : '○ OFFLINE',
              style: TextStyle(color: client?.connected == true ? Colors.greenAccent : Colors.grey))))]),
    body: IndexedStack(index: tab, children: [overview(), signalHistory(), digitPage(), settingsPage()]),
    floatingActionButton: FloatingActionButton.extended(onPressed: openFloatingAnalyzer,
      backgroundColor: violet, foregroundColor: Colors.white,
      icon: const Icon(Icons.auto_graph), label: const Text('Expert Analysis')),
    bottomNavigationBar: NavigationBar(selectedIndex: tab,
      onDestinationSelected: (i) => setState(() => tab = i),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Dashboard'),
        NavigationDestination(icon: Icon(Icons.insights_outlined), label: 'History'),
        NavigationDestination(icon: Icon(Icons.pin_outlined), label: 'Analyzer'),
        NavigationDestination(icon: Icon(Icons.tune), label: 'Settings'),
      ],
    ),
  );
}
