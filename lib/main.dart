import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

void main() => runApp(const MaterialApp(home: TradingScreen(), debugShowCheckedModeBanner: false));

class Candidate {
  final String symbol, direction;
  final double score;
  final int epoch;
  const Candidate(this.symbol, this.direction, this.score, this.epoch);
}

class DerivClient {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _heartbeat;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _nextId = 0;
  bool connected = false;
  void Function(String)? onDisconnect;

  static const _base = 'https://api.derivws.com';

  Future<String> connectDemo(String appId, String pat) async {
    await close();
    final headers = {'Authorization': 'Bearer $pat', 'Deriv-App-ID': appId};
    final accountsResponse = await http.get(
      Uri.parse('$_base/trading/v1/options/accounts'), headers: headers,
    ).timeout(const Duration(seconds: 20));
    if (accountsResponse.statusCode != 200) {
      throw StateError('Accounts request failed (HTTP ${accountsResponse.statusCode}). Check PAT, App ID and permissions.');
    }
    final accountsJson = jsonDecode(accountsResponse.body) as Map<String, dynamic>;
    final payload = accountsJson['data'];
    List<dynamic> accounts;
    if (payload is List) {
      accounts = payload;
    } else if (payload is Map && payload['accounts'] is List) {
      accounts = payload['accounts'] as List;
    } else {
      throw StateError('Unrecognized accounts response format.');
    }
    Map<String, dynamic>? demo;
    for (final item in accounts) {
      if (item is Map) {
        final a = Map<String, dynamic>.from(item);
        if (a['account_type']?.toString().toLowerCase() == 'demo') {
          demo = a;
          break;
        }
      }
    }
    if (demo == null) throw StateError('No demo Options account found.');
    final accountId = (demo['account_id'] ?? demo['id'])?.toString();
    if (accountId == null || accountId.isEmpty) throw StateError('Demo account ID missing.');
    final otpResponse = await http.post(
      Uri.parse('$_base/trading/v1/options/accounts/${Uri.encodeComponent(accountId)}/otp'),
      headers: headers,
    ).timeout(const Duration(seconds: 20));
    if (otpResponse.statusCode != 200) {
      throw StateError('OTP request failed (HTTP ${otpResponse.statusCode}).');
    }
    final otpJson = jsonDecode(otpResponse.body) as Map<String, dynamic>;
    final otpData = otpJson['data'];
    final url = otpData is Map ? otpData['url']?.toString() : null;
    if (url == null || url.isEmpty) throw StateError('OTP URL missing.');
    final uri = Uri.parse(url);
    if (uri.scheme != 'wss' || uri.host != 'api.derivws.com' ||
        uri.path != '/trading/v1/options/ws/demo') {
      throw StateError('Refusing unexpected or non-demo WebSocket URL.');
    }
    try {
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready.timeout(const Duration(seconds: 15));
      connected = true;
      _subscription = _channel!.stream.listen((event) {
        try {
          final msg = jsonDecode(event as String) as Map<String, dynamic>;
          final rawId = msg['req_id'];
          final id = rawId is int ? rawId : int.tryParse(rawId?.toString() ?? '');
          final waiter = id == null ? null : _pending.remove(id);
          if (waiter != null && !waiter.isCompleted) {
            if (msg['error'] != null) {
              waiter.completeError(StateError(msg['error'].toString()));
            } else {
              waiter.complete(msg);
            }
          }
        } catch (_) {
          // Ignore unsolicited or malformed messages during this test build.
        }
      }, onError: (Object error) => _lost('Connection error'),
         onDone: () => _lost('Connection closed'));
      _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
        if (connected) {
          call({'ping': 1}).catchError((Object _) {
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
    _failPending(StateError(reason));
    onDisconnect?.call(reason);
  }

  void _failPending(Object error) {
    for (final waiter in _pending.values) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _pending.clear();
  }

  Future<Map<String, dynamic>> call(Map<String, dynamic> payload) async {
    if (!connected || _channel == null) throw StateError('Not connected');
    final id = ++_nextId;
    final waiter = Completer<Map<String, dynamic>>();
    _pending[id] = waiter;
    try {
      _channel!.sink.add(jsonEncode({...payload, 'req_id': id}));
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

double ema(List<double> values, int length) {
  var value = values.first;
  final alpha = 2 / (length + 1);
  for (final v in values.skip(1)) { value = alpha * v + (1 - alpha) * value; }
  return value;
}

double rsi(List<double> closes) {
  var gains = 0.0, losses = 0.0;
  for (var i = closes.length - 14; i < closes.length; i++) {
    final change = closes[i] - closes[i - 1];
    gains += max(0, change);
    losses += max(0, -change);
  }
  if (losses == 0) return gains == 0 ? 50 : 100;
  return 100 - 100 / (1 + gains / losses);
}

Candidate? evaluate(String symbol, List<dynamic> data) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final closed = data.whereType<Map>().map((e) => Map<String, dynamic>.from(e))
      .where((c) => (int.tryParse(c['epoch'].toString()) ?? now) + 60 <= now - 2)
      .toList();
  if (closed.length < 36) return null;
  final closes = closed.map((c) => double.tryParse(c['close'].toString()) ?? double.nan).toList();
  if (closes.any((v) => !v.isFinite)) return null;
  final three = closed.sublist(closed.length - 3);
  final up = three.every((c) => (double.tryParse(c['close'].toString()) ?? 0) > (double.tryParse(c['open'].toString()) ?? 0));
  final down = three.every((c) => (double.tryParse(c['close'].toString()) ?? 0) < (double.tryParse(c['open'].toString()) ?? 0));
  final fast = ema(closes.sublist(closes.length - 35), 9);
  final slow = ema(closes.sublist(closes.length - 35), 21);
  final momentum = rsi(closes);
  final ranges = closed.sublist(closed.length - 14).map((c) =>
      (double.tryParse(c['high'].toString()) ?? 0) - (double.tryParse(c['low'].toString()) ?? 0)).toList();
  final atr = ranges.reduce((a, b) => a + b) / ranges.length;
  if (atr <= 0) return null;
  final separation = (fast - slow).abs() / atr;
  final epoch = int.tryParse(three.last['epoch'].toString()) ?? 0;
  if (up && fast > slow && momentum >= 53 && momentum <= 68 &&
      closes.last > closes[closes.length - 2] && closes[closes.length - 2] > closes[closes.length - 3]) {
    return Candidate(symbol, 'CALL', separation + (momentum - 50) / 100, epoch);
  }
  if (down && fast < slow && momentum >= 32 && momentum <= 47 &&
      closes.last < closes[closes.length - 2] && closes[closes.length - 2] < closes[closes.length - 3]) {
    return Candidate(symbol, 'PUT', separation + (50 - momentum) / 100, epoch);
  }
  return null;
}

class TradingScreen extends StatefulWidget {
  const TradingScreen({super.key});
  @override
  State<TradingScreen> createState() => _TradingScreenState();
}

class _TradingScreenState extends State<TradingScreen> with WidgetsBindingObserver {
  static const symbols = ['R_10', 'R_25', 'R_50', 'R_75', 'R_100'];
  final storage = const FlutterSecureStorage();
  final appIdController = TextEditingController();
  final tokenController = TextEditingController();
  DerivClient? client;
  bool connecting = false, scanning = false, busy = false;
  String status = 'Disconnected', accountId = '';
  Candidate? best;
  final seen = <String>{};
  final marketStatus = <String, String>{for (final s in symbols) s: 'Waiting'};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restore();
  }

  Future<void> _restore() async {
    final id = await storage.read(key: 'appId') ?? '';
    if (!mounted) return;
    setState(() => appIdController.text = id);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      scanning = false;
      if (mounted) setState(() => status = 'Scanning paused: app backgrounded');
    }
  }

  Future<void> connect() async {
    if (connecting || client?.connected == true) return;
    final id = appIdController.text.trim();
    final pat = tokenController.text.trim();
    if (id.isEmpty || pat.isEmpty) {
      setState(() => status = 'Enter App ID and PAT');
      return;
    }
    setState(() { connecting = true; status = 'Checking demo account and requesting OTP…'; });
    final c = DerivClient();
    try {
      await storage.write(key: 'appId', value: id);
      final demoId = await c.connectDemo(id, pat);
      if (!mounted) { await c.close(); return; }
      client = c;
      c.onDisconnect = (reason) {
        scanning = false;
        if (mounted) setState(() => status = 'Disconnected: $reason');
      };
      setState(() { accountId = demoId; status = 'Connected to DEMO: $demoId'; });
    } catch (e) {
      await c.close();
      if (mounted) setState(() => status = 'Connection failed: $e');
    } finally {
      if (mounted) setState(() => connecting = false);
    }
  }

  Future<void> disconnect() async {
    scanning = false;
    await client?.close();
    client = null;
    if (mounted) setState(() { status = 'Disconnected'; accountId = ''; });
  }

  Future<void> start() async {
    if (scanning || busy || client?.connected != true) return;
    setState(() { scanning = true; status = 'Scanning demo markets (signals only)'; });
    while (scanning && mounted && client?.connected == true) {
      busy = true;
      try {
        final candidates = <Candidate>[];
        for (final symbol in symbols) {
          if (!scanning || client?.connected != true) break;
          try {
            final response = await client!.call({
              'ticks_history': symbol, 'end': 'latest', 'style': 'candles',
              'granularity': 60, 'count': 60,
            });
            final candles = response['candles'];
            if (candles is! List) throw StateError('No candles returned');
            final candidate = evaluate(symbol, candles);
            if (candidate != null) candidates.add(candidate);
            marketStatus[symbol] = candidate == null ? 'No signal' :
                '${candidate.direction} ${candidate.score.toStringAsFixed(2)}';
          } catch (e) {
            marketStatus[symbol] = 'Data error: $e';
          }
          if (mounted) setState(() {});
        }
        candidates.sort((a, b) => b.score.compareTo(a.score));
        best = candidates.isEmpty ? null : candidates.first;
        if (best != null && seen.add('${best!.symbol}:${best!.epoch}')) {
          status = 'Signal: ${best!.symbol} ${best!.direction} (${best!.score.toStringAsFixed(2)})';
        } else {
          status = 'Scan complete; no new qualifying signal';
        }
      } catch (e) {
        scanning = false;
        status = 'Scanner stopped: $e';
      } finally {
        busy = false;
        if (mounted) setState(() {});
      }
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
    appIdController.dispose();
    tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF101723),
    appBar: AppBar(title: const Text('Volatility Scanner V2'),
        backgroundColor: const Color(0xFF182334), foregroundColor: Colors.white),
    body: Theme(
      data: ThemeData.dark(),
      child: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('DEMO ONLY — SIGNALS ONLY', style: TextStyle(
            color: Colors.greenAccent, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        TextField(controller: appIdController, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Deriv App ID')),
        TextField(controller: tokenController, obscureText: true,
            enableSuggestions: false, autocorrect: false,
            decoration: const InputDecoration(labelText: 'Deriv PAT (not saved)')),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          FilledButton(onPressed: connecting || client?.connected == true ? null : connect,
              child: const Text('Connect demo')),
          OutlinedButton(onPressed: client?.connected == true ? disconnect : null,
              child: const Text('Disconnect')),
        ]),
        Wrap(spacing: 8, children: [
          FilledButton(onPressed: client?.connected == true && !scanning && !busy ? start : null,
              child: const Text('START SCAN')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: scanning ? () => setState(() { scanning = false; status = 'Stop requested'; }) : null,
              child: const Text('STOP SCAN')),
        ]),
        const SizedBox(height: 12),
        Text('Status: $status'),
        Text('Demo account: $accountId'),
        const Divider(),
        for (final symbol in symbols)
          Card(color: const Color(0xFF1D2A3D), child: ListTile(
            title: Text(symbol), subtitle: Text(marketStatus[symbol] ?? 'Waiting'),
            trailing: best?.symbol == symbol ? const Icon(Icons.star, color: Colors.amber) : null,
          )),
        const Text('TEST BUILD: No buying, selling, real-money mode, or automatic trading. '
            'Signals are experimental and not evidence of profitability. '
            'Keep the app in the foreground during testing.',
            style: TextStyle(color: Colors.orangeAccent)),
      ]),
    ),
  );
}
