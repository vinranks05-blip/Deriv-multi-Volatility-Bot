import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() => runApp(const TraderApp());

const bg = Color(0xff06112b);
const panel = Color(0xff11254b);
const cyan = Color(0xff19d6ff);
const green = Color(0xff20dfab);
const red = Color(0xffff6581);

class TraderApp extends StatelessWidget {
  const TraderApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: bg,
          colorScheme: ColorScheme.fromSeed(seedColor: cyan, brightness: Brightness.dark),
        ),
        home: const Dashboard(),
      );
}

class Tick {
  final double price;
  final int epoch, digit;
  const Tick(this.price, this.epoch, this.digit);
}

class Prediction {
  final String strategy;
  final int digit, startedAt, expiresAt;
  const Prediction(this.strategy, this.digit, this.startedAt, this.expiresAt);
}

class Market {
  final String symbol, name;
  final List<Tick> ticks = [];
  bool live = false;
  DateTime? seen;
  int precision = 2;
  String trend = 'COLLECTING';
  double rsi = 50, macd = 0, movement = 0, score = 0;
  Prediction? prediction;
  Market(this.symbol, this.name);
  int? get lastDigit => ticks.isEmpty ? null : ticks.last.digit;
  List<int> get counts {
    final result = List<int>.filled(10, 0);
    for (final tick in ticks) { result[tick.digit]++; }
    return result;
  }
}

class Observation {
  final String symbol, strategy;
  final int predicted, actual, epoch;
  final bool correct;
  Observation(this.symbol, this.strategy, this.predicted, this.actual, this.epoch, this.correct);
  Map<String, dynamic> toJson() => {
    'symbol': symbol, 'strategy': strategy, 'predicted': predicted,
    'actual': actual, 'epoch': epoch, 'correct': correct,
  };
  factory Observation.fromJson(Map<String, dynamic> j) => Observation(
    '${j['symbol']}', '${j['strategy']}', (j['predicted'] as num).toInt(),
    (j['actual'] as num).toInt(), (j['epoch'] as num).toInt(), j['correct'] == true,
  );
}

class Trade {
  final int id;
  final String symbol, type;
  final double stake;
  double? profit;
  String status;
  Trade(this.id, this.symbol, this.type, this.stake, {this.profit, this.status = 'OPEN'});
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final markets = [
    Market('R_10', 'Volatility 10'), Market('R_25', 'Volatility 25'),
    Market('R_50', 'Volatility 50'), Market('R_75', 'Volatility 75'),
    Market('R_100', 'Volatility 100'), Market('1HZ10V', 'Volatility 10 (1s)'),
    Market('1HZ25V', 'Volatility 25 (1s)'), Market('1HZ50V', 'Volatility 50 (1s)'),
    Market('1HZ75V', 'Volatility 75 (1s)'), Market('1HZ100V', 'Volatility 100 (1s)'),
  ];
  final secure = const FlutterSecureStorage();
  final tokenInput = TextEditingController();
  final journalInput = TextEditingController();
  final results = <Observation>[];
  final trades = <Trade>[];
  final alerts = <String>[];
  final pending = <int, Completer<Map<String, dynamic>>>{};
  final contractSubscriptions = <int>{};
  WebSocketChannel? ws;
  StreamSubscription? subscription;
  Timer? heartbeat, retry, clock;
  int generation = 0, retries = 0, tab = 0, maxTrades = 6, requestId = 100;
  bool connecting = false, connected = false, authenticated = false;
  bool autoScan = true, autoReconnect = true, orderPending = false;
  String status = 'OFFLINE', selected = 'R_25', strategy = 'Matches';
  String token = '', account = '', currency = 'USD', orderMessage = '';
  double balance = 0, stake = 0.35, sessionLossLimit = 2.0;
  DateTime sessionStart = DateTime.now();

  Market get current => markets.firstWhere((m) => m.symbol == selected);
  int get completedTrades => trades.where((t) => t.status == 'CLOSED').length;
  double get realizedPnL => trades.where((t) => t.status == 'CLOSED')
      .fold(0.0, (double total, t) => total + (t.profit ?? 0));
  int get lossStreak {
    int n = 0;
    for (final trade in trades) {
      if (trade.status != 'CLOSED') { continue; }
      if ((trade.profit ?? 0) >= 0) { break; }
      n++;
    }
    return n;
  }
  bool get riskBlocked => trades.length >= maxTrades ||
      realizedPnL <= -sessionLossLimit || lossStreak >= 2 ||
      trades.any((t) => t.status == 'OPEN');

  @override
  void initState() {
    super.initState();
    _load();
    _connect();
    heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!connected) return;
      _send({'ping': 1});
      final last = markets.where((m) => m.seen != null).map((m) => m.seen!).toList();
      if (last.isNotEmpty && DateTime.now().difference(last.reduce((a, b) => a.isAfter(b) ? a : b)).inSeconds > 40) {
        _disconnect();
      }
    });
    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      for (final m in markets) {
        if (m.seen != null && DateTime.now().difference(m.seen!).inSeconds > 15) m.live = false;
        // Expired predictions remain pending until a fresh broker tick arrives.
        if (autoScan && m.live && m.prediction == null && m.ticks.length >= 60) _predict(m);
      }
      setState(() {});
    });
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final savedToken = await secure.read(key: 'deriv_demo_token') ?? '';
    if (!mounted) return;
    setState(() {
      token = savedToken;
      autoScan = p.getBool('scan') ?? true;
      autoReconnect = p.getBool('reconnect') ?? true;
      stake = p.getDouble('stake') ?? 0.35;
      sessionLossLimit = p.getDouble('limit') ?? 2.0;
      maxTrades = p.getInt('maxTrades') ?? 6;
      journalInput.text = p.getString('journal') ?? '';
      for (final s in p.getStringList('results') ?? <String>[]) {
        try { results.add(Observation.fromJson(jsonDecode(s) as Map<String, dynamic>)); } catch (_) {}
      }
    });
    if (connected && token.isNotEmpty) _authorize();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('scan', autoScan);
    await p.setBool('reconnect', autoReconnect);
    await p.setDouble('stake', stake);
    await p.setDouble('limit', sessionLossLimit);
    await p.setInt('maxTrades', maxTrades);
    await p.setString('journal', journalInput.text);
    await p.setStringList('results', results.take(300).map((e) => jsonEncode(e.toJson())).toList());
  }

  void _alert(String message) {
    alerts.insert(0, '${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')} • $message');
    if (alerts.length > 100) alerts.removeLast();
  }

  void _send(Map<String, dynamic> data) {
    if (!connected) return;
    try { ws?.sink.add(jsonEncode(data)); } catch (_) { _disconnect(); }
  }

  Future<Map<String, dynamic>> _request(Map<String, dynamic> data) async {
    if (!connected) throw StateError('WebSocket disconnected');
    final id = ++requestId;
    final c = Completer<Map<String, dynamic>>();
    pending[id] = c;
    _send({...data, 'req_id': id});
    try { return await c.future.timeout(const Duration(seconds: 20)); }
    finally { pending.remove(id); }
  }

  Future<void> _connect() async {
    if (!mounted || connecting || connected) return;
    retry?.cancel();
    connecting = true;
    final g = ++generation;
    setState(() => status = 'CONNECTING');
    try {
      final channel = WebSocketChannel.connect(Uri.parse('wss://ws.derivws.com/websockets/v3?app_id=1089'));
      await channel.ready.timeout(const Duration(seconds: 15));
      if (!mounted || g != generation) { await channel.sink.close(); return; }
      ws = channel;
      connected = true;
      subscription = channel.stream.listen((raw) => _message(raw, g),
        onDone: () => _disconnect(g), onError: (_) => _disconnect(g));
      retries = 0;
      setState(() => status = 'PUBLIC LIVE');
      for (final m in markets) { _send({'ticks': m.symbol, 'subscribe': 1}); }
      if (token.isNotEmpty) await _authorize();
    } catch (e) {
      if (g == generation) _disconnect(g);
    } finally { connecting = false; }
  }

  void _disconnect([int? g]) {
    if (!mounted || (g != null && g != generation)) return;
    generation++;
    connected = false;
    authenticated = false;
    account = '';
    for (final c in pending.values) {
      if (!c.isCompleted) c.completeError(StateError('Connection lost'));
    }
    pending.clear();
    subscription?.cancel();
    ws?.sink.close();
    ws = null;
    contractSubscriptions.clear();
    for (final m in markets) { m.live = false; m.prediction = null; }
    setState(() => status = autoReconnect ? 'RECONNECTING' : 'OFFLINE');
    retry?.cancel();
    if (autoReconnect) {
      retry = Timer(Duration(seconds: min(30, 2 << min(retries++, 4))), _connect);
    }
  }

  Future<void> _authorize() async {
    if (token.isEmpty || !connected) return;
    try {
      final response = await _request({'authorize': token});
      final a = response['authorize'];
      if (a is! Map) throw StateError('No authorization response');
      if (a['is_virtual'] != 1 && a['is_virtual'] != true) {
        throw StateError('Only demo tokens are supported');
      }
      if (!mounted) return;
      setState(() {
        authenticated = true;
        account = '${a['loginid'] ?? 'Demo'}';
        currency = '${a['currency'] ?? 'USD'}';
        balance = (a['balance'] as num?)?.toDouble() ?? 0;
        status = 'DEMO CONNECTED';
        orderMessage = '';
      });
      _send({'balance': 1, 'subscribe': 1});
      // Re-subscribe after a reconnect to recover settlement updates.
      for (final t in trades.where((t) => t.status == 'OPEN')) {
        _subscribeContract(t.id);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { authenticated = false; orderMessage = 'Demo authorization failed: $e'; });
      _alert('Demo authorization failed');
    }
  }

  void _subscribeContract(int id) {
    if (!authenticated || !contractSubscriptions.add(id)) return;
    _send({'proposal_open_contract': 1, 'contract_id': id, 'subscribe': 1});
  }

  void _message(dynamic raw, int g) {
    if (!mounted || g != generation) return;
    try {
      final j = jsonDecode(raw as String) as Map<String, dynamic>;
      final id = j['req_id'];
      if (id is int && pending.containsKey(id)) {
        final c = pending[id]!;
        if (!c.isCompleted) {
          if (j['error'] != null) { c.completeError(StateError('${j['error']['message']}')); }
          else { c.complete(j); }
        }
      }
      if (j['error'] != null) {
        _alert('${j['error']['message']}');
        setState(() {});
        return;
      }
      switch (j['msg_type']) {
        case 'tick':
          final t = j['tick'] as Map<String, dynamic>;
          final sym = '${t['symbol']}';
          Market? m;
          for (final candidate in markets) { if (candidate.symbol == sym) { m = candidate; break; } }
          if (m == null) return;
          final price = (t['quote'] as num).toDouble();
          final epoch = (t['epoch'] as num).toInt();
          m.precision = (t['pip_size'] as num?)?.toInt() ?? m.precision;
          final formatted = price.toStringAsFixed(m.precision.clamp(0, 10));
          final digit = int.parse(formatted.substring(formatted.length - 1));
          if (m.ticks.isNotEmpty && m.ticks.last.epoch == epoch && m.ticks.last.price == price) return;
          m.ticks.add(Tick(price, epoch, digit));
          if (m.ticks.length > 250) m.ticks.removeAt(0);
          m.seen = DateTime.now();
          m.live = true;
          _analyze(m);
          _settle(m);
          if (autoScan && m.prediction == null && m.ticks.length >= 60) _predict(m);
          setState(() {});
          break;
        case 'balance':
          final b = j['balance'];
          if (b is Map) setState(() => balance = (b['balance'] as num?)?.toDouble() ?? balance);
          break;
        case 'proposal_open_contract':
          final p = j['proposal_open_contract'];
          if (p is Map) {
            final contractId = (p['contract_id'] as num?)?.toInt();
            if (contractId != null) {
              for (final t in trades.where((x) => x.id == contractId && x.status == 'OPEN')) {
                if (p['is_sold'] == 1 || p['is_sold'] == true) {
                  t.status = 'CLOSED';
                  t.profit = (p['profit'] as num?)?.toDouble() ?? 0;
                  contractSubscriptions.remove(contractId);
                  _alert('${t.symbol}: ${t.profit! >= 0 ? 'PROFIT' : 'LOSS'} ${t.profit!.toStringAsFixed(2)} $currency');
                }
              }
              setState(() {});
            }
          }
          break;
      }
    } catch (e) {
      _alert('Data processing warning: $e');
    }
  }

  double _ema(List<double> a, int n) {
    if (a.isEmpty) return 0;
    var v = a.first;
    final k = 2 / (n + 1);
    for (final x in a.skip(1)) { v = x * k + v * (1 - k); }
    return v;
  }

  void _analyze(Market m) {
    final a = m.ticks.map((e) => e.price).toList();
    if (a.length < 50) return;
    final e20 = _ema(a, 20), e50 = _ema(a, 50);
    m.trend = e20 > e50 ? 'UP' : e20 < e50 ? 'DOWN' : 'SIDEWAYS';
    double gains = 0, losses = 0, movement = 0;
    for (int i = a.length - 14; i < a.length; i++) {
      final d = a[i] - a[i - 1];
      if (d > 0) { gains += d; } else { losses -= d; }
      movement += d.abs();
    }
    m.rsi = gains == 0 && losses == 0 ? 50 : losses == 0 ? 100 : 100 - 100 / (1 + gains / losses);
    m.macd = _ema(a, 12) - _ema(a, 26);
    m.movement = movement / 14;
    final agreement = (e20 > e50 && m.macd > 0) || (e20 < e50 && m.macd < 0);
    m.score = (40 + (agreement ? 25 : 0) + (m.rsi > 35 && m.rsi < 65 ? 15 : 0) + (m.movement > 0 ? 10 : 0)).toDouble();
  }

  void _predict(Market m) {
    if (!m.live || m.ticks.length < 60 || m.prediction != null) return;
    // Frequency is descriptive, not a validated forecast of the next digit.
    final counts = m.counts;
    int mostCommon = 0;
    for (int i = 1; i < 10; i++) { if (counts[i] > counts[mostCommon]) mostCommon = i; }
    int digit = mostCommon;
    if (strategy == 'Even/Odd') {
      final even = m.ticks.where((t) => t.digit.isEven).length;
      digit = even >= m.ticks.length - even ? 0 : 1;
    }
    if (strategy == 'Over' || strategy == 'Under') digit = 4;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    m.prediction = Prediction(strategy, digit, now, now + 10);
  }

  void _settle(Market m) {
    final p = m.prediction;
    if (p == null || m.ticks.isEmpty) return;
    // First tick received at/after the wall-clock 10-second expiry.
    if (DateTime.now().millisecondsSinceEpoch ~/ 1000 < p.expiresAt) return;
    final last = m.ticks.last;
    if (last.epoch < p.startedAt) return;
    final actual = last.digit;
    final correct = switch (p.strategy) {
      'Matches' => actual == p.digit,
      'Differs' => actual != p.digit,
      'Even/Odd' => actual.isEven == p.digit.isEven,
      'Over' => actual > p.digit,
      'Under' => actual < p.digit,
      _ => false,
    };
    results.insert(0, Observation(m.symbol, p.strategy, p.digit, actual, last.epoch, correct));
    if (results.length > 300) results.removeLast();
    _alert('${m.name}: ${correct ? 'CORRECT' : 'INCORRECT'} • ${p.strategy} ${p.digit} → $actual');
    m.prediction = null;
    _save();
  }

  Future<void> _login(String value) async {
    final v = value.trim();
    if (v.isEmpty) { setState(() => orderMessage = 'Enter your demo API token first'); return; }
    // Never save an unverified token as an authenticated session.
    await secure.write(key: 'deriv_demo_token', value: v);
    token = v;
    tokenInput.clear();
    if (connected) { await _authorize(); } else { await _connect(); }
  }

  Future<void> _logout() async {
    await secure.delete(key: 'deriv_demo_token');
    token = '';
    authenticated = false;
    account = '';
    _disconnect();
    retry?.cancel();
    await _connect();
  }

  Future<void> _buy() async {
    if (orderPending || !authenticated || riskBlocked) {
      setState(() => orderMessage = 'Not authenticated or risk limit reached');
      return;
    }
    final m = current;
    if (!m.live) { setState(() => orderMessage = 'Market feed unavailable'); return; }
    if (!stake.isFinite || stake <= 0) { setState(() => orderMessage = 'Invalid stake'); return; }
    final p = m.prediction;
    if (p == null || DateTime.now().millisecondsSinceEpoch ~/ 1000 >= p.expiresAt) {
      setState(() => orderMessage = 'Refresh and wait for a current observation');
      return;
    }
    final type = switch (strategy) {
      'Matches' => 'DIGITMATCH', 'Differs' => 'DIGITDIFF',
      'Even/Odd' => p.digit.isEven ? 'DIGITEVEN' : 'DIGITODD',
      'Over' => 'DIGITOVER', _ => 'DIGITUNDER',
    };
    setState(() { orderPending = true; orderMessage = 'Requesting demo quote...'; });
    try {
      final request = <String, dynamic>{
        'proposal': 1, 'amount': stake, 'basis': 'stake',
        'contract_type': type, 'currency': currency,
        'duration': 1, 'duration_unit': 't', 'symbol': m.symbol,
      };
      if (type != 'DIGITEVEN' && type != 'DIGITODD') request['barrier'] = '${p.digit}';
      final response = await _request(request);
      final proposal = response['proposal'];
      if (proposal is! Map || proposal['id'] == null) throw StateError('No valid broker proposal');
      final ask = (proposal['ask_price'] as num?)?.toDouble();
      if (ask == null || ask <= 0 || ask > stake * 1.05) throw StateError('Invalid or excessive quote');
      if (!authenticated || riskBlocked) throw StateError('Risk or authentication changed');
      setState(() => orderMessage = 'Submitting demo order...');
      final buy = await _request({'buy': proposal['id'], 'price': ask});
      final confirmed = buy['buy'];
      if (confirmed is! Map || confirmed['contract_id'] == null) throw StateError('Broker did not confirm order');
      final id = (confirmed['contract_id'] as num).toInt();
      trades.insert(0, Trade(id, m.symbol, type, ask));
      _subscribeContract(id);
      setState(() => orderMessage = 'Demo order confirmed • #$id');
    } catch (e) {
      if (mounted) setState(() => orderMessage = 'Order not confirmed: $e');
    } finally {
      if (mounted) setState(() => orderPending = false);
    }
  }

  @override
  void dispose() {
    generation++;
    retry?.cancel(); heartbeat?.cancel(); clock?.cancel();
    subscription?.cancel(); ws?.sink.close();
    tokenInput.dispose(); journalInput.dispose();
    super.dispose();
  }

  Widget card(Widget child) => Container(
    width: double.infinity, margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(18),
      border: Border.all(color: cyan.withValues(alpha: .18))), child: child,
  );
  Widget pill(String s, {Color color = cyan}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: color.withValues(alpha: .13), borderRadius: BorderRadius.circular(24)),
    child: Text(s, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold)),
  );
  Widget metric(String label, String value) => Expanded(child: card(Column(children: [
    Text(value, style: const TextStyle(fontSize: 22, color: cyan, fontWeight: FontWeight.bold)),
    Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: Colors.white70)),
  ])));
  int remaining(Market m) => m.prediction == null ? 0 : max(0, m.prediction!.expiresAt - DateTime.now().millisecondsSinceEpoch ~/ 1000);

  Widget marketCard(Market m) {
    final p = m.prediction;
    return card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Expanded(child: Text(m.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold))),
        pill(m.live ? 'LIVE' : 'WAIT', color: m.live ? green : Colors.orange)]),
      const SizedBox(height: 12),
      Row(children: [
        Container(width: 70, height: 70, alignment: Alignment.center,
          decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xff1765b4)),
          child: Text('${p?.digit ?? '—'}', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold))),
        const SizedBox(width: 15),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${p?.strategy ?? strategy} • ${p == null ? 'Waiting for data' : '10-second observation'}',
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Text('Trend ${m.trend} • Score ${m.score.toStringAsFixed(0)}/100'),
          Text('${m.ticks.length} ticks • ${p == null ? '—' : '${remaining(m)}s left'}',
            style: const TextStyle(color: Colors.white60, fontSize: 12)),
        ])),
      ]),
      const SizedBox(height: 9),
      if (p != null) LinearProgressIndicator(value: remaining(m) / 10, minHeight: 5, color: cyan, backgroundColor: Colors.white12),
      const SizedBox(height: 8),
      const Text('Indicator score is not a probability of winning.', style: TextStyle(fontSize: 10, color: Colors.white54)),
    ]));
  }

  Widget radar() {
    final live = markets.where((m) => m.live).length;
    final accuracy = results.isEmpty ? '—' : '${(100 * results.where((r) => r.correct).length / results.length).toStringAsFixed(1)}%';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [pill(status, color: connected ? green : Colors.orange), const Spacer(), Text('$live/10 feeds')]),
      const SizedBox(height: 14),
      const Text('Market Radar', style: TextStyle(fontSize: 27, fontWeight: FontWeight.bold)),
      const Text('Live market monitoring • demo-only execution', style: TextStyle(color: Colors.white70)),
      const SizedBox(height: 12),
      Row(children: [metric('OBSERVED ACCURACY', accuracy), const SizedBox(width: 8), metric('OBSERVATIONS', '${results.length}')]),
      Row(children: [metric('LIVE MARKETS', '$live'), const SizedBox(width: 8), metric('DEMO BALANCE', authenticated ? '${balance.toStringAsFixed(2)} $currency' : '—')]),
      Wrap(spacing: 6, runSpacing: 6, children: ['Matches', 'Differs', 'Even/Odd', 'Over', 'Under']
        .map((s) => ChoiceChip(label: Text(s), selected: strategy == s, onSelected: (_) => setState(() {
          strategy = s;
          for (final m in markets) { m.prediction = null; }
        }))).toList()),
      const SizedBox(height: 12),
      ...markets.map(marketCard),
    ]);
  }

  Widget marketSelector() => DropdownButton<String>(value: selected, isExpanded: true,
    items: markets.map((m) => DropdownMenuItem(value: m.symbol, child: Text(m.name))).toList(),
    onChanged: (v) => setState(() => selected = v!));

  Widget analyzer() {
    final m = current, c = m.counts;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Expert Analyzer', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
      card(marketSelector()),
      card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Text(m.name, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold))),
          pill(m.live ? 'LIVE' : 'WAIT', color: m.live ? green : Colors.orange)]),
        const SizedBox(height: 12),
        Text('Trend ${m.trend} • Indicator score ${m.score.toStringAsFixed(0)}/100', style: const TextStyle(color: cyan)),
        Text('RSI(14): ${m.rsi.toStringAsFixed(1)}   MACD: ${m.macd.toStringAsFixed(5)}'),
        Text('Average tick movement: ${m.movement.toStringAsFixed(5)}'),
        Text('Latest digit: ${m.lastDigit ?? '—'} • Observation: ${m.prediction?.digit ?? '—'}'),
        Text('Observation countdown: ${remaining(m)}s', style: const TextStyle(color: green)),
        const SizedBox(height: 12),
        SizedBox(height: 125, child: CustomPaint(painter: Spark(m.ticks.map((e) => e.price).toList()), child: const SizedBox.expand())),
        const Text('Tick chart; indicators are tick-based, not candle-based.', style: TextStyle(fontSize: 11, color: Colors.white60)),
      ])),
      card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Digit distribution', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
        for (int i = 0; i < 10; i++) Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Row(children: [
          SizedBox(width: 22, child: Text('$i')),
          Expanded(child: LinearProgressIndicator(value: m.ticks.isEmpty ? 0 : c[i] / m.ticks.length,
            minHeight: 8, color: cyan, backgroundColor: Colors.white12)),
          const SizedBox(width: 9),
          SizedBox(width: 52, child: Text(m.ticks.isEmpty ? '—' : '${(100 * c[i] / m.ticks.length).toStringAsFixed(1)}%')),
        ])),
      ])),
      card(Text('Even: ${m.ticks.isEmpty ? '—' : '${(100 * m.ticks.where((x) => x.digit.isEven).length / m.ticks.length).toStringAsFixed(1)}%'}   '
          'Odd: ${m.ticks.isEmpty ? '—' : '${(100 * m.ticks.where((x) => x.digit.isOdd).length / m.ticks.length).toStringAsFixed(1)}%'}')),
      FilledButton(onPressed: m.live && m.ticks.length >= 60 ? () => setState(() {
        m.prediction = null;
        _predict(m);
      }) : null, child: const Text('REFRESH 10-SECOND OBSERVATION')),
    ]);
  }

  Widget tradePage() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Demo Trades', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
    card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      pill(authenticated ? 'DEMO AUTHENTICATED' : 'NOT AUTHENTICATED', color: authenticated ? green : Colors.orange),
      const SizedBox(height: 10),
      Text('Account: ${authenticated ? account : 'Connect in Settings'}'),
      Text('Balance: ${authenticated ? '${balance.toStringAsFixed(2)} $currency' : '—'}'),
      Text('Session realized P/L: ${realizedPnL.toStringAsFixed(2)} $currency'),
      Text('Orders: ${trades.length} / $maxTrades • Loss streak: $lossStreak / 2'),
      const SizedBox(height: 10), marketSelector(),
      DropdownButton<String>(value: strategy, isExpanded: true,
        items: ['Matches', 'Differs', 'Even/Odd', 'Over', 'Under'].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
        onChanged: (v) => setState(() { strategy = v!; for (final m in markets) { m.prediction = null; } })),
      Text('Digit: ${current.prediction?.digit ?? 'Waiting'} • Stake: ${stake.toStringAsFixed(2)} $currency'),
      const SizedBox(height: 10),
      FilledButton(onPressed: authenticated && !orderPending && current.live && !riskBlocked ? _buy : null,
        child: Text(orderPending ? 'WAITING FOR BROKER...' : 'BUY DEMO CONTRACT')),
      const SizedBox(height: 8),
      Text(orderMessage, style: const TextStyle(fontSize: 12, color: Colors.amber)),
      const Text('Orders are manually submitted. Demo accounts only.', style: TextStyle(fontSize: 11, color: Colors.white60)),
    ])),
    const Text('Broker-confirmed contracts', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
    if (trades.isEmpty) card(const Text('No orders placed this session.')),
    ...trades.map((t) => card(Text('#${t.id} • ${t.symbol} • ${t.type}\n'
      '${t.status} • Stake ${t.stake.toStringAsFixed(2)} • P/L ${t.profit?.toStringAsFixed(2) ?? 'Pending'}'))),
  ]);

  Widget history() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Observation History', style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
    const Text('These are timed observations, not broker trades.', style: TextStyle(color: Colors.white70)),
    if (results.isEmpty) card(const Text('No completed observations yet.')),
    ...results.take(100).map((r) => card(Text('${r.symbol} • ${r.strategy} • ${r.correct ? 'CORRECT' : 'INCORRECT'}\n'
      'Predicted ${r.predicted} • Actual ${r.actual} • Epoch ${r.epoch}', style: TextStyle(color: r.correct ? green : red)))),
  ]);

  Widget journalPage() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Journal', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
    Row(children: [metric('OBSERVATIONS', '${results.length}'), const SizedBox(width: 8),
      metric('CORRECT', '${results.where((r) => r.correct).length}')]),
    card(Text('Confirmed demo contracts: ${trades.length}\nSession realized P/L: ${realizedPnL.toStringAsFixed(2)} $currency')),
    card(TextField(controller: journalInput, maxLines: 5, decoration: const InputDecoration(labelText: 'Trading notes'))),
    FilledButton(onPressed: () async {
      await _save();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Journal saved')));
    }, child: const Text('SAVE JOURNAL')),
  ]);

  Widget alertsPage() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Alerts', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
    if (alerts.isEmpty) card(const Text('No alerts yet.')),
    ...alerts.take(80).map((a) => card(Text(a))),
  ]);

  Widget settings() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Settings', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
    card(Column(children: [
      SwitchListTile(title: const Text('Automatic observations'), value: autoScan,
        onChanged: (v) { setState(() => autoScan = v); _save(); }),
      SwitchListTile(title: const Text('Automatic reconnection'), value: autoReconnect,
        onChanged: (v) { setState(() => autoReconnect = v); _save(); }),
      const ListTile(title: Text('Execution mode'), subtitle: Text('Demo only • manual orders • no real-money execution')),
    ])),
    card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Deriv demo API token', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      const Text('Use a demo token with trading permission. Never commit tokens to GitHub.',
        style: TextStyle(fontSize: 12, color: Colors.white70)),
      TextField(controller: tokenInput, obscureText: true, autocorrect: false,
        enableSuggestions: false, decoration: const InputDecoration(labelText: 'Demo token', border: OutlineInputBorder()),
        onSubmitted: _login),
      const SizedBox(height: 10),
      Wrap(spacing: 8, children: [
        FilledButton(onPressed: () => _login(tokenInput.text), child: const Text('CONNECT DEMO')),
        TextButton(onPressed: _logout, child: const Text('LOG OUT')),
      ]),
      Text('Status: $status • ${authenticated ? account : 'Public data'}'),
      if (orderMessage.isNotEmpty) Text(orderMessage, style: const TextStyle(fontSize: 12, color: Colors.amber)),
    ])),
    card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Risk controls', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      TextFormField(initialValue: stake.toString(), keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Stake (account currency)'),
        onChanged: (v) { final n = double.tryParse(v); if (n != null && n.isFinite && n > 0) { stake = n; _save(); } }),
      TextFormField(initialValue: sessionLossLimit.toString(), keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Session loss limit'),
        onChanged: (v) { final n = double.tryParse(v); if (n != null && n.isFinite && n > 0) { sessionLossLimit = n; _save(); } }),
      TextFormField(initialValue: maxTrades.toString(), keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Max orders per session'),
        onChanged: (v) { final n = int.tryParse(v); if (n != null && n > 0) { maxTrades = n; _save(); } }),
      const Text('Additional safety: stop after 2 consecutive losses or while a contract remains open.',
        style: TextStyle(fontSize: 11, color: Colors.white60)),
    ])),
    FilledButton(onPressed: () { _disconnect(); retry?.cancel(); _connect(); }, child: const Text('RECONNECT')),
  ]);

  @override
  Widget build(BuildContext context) {
    final pages = [radar, analyzer, tradePage, history, journalPage, alertsPage, settings];
    final names = ['Radar', 'Analyzer', 'Trades', 'History', 'Journal', 'Alerts', 'Settings'];
    final icons = [Icons.radar, Icons.analytics, Icons.swap_horiz, Icons.history,
      Icons.article, Icons.notifications, Icons.settings];
    return Scaffold(
      appBar: AppBar(backgroundColor: panel, title: const Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('V13 Expert Trader PRO', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
          Text('Deriv • Live analytics + demo trading', style: TextStyle(fontSize: 11, color: Colors.white70)),
        ]), actions: [Padding(padding: const EdgeInsets.only(right: 10),
          child: Center(child: pill(authenticated ? 'DEMO' : 'PUBLIC', color: authenticated ? green : cyan)))]),
      body: SafeArea(child: Column(children: [
        Expanded(child: ListView(padding: const EdgeInsets.all(14), children: [pages[tab]()])),
        Container(height: 70, color: panel, child: ListView(scrollDirection: Axis.horizontal,
          children: List.generate(names.length, (i) => InkWell(
            onTap: () => setState(() => tab = i),
            child: SizedBox(width: max(66, MediaQuery.sizeOf(context).width / 5.4),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icons[i], color: tab == i ? cyan : Colors.white60),
                const SizedBox(height: 4),
                Text(names[i], style: TextStyle(fontSize: 10, color: tab == i ? cyan : Colors.white70)),
              ])),
          )))),
      ])),
    );
  }
}

class Spark extends CustomPainter {
  final List<double> data;
  Spark(this.data);
  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final a = data.length > 100 ? data.sublist(data.length - 100) : data;
    final lo = a.reduce(min), hi = a.reduce(max), range = max(hi - lo, 0.0000001);
    final path = Path();
    for (int i = 0; i < a.length; i++) {
      final x = i * size.width / (a.length - 1);
      final y = size.height - (a[i] - lo) / range * size.height;
      if (i == 0) { path.moveTo(x, y); } else { path.lineTo(x, y); }
    }
    canvas.drawPath(path, Paint()..color = cyan..strokeWidth = 2..style = PaintingStyle.stroke);
  }
  @override
  bool shouldRepaint(covariant Spark oldDelegate) => true;
}
