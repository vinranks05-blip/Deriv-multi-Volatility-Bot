import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

void main() => runApp(const ExpertApp());
const symbols = ['R_10', 'R_25', 'R_50', 'R_75', 'R_100'];
const bg = Color(0xFF0A1020);
const surface = Color(0xFF17243B);
const accent = Color(0xFF5399FF);

class ExpertApp extends StatelessWidget {
  const ExpertApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'V9 Expert Trader',
    theme: ThemeData(useMaterial3: true, brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark),
      scaffoldBackgroundColor: bg),
    home: const ExpertHome(),
  );
}

class Broker {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _listener;
  Timer? _heartbeat;
  final _waiting = <int, Completer<Map<String, dynamic>>>{};
  int _next = 0;
  bool connected = false;
  String? account;
  String accountType = 'demo';
  void Function(String)? onDisconnect;
  void Function(Map<String, dynamic>)? onTick;
  final subscriptions = <String, String>{};

  Future<void> connect(String appId, String pat, {String mode = 'demo'}) async {
    await close();
    final headers = {'Authorization': 'Bearer $pat', 'Deriv-App-ID': appId};
    const root = 'https://api.derivws.com';
    final accounts = await http.get(Uri.parse('$root/trading/v1/options/accounts'), headers: headers)
        .timeout(const Duration(seconds: 20));
    if (accounts.statusCode != 200) throw StateError('Account HTTP ${accounts.statusCode}');
    final payload = jsonDecode(accounts.body);
    final data = payload is Map ? payload['data'] : null;
    final list = data is List ? data : data is Map ? data['accounts'] : null;
    if (list is! List) throw StateError('Options accounts unavailable');
    Map? chosen;
    for (final item in list) {
      if (item is Map && '${item['account_type']}'.toLowerCase() == mode) { chosen = item; break; }
    }
    if (chosen == null) throw StateError('No $mode Options account found');
    final id = '${chosen['account_id'] ?? chosen['id'] ?? ''}';
    if (id.isEmpty) throw StateError('$mode account ID missing');
    final otp = await http.post(Uri.parse('$root/trading/v1/options/accounts/${Uri.encodeComponent(id)}/otp'), headers: headers)
        .timeout(const Duration(seconds: 20));
    if (otp.statusCode != 200) throw StateError('Demo OTP HTTP ${otp.statusCode}');
    final otpBody = jsonDecode(otp.body);
    final url = otpBody is Map && otpBody['data'] is Map ? otpBody['data']['url']?.toString() : null;
    if (url == null) throw StateError('Demo socket URL missing');
    final uri = Uri.parse(url);
    if (uri.scheme != 'wss' || uri.host != 'api.derivws.com' || uri.path != '/trading/v1/options/ws/$mode') {
      throw StateError('Unexpected socket destination');
    }
    try {
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready.timeout(const Duration(seconds: 20));
      connected = true;
      account = id;
      accountType = mode;
      _listener = _channel!.stream.listen((raw) {
        try {
          final decoded = jsonDecode(raw as String);
          if (decoded is! Map) return;
          final msg = Map<String, dynamic>.from(decoded);
          if (msg['msg_type'] == 'tick') onTick?.call(msg);
          final reqId = int.tryParse('${msg['req_id']}');
          final completer = reqId == null ? null : _waiting.remove(reqId);
          if (completer != null && !completer.isCompleted) {
            if (msg['error'] != null) { completer.completeError(StateError('${msg['error']}')); }
            else { completer.complete(msg); }
          }
        } catch (_) {}
      }, onError: (_) => _lost('Network error'), onDone: () => _lost('Socket closed'));
      _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
        if (connected) unawaited(request({'ping': 1}).catchError((Object _) { _lost('Heartbeat failed'); return <String, dynamic>{}; }));
      });
    } catch (_) { await close(); rethrow; }
  }

  void _lost(String message) {
    if (!connected) return;
    connected = false;
    _heartbeat?.cancel();
    subscriptions.clear();
    for (final c in _waiting.values) { if (!c.isCompleted) c.completeError(StateError(message)); }
    _waiting.clear();
    onDisconnect?.call(message);
  }

  Future<Map<String, dynamic>> request(Map<String, dynamic> payload) async {
    if (!connected || _channel == null) throw StateError('Connect an account first');
    final id = ++_next;
    final c = Completer<Map<String, dynamic>>();
    _waiting[id] = c;
    try {
      _channel!.sink.add(jsonEncode({...payload, 'req_id': id}));
      return await c.future.timeout(const Duration(seconds: 22));
    } finally { _waiting.remove(id); }
  }

  Future<void> subscribe(String symbol) async {
    final reply = await request({'ticks': symbol, 'subscribe': 1});
    if (reply['tick'] is! Map) throw StateError('Tick subscription failed for $symbol');
    final sub = reply['subscription'];
    if (sub is Map && sub['id'] != null) subscriptions[symbol] = '${sub['id']}';
    onTick?.call(reply);
  }

  Future<void> close() async {
    connected = false;
    account = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    subscriptions.clear();
    for (final c in _waiting.values) { if (!c.isCompleted) c.completeError(StateError('Disconnected')); }
    _waiting.clear();
    await _listener?.cancel();
    _listener = null;
    await _channel?.sink.close();
    _channel = null;
  }
}

class MarketState {
  final String symbol;
  final Queue<int> digits = Queue<int>();
  final Queue<double> prices = Queue<double>();
  int? precision;
  int? lastDigit;
  double? lastPrice;
  int? lastEpoch;
  DateTime? received;
  int tickSequence = 0;
  MarketState(this.symbol);
  bool get fresh => received != null && DateTime.now().difference(received!).inSeconds < 15;
  int get total => digits.length;
  List<int> get counts {
    final c = List<int>.filled(10, 0);
    for (final n in digits) { c[n]++; }
    return c;
  }
  int? get frequentDigit {
    if (total < 100) return null;
    final c = counts;
    var best = 0;
    for (var i = 1; i < 10; i++) { if (c[i] > c[best]) best = i; }
    return best;
  }
  double get frequentRate {
    final d = frequentDigit;
    return d == null ? 0 : counts[d] * 100 / total;
  }
  String get trend {
    if (prices.length < 30) return 'COLLECTING';
    final p = prices.toList();
    final a = p.sublist(p.length - 10).reduce((x, y) => x + y) / 10;
    final b = p.sublist(p.length - 30).reduce((x, y) => x + y) / 30;
    final movement = p.last - p[p.length - 30];
    final noise = p.skip(1).toList().asMap().entries.fold<double>(0, (sum, e) => sum + (e.value - p[e.key]).abs()) / (p.length - 1);
    if (noise == 0 || (a - b).abs() < noise * 0.65) return 'SIDEWAYS';
    return a > b && movement > 0 ? 'UP ↗' : a < b && movement < 0 ? 'DOWN ↘' : 'MIXED';
  }
  void record(double price, int digit, int epoch) {
    lastPrice = price;
    lastDigit = digit;
    lastEpoch = epoch;
    received = DateTime.now();
    tickSequence++;
    prices.addLast(price);
    digits.addLast(digit);
    while (prices.length > 240) { prices.removeFirst(); }
    while (digits.length > 1000) { digits.removeFirst(); }
  }
}

class Observation {
  final String market, strategy;
  final int barrier, sequenceAtStart;
  final DateTime started, deadline;
  int? actualDigit, actualEpoch;
  bool? won;
  String status = 'WAITING';
  Observation(this.market, this.strategy, this.barrier, this.sequenceAtStart, this.started)
      : deadline = started.add(const Duration(seconds: 10));
  int get remaining => max(0, deadline.difference(DateTime.now()).inMilliseconds.ceil() ~/ 1000);
  bool get pending => status == 'WAITING';
}

class TradeRecord {
  final String market, direction, id;
  final double stake;
  String status = 'OPEN';
  double profit = 0;
  TradeRecord(this.market, this.direction, this.id, this.stake);
}

class ExpertHome extends StatefulWidget {
  const ExpertHome({super.key});
  @override
  State<ExpertHome> createState() => _ExpertHomeState();
}

class _ExpertHomeState extends State<ExpertHome> with WidgetsBindingObserver {
  final broker = Broker();
  final appId = TextEditingController();
  final pat = TextEditingController();
  final states = {for (final s in symbols) s: MarketState(s)};
  final observations = <Observation>[];
  final trades = <TradeRecord>[];
  Timer? clock;
  bool connecting = false, loading = false, orderBusy = false, unresolvedOrder = false;
  bool foreground = true, emergencyStopped = false;
  String mode = 'demo';
  bool realArmed = false;
  String selected = 'R_25', strategy = 'Matches', status = 'Disconnected';
  int barrier = 5, tab = 0, tradeCount = 0, consecutiveLosses = 0;
  double stake = 0.35, pnl = 0;
  String? activeContract;
  DateTime? lastOrder;
  final precision = <String, int>{};
  final seen = <String, String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    broker.onTick = handleTick;
    broker.onDisconnect = (message) {
      if (!mounted) return;
      setState(() { status = message; realArmed = false; unresolvedOrder = activeContract != null || orderBusy; });
    };
    clock = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted && foreground) setState(() {});
    });
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground && mounted) setState(() { realArmed = false; status = 'Paused in background • no new orders'; });
    if (foreground && broker.connected && mounted) setState(() => status = '${mode.toUpperCase()} connected');
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    clock?.cancel();
    unawaited(broker.close());
    appId.dispose();
    pat.dispose();
    super.dispose();
  }
  void message(String value) { if (mounted) setState(() => status = value); }
  int? parsePrecision(dynamic raw) {
    if (raw == null) return null;
    final text = '$raw';
    final i = int.tryParse(text);
    if (i != null && i >= 0 && i <= 10) return i;
    final value = double.tryParse(text);
    if (value == null || value <= 0 || value >= 1) return null;
    final normalized = value.toStringAsFixed(10).replaceFirst(RegExp(r'0+$'), '');
    return normalized.split('.').length == 2 ? normalized.split('.').last.length : null;
  }
  int? lastDigit(dynamic price, int places) {
    final number = double.tryParse('$price');
    if (number == null || !number.isFinite) return null;
    final formatted = number.toStringAsFixed(places);
    return int.tryParse(formatted.substring(formatted.length - 1));
  }
  Future<void> connect() async {
    if (connecting || broker.connected) return;
    if (appId.text.trim().isEmpty || pat.text.trim().isEmpty) { message('Enter App ID and a PAT authorized for the selected account'); return; }
    setState(() { connecting = true; status = 'Connecting to ${mode.toUpperCase()}…'; });
    try {
      await broker.connect(appId.text.trim(), pat.text.trim(), mode: mode);
      if (!mounted) return;
      message('${mode.toUpperCase()} connected • ${broker.account}');
      await loadMarkets();
    } catch (e) { message('Connection failed: $e'); }
    finally { if (mounted) setState(() => connecting = false); }
  }
  Future<void> loadMarkets() async {
    if (!broker.connected || loading) return;
    setState(() { loading = true; status = 'Loading five live markets…'; });
    try {
      final active = await broker.request({'active_symbols': 'full'});
      final list = active['active_symbols'];
      if (list is List) {
        for (final item in list) {
          if (item is! Map) continue;
          final symbol = '${item['symbol']}';
          final p = parsePrecision(item['pip_size']) ?? parsePrecision(item['pip']);
          if (p != null) precision[symbol] = p;
        }
      }
      for (final symbol in symbols) {
        if (!broker.connected) break;
        try {
          final response = await broker.request({'ticks_history': symbol, 'end': 'latest', 'style': 'ticks', 'count': 1000});
          final history = response['history'];
          if (history is Map && history['prices'] is List) {
            final prices = history['prices'] as List;
            final times = history['times'] is List ? history['times'] as List : <dynamic>[];
            final p = parsePrecision(history['pip_size']) ?? precision[symbol];
            if (p != null) {
              precision[symbol] = p;
              final m = states[symbol]!;
              m.precision = p;
              for (var i = 0; i < prices.length; i++) {
                final n = double.tryParse('${prices[i]}');
                final d = lastDigit(prices[i], p);
                if (n != null && d != null) {
                  m.record(n, d, i < times.length ? int.tryParse('${times[i]}') ?? 0 : 0);
                }
              }
              // Historical ticks are not evidence of a current live feed.
              m.received = null;
            }
          }
          await broker.subscribe(symbol);
        } catch (e) { message('$symbol unavailable: $e'); }
      }
      if (broker.connected) message('Live radar ready • ${broker.subscriptions.length}/5 markets');
    } catch (e) { message('Market load failed: $e'); }
    finally { if (mounted) setState(() => loading = false); }
  }
  void handleTick(Map<String, dynamic> response) {
    if (!mounted || !broker.connected) return;
    final tick = response['tick'];
    if (tick is! Map) return;
    final symbol = '${tick['symbol'] ?? ''}';
    final market = states[symbol];
    if (market == null) return;
    final epoch = int.tryParse('${tick['epoch']}');
    final price = double.tryParse('${tick['quote']}');
    final p = parsePrecision(tick['pip_size']) ?? precision[symbol] ?? market.precision;
    if (epoch == null || price == null || p == null) return;
    precision[symbol] = p;
    market.precision = p;
    final digit = lastDigit(tick['quote'], p);
    if (digit == null) return;
    // A subscription's initial tick may duplicate its preceding history or request reply.
    final key = '$epoch:${price.toStringAsFixed(p)}';
    if (seen[symbol] == key) return;
    seen[symbol] = key;
    setState(() {
      market.record(price, digit, epoch);
      for (final o in observations.where((o) => o.pending && o.market == symbol)) {
        if (!DateTime.now().isBefore(o.deadline) && market.tickSequence > o.sequenceAtStart) {
          o.actualDigit = digit;
          o.actualEpoch = epoch;
          o.won = evaluate(o.strategy, digit, o.barrier);
          o.status = o.won! ? 'CORRECT' : 'INCORRECT';
        }
      }
    });
  }
  bool evaluate(String type, int digit, int n) {
    switch (type) {
      case 'Even': return digit.isEven;
      case 'Odd': return digit.isOdd;
      case 'Over': return digit > n;
      case 'Under': return digit < n;
      case 'Matches': return digit == n;
      case 'Differs': return digit != n;
    }
    return false;
  }
  void startObservation() {
    final m = states[selected]!;
    if (!broker.connected || !foreground || !m.fresh || m.total < 100) {
      message('Connect and collect at least 100 ticks with a fresh live feed'); return;
    }
    if (observations.any((o) => o.pending && o.market == selected)) {
      message('Wait for the current observation to finish'); return;
    }
    final n = strategy == 'Matches' || strategy == 'Differs' ? (m.frequentDigit ?? barrier) : barrier;
    setState(() {
      observations.insert(0, Observation(selected, strategy, n, m.tickSequence, DateTime.now()));
      if (observations.length > 500) observations.removeLast();
      status = 'Observation locked • no broker order placed';
    });
  }
  int get evaluated => observations.where((o) => o.won != null).length;
  int get correct => observations.where((o) => o.won == true).length;
  int evaluatedFor(String symbol) => observations.where((o) => o.market == symbol && o.won != null).length;
  int correctFor(String symbol) => observations.where((o) => o.market == symbol && o.won == true).length;
  String rate(int wins, int total) => total == 0 ? 'Not measured' : '${(100 * wins / total).toStringAsFixed(1)}% ($wins/$total)';

  bool get canTrade => broker.connected && foreground && !emergencyStopped && !orderBusy && !unresolvedOrder && activeContract == null &&
      tradeCount < 6 && consecutiveLosses < 2 && pnl > -1.00 &&
      stake.isFinite && stake >= 0.35 && stake <= (mode == 'real' ? 1.00 : 5.00) &&
      (mode == 'demo' || realArmed) &&
      (lastOrder == null || DateTime.now().difference(lastOrder!).inSeconds >= 300);
  Future<void> reviewTrade() async {
    final m = states[selected]!;
    if (!canTrade || !m.fresh || !['UP ↗', 'DOWN ↘'].contains(m.trend)) {
      message('Trade blocked: risk limits, stale feed, or no confirmed trend'); return;
    }
    final side = m.trend == 'UP ↗' ? 'CALL' : 'PUT';
    final approved = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(mode == 'real' ? 'CONFIRM REAL-MONEY ORDER' : 'Confirm DEMO order'),
      content: Text('$selected • $side • USD ${stake.toStringAsFixed(2)}\n'
        '5-minute Rise/Fall. Trend is NOT a measured win probability.\n'
        'Broker payout will be shown in proposal only.\n'
        '${mode == 'real' ? 'REAL FUNDS WILL BE AT RISK. You may lose the full stake.' : 'This is an order on a DEMO account.'}'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(mode == 'real' ? 'BUY WITH REAL MONEY' : 'BUY DEMO'))],
    ));
    if (approved == true && mounted && broker.accountType == mode) await buyTrade(selected, side);
  }
  Future<void> buyTrade(String symbol, String side) async {
    if (!canTrade || broker.accountType != mode) return;
    setState(() { orderBusy = true; status = 'Requesting ${mode.toUpperCase()} proposal…'; });
    var buyAttempted = false;
    try {
      final proposal = await broker.request({'proposal': 1, 'amount': stake.toStringAsFixed(2),
        'basis': 'stake', 'contract_type': side, 'currency': 'USD',
        'duration': 5, 'duration_unit': 'm', 'underlying_symbol': symbol});
      final offer = proposal['proposal'];
      if (offer is! Map) throw StateError('Invalid broker proposal');
      final proposalId = '${offer['id'] ?? ''}';
      final ask = double.tryParse('${offer['ask_price']}');
      if (proposalId.isEmpty || ask == null || !ask.isFinite || ask <= 0 || ask > stake + 0.01) {
        throw StateError('Proposal missing or exceeds stake');
      }
      if (!mounted || !broker.connected || !foreground) throw StateError('Connection or foreground lost');
      buyAttempted = true;
      unresolvedOrder = true; // Never blindly retry a timed-out buy.
      final bought = await broker.request({'buy': proposalId, 'price': ask});
      final details = bought['buy'];
      if (details is! Map || details['contract_id'] == null) {
        throw StateError('Buy response uncertain; check ${mode.toUpperCase()} portfolio before retrying');
      }
      final id = '${details['contract_id']}';
      final record = TradeRecord(symbol, side, id, ask);
      setState(() {
        trades.insert(0, record);
        activeContract = id;
        unresolvedOrder = false;
        tradeCount++;
        lastOrder = DateTime.now();
        status = '${mode.toUpperCase()} $side purchased • monitoring $id';
      });
      unawaited(monitor(record));
    } catch (e) {
      if (buyAttempted) { unresolvedOrder = true; message('ORDER UNCERTAIN • check Deriv portfolio: $e'); }
      else { message('Proposal rejected: $e'); }
    } finally { if (mounted) setState(() => orderBusy = false); }
  }
  Future<void> monitor(TradeRecord record) async {
    while (mounted && broker.connected && activeContract == record.id) {
      try {
        final response = await broker.request({'proposal_open_contract': 1, 'contract_id': int.tryParse(record.id) ?? record.id});
        final contract = response['proposal_open_contract'];
        if (contract is! Map) throw StateError('Contract status unavailable');
        final sold = '${contract['is_sold']}' == '1' || contract['is_sold'] == true;
        if (sold) {
          final profit = double.tryParse('${contract['profit']}');
          if (profit == null) throw StateError('Settled profit missing');
          if (!mounted) return;
          setState(() {
            record.profit = profit;
            record.status = profit > 0 ? 'WIN' : profit < 0 ? 'LOSS' : 'DRAW';
            pnl += profit;
            consecutiveLosses = profit < 0 ? consecutiveLosses + 1 : profit > 0 ? 0 : consecutiveLosses;
            activeContract = null;
            status = '${mode.toUpperCase()} ${record.status} • P/L ${profit.toStringAsFixed(2)}';
          });
          return;
        }
      } catch (e) { message('Settlement check pending: $e'); }
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    if (mounted && activeContract == record.id) {
      setState(() { unresolvedOrder = true; status = 'Contract status unresolved • verify ${mode.toUpperCase()} portfolio'; });
    }
  }
  Future<void> disconnect() async {
    await broker.close();
    if (mounted) setState(() {
      unresolvedOrder = unresolvedOrder || activeContract != null || orderBusy;
      status = 'Disconnected'; realArmed = false;
    });
  }
  Future<void> reconcile() async {
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('Verify ${mode.toUpperCase()} portfolio'),
      content: const Text('Only reset after checking Deriv and confirming that no contract or unrecorded order is open. This does not resolve an open trade.'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('I VERIFIED'))],
    ));
    if (confirmed == true && mounted) setState(() { activeContract = null; unresolvedOrder = false; status = 'Manually reconciled'; });
  }

  Widget panel(String title, Widget child) => Card(color: surface, margin: const EdgeInsets.symmetric(vertical: 7),
    child: Padding(padding: const EdgeInsets.all(15), child: Column(crossAxisAlignment: CrossAxisAlignment.start,
      children: [Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12), child])));
  Widget pill(String text, {Color? color}) => Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(color: (color ?? accent).withValues(alpha: .15), borderRadius: BorderRadius.circular(10)),
    child: Text(text, style: TextStyle(color: color ?? accent, fontSize: 12, fontWeight: FontWeight.w600)));

  Widget radar() => Column(children: [
    panel('LIVE MULTI-MARKET RADAR', Column(children: [
      const Text('All five markets • live feed status • trend is not trade accuracy', style: TextStyle(fontSize: 12, color: Colors.white70)),
      const SizedBox(height: 8),
      ...symbols.map((s) {
        final m = states[s]!;
        final count = evaluatedFor(s);
        return ListTile(contentPadding: EdgeInsets.zero,
          onTap: () => setState(() { selected = s; tab = 1; }),
          leading: CircleAvatar(backgroundColor: m.fresh ? Colors.green.withValues(alpha: .2) : Colors.white10,
            child: Icon(m.fresh ? Icons.sensors : Icons.hourglass_empty, color: m.fresh ? Colors.greenAccent : Colors.white54)),
          title: Text('Volatility ${s.substring(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('${m.trend} • ${m.total} ticks • ${m.fresh ? 'LIVE' : 'WAIT'}\n'
              'Observed accuracy: ${rate(correctFor(s), count)}'),
          isThreeLine: true,
          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(m.lastDigit?.toString() ?? '–', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: accent)),
            const Text('LAST DIGIT', style: TextStyle(fontSize: 9)),
          ]),
        );
      }),
    ])),
    panel('ACTUAL RESULTS', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(rate(correct, evaluated), style: const TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
      Text('$evaluated evaluated observations • $correct correct'),
      const Text('10-second observations are NOT broker trades or a calibrated probability.', style: TextStyle(color: Colors.white70, fontSize: 12)),
      const SizedBox(height: 8),
      Text('Broker-settled demo trades: ${trades.where((t) => t.status == 'WIN' || t.status == 'LOSS').length}'),
      Text('Session P/L: USD ${pnl.toStringAsFixed(2)}'),
    ])),
  ]);

  Widget analyzer() {
    final m = states[selected]!;
    final current = observations.where((o) => o.market == selected).toList();
    final latest = current.isEmpty ? null : current.first;
    final counts = m.counts;
    return Column(children: [
      panel('EXPERT ANALYZER', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DropdownButtonFormField<String>(initialValue: selected, decoration: const InputDecoration(labelText: 'Market'),
          items: symbols.map((s) => DropdownMenuItem(value: s, child: Text('Volatility ${s.substring(2)}'))).toList(),
          onChanged: (v) { if (v != null) setState(() => selected = v); }),
        const SizedBox(height: 12),
        Wrap(spacing: 7, runSpacing: 7, children: [pill(m.fresh ? 'LIVE' : 'WAIT', color: m.fresh ? Colors.greenAccent : Colors.orangeAccent),
          pill('TREND ${m.trend}'), pill('${m.total} TICKS'), pill('PRECISION ${m.precision ?? '–'}')]),
        const SizedBox(height: 12),
        Text('Last quote: ${m.lastPrice == null ? '–' : m.lastPrice!.toStringAsFixed(m.precision ?? 3)}'),
        Text('Last digit: ${m.lastDigit ?? '–'}', style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold, color: accent)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(initialValue: strategy, decoration: const InputDecoration(labelText: 'Observation strategy'),
          items: ['Even', 'Odd', 'Over', 'Under', 'Matches', 'Differs'].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
          onChanged: (v) { if (v != null) setState(() => strategy = v); }),
        if (strategy == 'Over' || strategy == 'Under') Column(children: [
          Text('Barrier: $barrier'), Slider(value: barrier.toDouble(), min: 0, max: 9, divisions: 9,
            onChanged: (v) => setState(() => barrier = v.round()))]),
        const SizedBox(height: 8),
        Text('Suggested historical digit: ${m.frequentDigit ?? '–'} • frequency ${m.frequentRate.toStringAsFixed(1)}%'),
        const Text('Historical frequency is NOT next-digit confidence.', style: TextStyle(fontSize: 12, color: Colors.white70)),
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: broker.connected && m.fresh ? startObservation : null,
          icon: const Icon(Icons.timer), label: const Text('START 10s OBSERVATION')),
        if (latest != null) ...[
          const SizedBox(height: 14),
          Center(child: Text(latest.pending ? '${latest.remaining}s' : '${latest.actualDigit}',
            style: const TextStyle(fontSize: 65, color: accent, fontWeight: FontWeight.bold))),
          Center(child: Text('${latest.strategy.toUpperCase()} • predicted ${latest.barrier} • ${latest.status}',
            textAlign: TextAlign.center)),
          if (!latest.pending) Center(child: Text('Observed digit: ${latest.actualDigit} • tick epoch: ${latest.actualEpoch}')),
          if (latest.pending && latest.remaining == 0) const Center(child: Text('Waiting for next live tick…')),
        ],
      ])),
      panel('DIGIT DISTRIBUTION', Column(children: [
        ...List.generate(10, (i) => Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [
          SizedBox(width: 25, child: Text('$i')),
          Expanded(child: LinearProgressIndicator(value: m.total == 0 ? 0 : counts[i] / m.total,
            minHeight: 8, borderRadius: BorderRadius.circular(6))),
          SizedBox(width: 70, child: Text(m.total == 0 ? '–' : '${(100 * counts[i] / m.total).toStringAsFixed(1)}%', textAlign: TextAlign.end)),
        ]))),
      ])),
      panel('${mode.toUpperCase()} RISE/FALL ORDER', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Trend: ${m.trend} • 5-minute duration • stake USD ${stake.toStringAsFixed(2)}'),
        const Text('Manual confirmation required. Digit observations do not trigger orders.',
          style: TextStyle(color: Colors.white70, fontSize: 12)),
        const SizedBox(height: 9),
        FilledButton.icon(onPressed: canTrade && m.fresh ? reviewTrade : null,
          icon: const Icon(Icons.verified_user_outlined), label: Text(mode == 'real' ? 'REVIEW REAL TRADE' : 'REVIEW DEMO TRADE')),
      ])),
    ]);
  }

  Widget history() => Column(children: [
    panel('BROKER-SETTLED ${mode.toUpperCase()} TRADES', Column(children: trades.isEmpty
      ? [const Text('No broker trades yet.')]
      : trades.map((t) => ListTile(contentPadding: EdgeInsets.zero,
        title: Text('${t.market} • ${t.direction} • ${t.status}'),
        subtitle: Text('Contract ${t.id} • Stake USD ${t.stake.toStringAsFixed(2)}'),
        trailing: Text(t.profit.toStringAsFixed(2)))).toList())),
    panel('10-SECOND OBSERVATION HISTORY', Column(children: observations.isEmpty
      ? [const Text('No observations yet.')]
      : observations.take(100).map((o) => ListTile(contentPadding: EdgeInsets.zero,
        title: Text('${o.market} • ${o.strategy} ${o.barrier} • ${o.status}'),
        subtitle: Text('Predicted: ${o.barrier} • Observed: ${o.actualDigit ?? 'pending'}\n'
          'Tick epoch: ${o.actualEpoch ?? 'pending'} • ${o.started.toLocal()}'),
        isThreeLine: true)).toList())),
  ]);

  Widget settings() => Column(children: [
    panel('ACCOUNT CONNECTION', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SegmentedButton<String>(segments: const [ButtonSegment(value: 'demo', label: Text('DEMO')), ButtonSegment(value: 'real', label: Text('REAL MONEY'))],
        selected: {mode}, onSelectionChanged: broker.connected || orderBusy || unresolvedOrder || activeContract != null ? null : (v) => setState(() {
          mode = v.first; realArmed = false; tradeCount = 0; consecutiveLosses = 0; pnl = 0; lastOrder = null;
          trades.clear(); stake = 0.35; status = '${mode.toUpperCase()} selected • not connected';
        })),
      if (mode == 'real') const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text(
        'REAL MONEY MODE • Actual funds can be lost. Manual orders only. Max USD 1 per order; session risk limits apply. No verified 80% accuracy.',
        style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold))),
      TextField(controller: appId, decoration: const InputDecoration(labelText: 'Deriv App ID')),
      TextField(controller: pat, obscureText: true, enableSuggestions: false, autocorrect: false,
        decoration: InputDecoration(labelText: '${mode.toUpperCase()} PAT (not saved)')),
      const SizedBox(height: 12),
      FilledButton(onPressed: connecting || broker.connected ? null : connect,
        child: Text(connecting ? 'CONNECTING…' : 'CONNECT ${mode.toUpperCase()}')),
      OutlinedButton(onPressed: broker.connected ? disconnect : null, child: const Text('DISCONNECT')),
      OutlinedButton(onPressed: broker.connected && !loading ? loadMarkets : null, child: const Text('REFRESH ALL MARKETS')),
    ])),
    if (mode == 'real') panel('REAL-MONEY ARMING', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Real-money orders are blocked until you deliberately arm them. Arming does not place an order. Each order still requires confirmation.'),
      SwitchListTile(title: const Text('Enable manual real-money orders'), value: realArmed,
        onChanged: broker.connected && !orderBusy && !unresolvedOrder && activeContract == null ? (v) async {
          if (!v) { setState(() => realArmed = false); return; }
          final approved = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
            title: const Text('Arm real-money trading?'),
            content: const Text('Real funds can be lost. Your V9 accuracy is not validated. Manual orders only, USD 1 maximum stake, USD 1 session loss limit, one contract at a time.'),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('I UNDERSTAND • ARM'))],
          ));
          if (mounted && approved == true && broker.connected && mode == 'real') setState(() => realArmed = true);
        } : null),
    ])),
    panel('RISK LIMITS', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Stake: USD ${stake.toStringAsFixed(2)}'),
      Slider(value: stake, min: 0.35, max: mode == 'real' ? 1.00 : 5.00, divisions: mode == 'real' ? 13 : 93,
        onChanged: (v) => setState(() => stake = double.parse(v.toStringAsFixed(2)))),
      const Text('Manual orders only • max 6/session • max 2 consecutive losses • '
        'USD 1 session loss cut-off • 5-minute cooldown • one open order at a time.'),
      Text('Session trades: $tradeCount/6 • loss streak: $consecutiveLosses • P/L: ${pnl.toStringAsFixed(2)}'),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: () => setState(() { emergencyStopped = true; realArmed = false; status = 'EMERGENCY STOP • new orders blocked'; }),
        icon: const Icon(Icons.stop_circle_outlined), label: const Text('EMERGENCY STOP • BLOCK NEW ORDERS')),
      if (emergencyStopped) OutlinedButton(onPressed: () => setState(() { emergencyStopped = false; status = 'Emergency stop reset • manual orders only'; }),
        child: const Text('RESET EMERGENCY STOP')),
      if (unresolvedOrder) OutlinedButton(onPressed: reconcile, child: const Text('RECONCILE AFTER PORTFOLIO CHECK')),
    ])),
    panel('ACCURACY & LIMITATIONS', const Text('No 80% win-rate claim is made. '
      'Digit predictions are observations, not orders. Price trend does not predict random last digits. '
      'Only broker-settled contracts count as trading results. '
      'Records are session-only and reset when the app restarts. '
      'Automatic trading is disabled. Real-money mode is manually armed and unverified; do not treat observations as proof of profitability.')),
  ]);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(backgroundColor: surface, title: const Text('V9 • Expert Trader'),
      actions: [Padding(padding: const EdgeInsets.only(right: 12), child: Center(child:
        pill(broker.connected ? '${mode.toUpperCase()} ONLINE' : 'OFFLINE', color: broker.connected ? Colors.greenAccent : Colors.orangeAccent)))]),
    body: Column(children: [
      Container(width: double.infinity, color: surface.withValues(alpha: .65),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Text(status, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
      Expanded(child: ListView(padding: const EdgeInsets.all(12), children: [
        if (tab == 0) radar() else if (tab == 1) analyzer() else if (tab == 2) history() else settings(),
      ])),
    ]),
    bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (v) => setState(() => tab = v),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.radar), label: 'Radar'),
        NavigationDestination(icon: Icon(Icons.analytics_outlined), label: 'Analyzer'),
        NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
      ]),
  );
}
