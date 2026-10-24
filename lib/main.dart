import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(
    const MaterialApp(
      home: TradingScreen(),
      debugShowCheckedModeBanner: false,
    ),
  );
}

class Candidate {
  final String symbol, direction;
  final double score;
  final int epoch;

  Candidate(
    this.symbol,
    this.direction,
    this.score,
    this.epoch,
  );
}

class DerivClient {
  StreamSubscription? _sub;WebSocketChannel? _channel;
  int _req = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  Future<void> connect(String appId) async {
    _channel = WebSocketChannel.connect(Uri.parse('wss://ws.derivws.com/websockets/v3?app_id=$appId'));
    await _channel!.ready;
    _sub = _channel!.stream.listen((event) {
      final msg = jsonDecode(event as String) as Map<String, dynamic>;
      final id = msg['req_id'];
      final c = _pending.remove(id);
      if (c != null && !c.isCompleted) {
        if (msg['error'] != null) {
          c.completeError(StateError(msg['error']['message'].toString()));
        } else { c.complete(msg); }
      }
    }, onError: (Object e) => _failAll(e), onDone: () => _failAll(StateError('Disconnected')));
  }
  void _failAll(Object e) {
    for (final c in _pending.values) { if (!c.isCompleted) c.completeError(e); }
    _pending.clear();
  }
  Future<Map<String, dynamic>> call(Map<String, dynamic> payload) async {
    if (_channel == null) throw StateError('Not connected');
    final id = ++_req;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _channel!.sink.add(jsonEncode({...payload, 'req_id': id}));
    try { return await c.future.timeout(const Duration(seconds: 20)); }
    finally { _pending.remove(id); }
  }
  Future<void> close() async { await _sub?.cancel(); await _channel?.sink.close(); _channel = null; _failAll(StateError('Closed')); }
}

double ema(List<double> values, int length) {
  var result = values.first;
  final alpha = 2 / (length + 1);
  for (final v in values.skip(1)) { result = alpha * v + (1 - alpha) * result; }
  return result;
}
double rsi(List<double> closes) {
  var gains = 0.0, losses = 0.0;
  for (var i = closes.length - 14; i < closes.length; i++) {
    final d = closes[i] - closes[i - 1];
    gains += max(0, d); losses += max(0, -d);
  }
  if (losses == 0) return gains == 0 ? 50 : 100;
  return 100 - 100 / (1 + gains / losses);
}
Candidate? evaluate(String symbol, List<dynamic> data) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final closed = data.cast<Map<String, dynamic>>().where((c) =>
      (int.tryParse(c['epoch'].toString()) ?? now) + 60 <= now - 2).toList();
  if (closed.length < 36) return null;
  final closes = closed.map((c) => double.parse(c['close'].toString())).toList();
  final three = closed.sublist(closed.length - 3);
  final up = three.every((c) => double.parse(c['close'].toString()) > double.parse(c['open'].toString()));
  final down = three.every((c) => double.parse(c['close'].toString()) < double.parse(c['open'].toString()));
  final fast = ema(closes.sublist(closes.length - 35), 9);
  final slow = ema(closes.sublist(closes.length - 35), 21);
  final momentum = rsi(closes);
  final ranges = closed.sublist(closed.length - 14).map((c) =>
      double.parse(c['high'].toString()) - double.parse(c['low'].toString())).toList();
  final atr = ranges.reduce((a, b) => a + b) / ranges.length;
  if (atr <= 0) return null;
  final separation = (fast - slow).abs() / atr;
  final epoch = int.parse(three.last['epoch'].toString());
  if (up && fast > slow && momentum >= 53 && momentum <= 68 &&
      closes[closes.length - 1] > closes[closes.length - 2] &&
      closes[closes.length - 2] > closes[closes.length - 3]) {
    return Candidate(symbol, 'CALL', separation + (momentum - 50) / 100, epoch);
  }
  if (down && fast < slow && momentum >= 32 && momentum <= 47 &&
      closes[closes.length - 1] < closes[closes.length - 2] &&
      closes[closes.length - 2] < closes[closes.length - 3]) {
    return Candidate(symbol, 'PUT', separation + (50 - momentum) / 100, epoch);
  }
  return null;
}

class TradingScreen extends StatefulWidget {
  const TradingScreen({super.key});
  @override State<TradingScreen> createState() => _TradingScreenState();
}
class _TradingScreenState extends State<TradingScreen> with WidgetsBindingObserver {
  static const symbols = ['R_10', 'R_25', 'R_50', 'R_75', 'R_100'];
  final storage = const FlutterSecureStorage();
  final tokenController = TextEditingController(), appIdController = TextEditingController();
  DerivClient? client;
  bool running = false, busy = false, auto = false, real = false, connected = false;
  String status = 'Disconnected', login = '';
  int trades = 0, lossStreak = 0;
  double pnl = 0;
  Candidate? best;
  final Set<String> seen = {};
  final Map<String, String> marketStatus = {for (final s in symbols) s: 'Waiting'};
  @override void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); _restore(); }
  Future<void> _restore() async {
    appIdController.text = await storage.read(key: 'appId') ?? '';
    tokenController.text = await storage.read(key: 'demoToken') ?? '';
    if (mounted) setState(() {});
  }
  void note(String s) { if (mounted) setState(() => status = s); }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) { running = false; note('Paused: app not in foreground'); }
  }
  Future<void> connect() async {
    if (connected) return;
    try {
      final id = appIdController.text.trim(), token = tokenController.text.trim();
      if (id.isEmpty || token.isEmpty) {
  throw StateError('Enter a valid Deriv App ID and API token');
      }
      await storage.write(key: 'appId', value: id);
      await storage.write(key: 'demoToken', value: token);
      final c = DerivClient(); await c.connect(id);
      final auth = (await c.call({'authorize': token}))['authorize'] as Map<String, dynamic>;
      final virtual = auth['is_virtual'] == 1 || auth['is_virtual'] == true;
      if (virtual == real) { await c.close(); throw StateError('Token account type does not match selected mode'); }
      client = c; connected = true; login = auth['loginid'].toString(); note('Connected: $login');
    } catch (e) { note('Connection error: $e'); }
  }
  Future<void> disconnect() async { running = false; connected = false; await client?.close(); client = null; note('Disconnected'); }
  Future<void> selectMode(bool live) async {
    if (running || busy) return;
    if (live) {
      final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('Enable REAL-money account?'),
        content: const Text('Real-money trades can lose funds. This strategy has not been validated. You must confirm again before starting automatic trading.'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Select REAL'))]));
      if (confirm != true) return;
    }
    await disconnect(); tokenController.clear();
    if (mounted) setState(() { real = live; trades = 0; pnl = 0; lossStreak = 0; seen.clear(); best = null; });
  }
  Future<void> start() async {
    if (!connected || busy || running) return;
    if (real && auto) {
      final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('Start REAL automatic trading?'),
        content: const Text('Up to 6 trades at \$0.35 each. The session loss threshold is not a guaranteed maximum loss. Continue?'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm start'))]));
      if (confirm != true) return;
    }
    setState(() { running = true; status = 'Scanning'; });
    _loop();
  }
  Future<void> _loop() async {
    while (running && connected && trades < 6 && lossStreak < 2 && pnl > -0.35 && pnl < 1) {
      if (busy) break;
      busy = true;
      try {
        final candidates = <Candidate>[];
        for (final symbol in symbols) {
          if (!running) break;
          try {
            final result = await client!.call({'ticks_history': symbol, 'end': 'latest', 'style': 'candles', 'granularity': 60, 'count': 60});
            final candidate = evaluate(symbol, result['candles'] as List<dynamic>);
            if (candidate != null) candidates.add(candidate);
            marketStatus[symbol] = candidate == null ? 'No signal' : '${candidate.direction} ${candidate.score.toStringAsFixed(2)}';
          } catch (e) { marketStatus[symbol] = 'Error: $e'; }
          if (mounted) setState(() {});
        }
        candidates.sort((a, b) => b.score.compareTo(a.score));
        best = candidates.isEmpty ? null : candidates.first;
        if (best != null && !seen.contains('${best!.symbol}:${best!.epoch}')) {
          seen.add('${best!.symbol}:${best!.epoch}');
          note('Best: ${best!.symbol} ${best!.direction} (${best!.score.toStringAsFixed(2)})');
          if (auto && running) await _trade(best!);
        } else { note('No new qualifying signal'); }
      } catch (e) { running = false; note('Stopped after error: $e'); }
      finally { busy = false; if (mounted) setState(() {}); }
      if (running) await Future.delayed(const Duration(seconds: 60));
    }
    running = false;
    if (mounted) setState(() {});
  }
  Future<void> manualTrade() async {
    if (!connected || running || busy || best == null || trades >= 6 || lossStreak >= 2 || pnl <= -0.35 || pnl >= 1) return;
    final chosen = best!;
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('${real ? 'REAL' : 'DEMO'} ${chosen.direction} on ${chosen.symbol}?'),
      content: const Text('Buy one \$0.35, 5-minute contract?'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Buy'))]));
    if (confirm != true) return;
    busy = true; if (mounted) setState(() {});
    try { await _trade(chosen); } finally { busy = false; if (mounted) setState(() {}); }
  }
  Future<void> _trade(Candidate candidate) async {
    // One contract at a time; buy failures stop the bot to avoid uncertain exposure.
    try {
      final proposal = (await client!.call({'proposal': 1, 'amount': 0.35, 'basis': 'stake',
        'contract_type': candidate.direction, 'currency': 'USD', 'duration': 5,
        'duration_unit': 'm', 'symbol': candidate.symbol}))['proposal'];
      if (!connected) return;
      final bought = (await client!.call({'buy': proposal['id'], 'price': 0.35}))['buy'];
      trades++;
      note('Contract ${bought['contract_id']} opened; awaiting settlement');
      // Foreground-only operation: stopping does not cancel an already purchased contract.
      while (connected) {
        await Future.delayed(const Duration(seconds: 5));
        final details = (await client!.call({'proposal_open_contract': 1, 'contract_id': bought['contract_id']}))['proposal_open_contract'];
        if (details['is_sold'] == 1 || details['is_sold'] == true) {
          final gain = double.tryParse(details['profit'].toString()) ?? 0;
          pnl += gain; lossStreak = gain < 0 ? lossStreak + 1 : 0;
          note('Settled: ${gain.toStringAsFixed(2)} | Session: ${pnl.toStringAsFixed(2)}');
          break;
        }
      }
    } catch (e) { running = false; note('Trade status uncertain. STOP and verify account history: $e'); }
  }
  @override void dispose() { WidgetsBinding.instance.removeObserver(this); running = false; client?.close(); tokenController.dispose(); appIdController.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF101723),
    appBar: AppBar(title: const Text('Volatility Scanner'), backgroundColor: const Color(0xFF182334), foregroundColor: Colors.white),
    body: Theme(data: ThemeData.dark(), child: ListView(padding: const EdgeInsets.all(16), children: [
      Text(real ? 'REAL MONEY — HIGH RISK' : 'DEMO — VIRTUAL FUNDS', style: TextStyle(color: real ? Colors.redAccent : Colors.greenAccent, fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      SegmentedButton<bool>(segments: const [ButtonSegment(value: false, label: Text('Demo')), ButtonSegment(value: true, label: Text('Real'))],
        selected: {real}, onSelectionChanged: busy || running ? null : (v) => selectMode(v.first)),
      const SizedBox(height: 12),
      TextField(controller: appIdController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Deriv app ID')),
      TextField(controller: tokenController, obscureText: true, decoration: InputDecoration(labelText: real ? 'REAL account API token' : 'DEMO account API token')),
      const SizedBox(height: 12),
      Wrap(spacing: 8, children: [FilledButton(onPressed: connected ? null : connect, child: const Text('Connect')), OutlinedButton(onPressed: connected ? disconnect : null, child: const Text('Disconnect'))]),
      SwitchListTile(title: const Text('Automatic trading'), subtitle: const Text('Off = signals only / manual trade'), value: auto,
        onChanged: running || busy ? null : (v) => setState(() => auto = v)),
      Wrap(spacing: 8, children: [FilledButton(onPressed: connected && !running && !busy ? start : null, child: const Text('START')),
        FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: running ? () => setState(() { running = false; status = 'Stop requested; existing contract may remain open'; }) : null, child: const Text('STOP')),
        OutlinedButton(onPressed: connected && !running && !busy && best != null ? manualTrade : null, child: const Text('Manual Buy'))]),
      const SizedBox(height: 12),
      Text('Status: $status'), Text('Account: $login'),
      Text('Session P/L: \$${pnl.toStringAsFixed(2)}    Trades: $trades/6    Loss streak: $lossStreak/2', style: const TextStyle(fontWeight: FontWeight.bold)),
      const Divider(),
      for (final s in symbols) Card(color: const Color(0xFF1D2A3D), child: ListTile(title: Text(s), subtitle: Text(marketStatus[s] ?? 'Waiting'),
        trailing: best?.symbol == s ? const Icon(Icons.star, color: Colors.amber) : null)),
      const Text('Prototype: not backtested or API-verified. Session limits reset on app restart. Android may suspend network activity when the app is backgrounded. Stop prevents new entries but cannot cancel purchased contracts.', style: TextStyle(color: Colors.orangeAccent)),
    ])));
}
