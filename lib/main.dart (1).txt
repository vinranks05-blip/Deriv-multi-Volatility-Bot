import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

void main() => runApp(const MaterialApp(home: Scanner(), debugShowCheckedModeBanner: false));

class Signal {
  final String symbol, direction, reason;
  final double score;
  final int epoch;
  const Signal(this.symbol, this.direction, this.score, this.epoch, this.reason);
}

class DerivConnection {
  WebSocketChannel? channel;
  StreamSubscription? subscription;
  Timer? heartbeat;
  final pending = <int, Completer<Map<String, dynamic>>>{};
  int nextId = 0;
  bool connected = false;
  void Function(String)? onLost;

  Future<String> connect(String appId, String pat) async {
    await close();
    final headers = {'Authorization': 'Bearer $pat', 'Deriv-App-ID': appId};
    final response = await http.get(Uri.parse('https://api.derivws.com/trading/v1/options/accounts'), headers: headers).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw StateError('Accounts HTTP ${response.statusCode}. Check credentials and permissions.');
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final data = decoded['data'];
    final List<dynamic> accounts;
    if (data is List) {
      accounts = data;
    } else if (data is Map && data['accounts'] is List) {
      accounts = data['accounts'] as List;
    } else {
      throw StateError('Unknown accounts response');
    }
    Map<String, dynamic>? demo;
    for (final a in accounts) {
      if (a is Map && a['account_type']?.toString().toLowerCase() == 'demo') {
        demo = Map<String, dynamic>.from(a);
        break;
      }
    }
    if (demo == null) throw StateError('No demo Options account found');
    final account = (demo['account_id'] ?? demo['id'])?.toString();
    if (account == null || account.isEmpty) throw StateError('Demo account ID missing');
    final otp = await http.post(Uri.parse('https://api.derivws.com/trading/v1/options/accounts/${Uri.encodeComponent(account)}/otp'), headers: headers).timeout(const Duration(seconds: 20));
    if (otp.statusCode != 200) throw StateError('OTP HTTP ${otp.statusCode}');
    final otpJson = jsonDecode(otp.body) as Map<String, dynamic>;
    final otpData = otpJson['data'];
    final url = otpData is Map ? otpData['url']?.toString() : null;
    if (url == null) throw StateError('OTP URL missing');
    final uri = Uri.parse(url);
    if (uri.scheme != 'wss' || uri.host != 'api.derivws.com' || uri.path != '/trading/v1/options/ws/demo') {
      throw StateError('Unexpected WebSocket endpoint');
    }
    try {
      channel = WebSocketChannel.connect(uri);
      await channel!.ready.timeout(const Duration(seconds: 15));
      connected = true;
      subscription = channel!.stream.listen((event) {
        try {
          final message = jsonDecode(event as String) as Map<String, dynamic>;
          final id = int.tryParse('${message['req_id']}');
          final waiter = id == null ? null : pending.remove(id);
          if (waiter != null && !waiter.isCompleted) {
            if (message['error'] != null) {
              waiter.completeError(StateError('${message['error']}'));
            } else {
              waiter.complete(message);
            }
          }
        } catch (_) {}
      }, onError: (_) => lost('Network error'), onDone: () => lost('Socket closed'));
      heartbeat = Timer.periodic(const Duration(seconds: 30), (_) async {
        if (!connected) return;
        try { await call({'ping': 1}); } catch (_) { lost('Heartbeat timeout'); }
      });
      return account;
    } catch (_) {
      await close();
      rethrow;
    }
  }

  void lost(String reason) {
    if (!connected) return;
    connected = false;
    heartbeat?.cancel();
    for (final c in pending.values) { if (!c.isCompleted) c.completeError(StateError(reason)); }
    pending.clear();
    onLost?.call(reason);
  }

  Future<Map<String, dynamic>> call(Map<String, dynamic> payload) async {
    if (!connected || channel == null) throw StateError('Not connected');
    final id = ++nextId;
    final waiter = Completer<Map<String, dynamic>>();
    pending[id] = waiter;
    try {
      channel!.sink.add(jsonEncode({...payload, 'req_id': id}));
      return await waiter.future.timeout(const Duration(seconds: 20));
    } finally { pending.remove(id); }
  }

  Future<void> close() async {
    connected = false;
    heartbeat?.cancel();
    for (final c in pending.values) { if (!c.isCompleted) c.completeError(StateError('Disconnected')); }
    pending.clear();
    await subscription?.cancel();
    subscription = null;
    await channel?.sink.close();
    channel = null;
  }
}

double ema(List<double> values, int period) {
  var result = values.first;
  final alpha = 2 / (period + 1);
  for (final v in values.skip(1)) { result = alpha * v + (1 - alpha) * result; }
  return result;
}

double rsi(List<double> closes) {
  double gains = 0, losses = 0;
  for (var i = closes.length - 14; i < closes.length; i++) {
    final delta = closes[i] - closes[i - 1];
    gains += max(0, delta);
    losses += max(0, -delta);
  }
  if (losses == 0) return gains == 0 ? 50 : 100;
  return 100 - 100 / (1 + gains / losses);
}

List<double> wilder(List<double> values, int period) {
  var v = values.take(period).reduce((a, b) => a + b) / period;
  final out = <double>[v];
  for (final x in values.skip(period)) { v = (v * (period - 1) + x) / period; out.add(v); }
  return out;
}

Signal? evaluate(String symbol, List<dynamic> raw) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final bars = raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e))
      .where((e) => (int.tryParse('${e['epoch']}') ?? now) + 60 <= now - 2).toList()
    ..sort((a, b) => (int.tryParse('${a['epoch']}') ?? 0).compareTo(int.tryParse('${b['epoch']}') ?? 0));
  if (bars.length < 110) return null;
  List<double> col(String key) => bars.map((e) => double.tryParse('${e[key]}') ?? double.nan).toList();
  final c = col('close'), o = col('open'), h = col('high'), l = col('low');
  if ([...c, ...o, ...h, ...l].any((v) => !v.isFinite)) return null;
  final fast = ema(c, 20), slow = ema(c, 50);
  final prevFast = ema(c.sublist(0, c.length - 1), 20);
  final prevSlow = ema(c.sublist(0, c.length - 1), 50);
  final momentum = rsi(c);
  final macd = ema(c, 12) - ema(c, 26);
  final prevMacd = ema(c.sublist(0, c.length - 1), 12) - ema(c.sublist(0, c.length - 1), 26);
  final trs = <double>[], plus = <double>[], minus = <double>[];
  for (var i = 1; i < c.length; i++) {
    trs.add(max(h[i] - l[i], max((h[i] - c[i - 1]).abs(), (l[i] - c[i - 1]).abs())));
    final up = h[i] - h[i - 1], down = l[i - 1] - l[i];
    plus.add(up > down && up > 0 ? up : 0);
    minus.add(down > up && down > 0 ? down : 0);
  }
  final atrSeries = wilder(trs, 14), pSeries = wilder(plus, 14), mSeries = wilder(minus, 14);
  final dx = <double>[];
  for (var i = 0; i < atrSeries.length; i++) {
    final p = atrSeries[i] > 0 ? 100 * pSeries[i] / atrSeries[i] : 0.0;
    final m = atrSeries[i] > 0 ? 100 * mSeries[i] / atrSeries[i] : 0.0;
    dx.add(p + m > 0 ? 100 * (p - m).abs() / (p + m) : 0);
  }
  final adx = wilder(dx, 14).last, atr = atrSeries.last;
  if (atr <= 0 || adx < 22 || adx > 65) return null;
  final up = fast > slow && prevFast > prevSlow && fast > prevFast && c.last > fast;
  final down = fast < slow && prevFast < prevSlow && fast < prevFast && c.last < fast;
  final call = up && momentum >= 53 && momentum <= 67 && macd > 0 && macd > prevMacd && c.last > o.last;
  final put = down && momentum >= 33 && momentum <= 47 && macd < 0 && macd < prevMacd && c.last < o.last;
  if (!call && !put) return null;
  final range = h.last - l.last;
  if (range > 2.5 * atr || range < 0.25 * atr) return null;
  final separation = (fast - slow).abs() / atr;
  if (separation < 0.15 || separation > 3) return null;
  final score = (60 + min(15.0, (adx - 22) * 0.6) + min(15.0, separation * 8) + min(10.0, (momentum - 50).abs() * 0.6)).clamp(0.0, 100.0).toDouble();
  return Signal(symbol, call ? 'CALL' : 'PUT', score, int.tryParse('${bars.last['epoch']}') ?? 0,
      'EMA20/50 • RSI ${momentum.toStringAsFixed(1)} • ADX ${adx.toStringAsFixed(1)} • MACD');
}

class Scanner extends StatefulWidget {
  const Scanner({super.key});
  @override
  State<Scanner> createState() => _ScannerState();
}

class _ScannerState extends State<Scanner> with WidgetsBindingObserver {
  static const symbols = ['R_10', 'R_25', 'R_50', 'R_75', 'R_100'];
  final storage = const FlutterSecureStorage();
  final appId = TextEditingController(), pat = TextEditingController();
  DerivConnection? client;
  bool connecting = false, scanning = false, busy = false;
  String status = 'Disconnected', account = '';
  Signal? best;
  DateTime? lastScan;
  int scanCount = 0;
  final seen = <String>{};
  final history = <Signal>[];
  final market = <String, String>{for (final s in symbols) s: 'Waiting for scan'};

  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); restore(); }
  Future<void> restore() async {
    final id = await storage.read(key: 'appId') ?? '';
    if (mounted) setState(() => appId.text = id);
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && scanning) {
      setState(() { scanning = false; status = 'Scan paused: app in background'; });
    }
  }
  Future<void> connect() async {
    if (connecting || client?.connected == true) return;
    if (appId.text.trim().isEmpty || pat.text.trim().isEmpty) {
      setState(() => status = 'Enter App ID and PAT'); return;
    }
    setState(() { connecting = true; status = 'Connecting to demo…'; });
    final c = DerivConnection();
    try {
      await storage.write(key: 'appId', value: appId.text.trim());
      final id = await c.connect(appId.text.trim(), pat.text.trim());
      if (!mounted) { await c.close(); return; }
      client = c;
      c.onLost = (reason) {
        if (mounted) setState(() { scanning = false; status = 'Disconnected: $reason'; });
      };
      setState(() { account = id; status = 'Connected to DEMO'; });
    } catch (e) {
      await c.close();
      if (mounted) setState(() => status = 'Connection failed: $e');
    } finally { if (mounted) setState(() => connecting = false); }
  }
  Future<void> disconnect() async {
    scanning = false;
    await client?.close();
    client = null;
    if (mounted) setState(() { account = ''; status = 'Disconnected'; });
  }
  Future<void> start() async {
    if (scanning || busy || client?.connected != true) return;
    setState(() { scanning = true; status = 'Scanning five demo markets'; });
    while (scanning && mounted && client?.connected == true) {
      busy = true;
      final candidates = <Signal>[];
      for (final symbol in symbols) {
        if (!scanning || client?.connected != true) break;
        try {
          final response = await client!.call({'ticks_history': symbol, 'end': 'latest', 'style': 'candles', 'granularity': 60, 'count': 180});
          if (response['candles'] is! List) throw StateError('No candles returned');
          final signal = evaluate(symbol, response['candles'] as List<dynamic>);
          if (signal != null) candidates.add(signal);
          market[symbol] = signal == null ? 'No qualifying signal' : '${signal.direction} • ${signal.score.toStringAsFixed(0)}/100\n${signal.reason}';
        } catch (e) { market[symbol] = 'Data error: $e'; }
        if (mounted) setState(() {});
      }
      candidates.sort((a, b) => b.score.compareTo(a.score));
      if (scanning && client?.connected == true) {
        best = candidates.isEmpty ? null : candidates.first;
        for (final s in candidates) {
          if (seen.add('${s.symbol}:${s.epoch}:${s.direction}')) {
            history.insert(0, s);
            if (history.length > 30) history.removeLast();
          }
        }
        scanCount++;
        lastScan = DateTime.now();
        status = best == null ? 'Scan complete • no qualifying signal' : 'Best: ${best!.symbol} ${best!.direction} (${best!.score.toStringAsFixed(0)}/100)';
      }
      busy = false;
      if (mounted) setState(() {});
      if (!scanning) break;
      await Future.delayed(const Duration(seconds: 60));
    }
    scanning = false;
    if (mounted) setState(() {});
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    scanning = false;
    client?.close();
    appId.dispose(); pat.dispose();
    super.dispose();
  }
  Widget panel(String title, Widget child) => Card(
    color: const Color(0xFF1D2A3D),
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white)),
      const SizedBox(height: 12), child,
    ])),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF101723),
    appBar: AppBar(title: const Text('Volatility Scanner V4'), backgroundColor: const Color(0xFF182334), foregroundColor: Colors.white),
    body: Theme(data: ThemeData.dark(), child: ListView(padding: const EdgeInsets.all(16), children: [
      const Text('DEMO • SIGNALS ONLY', style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold, color: Colors.greenAccent)),
      const SizedBox(height: 12),
      panel('Connection', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: appId, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Deriv App ID')),
        TextField(controller: pat, obscureText: true, enableSuggestions: false, autocorrect: false, decoration: const InputDecoration(labelText: 'Deriv PAT (not saved)')),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          FilledButton(onPressed: connecting || client?.connected == true ? null : connect, child: const Text('Connect demo')),
          OutlinedButton(onPressed: client?.connected == true ? disconnect : null, child: const Text('Disconnect')),
        ]),
        Text('Account: ${account.isEmpty ? '—' : account}'),
        Text('Status: $status'),
      ])),
      panel('Scanner controls', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, children: [
          FilledButton(onPressed: client?.connected == true && !scanning && !busy ? start : null, child: const Text('START SCAN')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: scanning ? () => setState(() { scanning = false; status = 'Stop requested'; }) : null, child: const Text('STOP SCAN')),
        ]),
        Text('Cycles: $scanCount   •   Signals logged: ${history.length}'),
        Text('Last scan: ${lastScan == null ? 'Never' : lastScan!.toLocal().toString().substring(0, 19)}'),
      ])),
      panel('Best current signal', best == null
        ? const Text('No qualifying signal yet')
        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${best!.symbol}   ${best!.direction}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.amberAccent)),
            Text('Agreement score: ${best!.score.toStringAsFixed(0)}/100'),
            Text(best!.reason),
          ])),
      panel('Market dashboard', Column(children: [for (final symbol in symbols)
        ListTile(contentPadding: EdgeInsets.zero, title: Text(symbol, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text(market[symbol] ?? 'Waiting'),
          trailing: best?.symbol == symbol ? const Icon(Icons.star, color: Colors.amber) : null),
      ])),
      panel('Recent signals • current session', history.isEmpty
        ? const Text('Signals will appear here after scanning')
        : Column(children: [for (final s in history.take(15))
            ListTile(contentPadding: EdgeInsets.zero, title: Text('${s.symbol} ${s.direction} • ${s.score.toStringAsFixed(0)}/100'),
              subtitle: Text('${DateTime.fromMillisecondsSinceEpoch(s.epoch * 1000).toLocal()}\n${s.reason}')),
          ])),
      const Text('V4 TEST BUILD • Indicator agreement is NOT win probability. No real-money trading, order placement or auto-trading. Signal history is in-memory and clears on restart. Keep app in foreground during scanning.', style: TextStyle(color: Colors.orangeAccent)),
      const SizedBox(height: 24),
    ])),
  );
}
