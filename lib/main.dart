import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    title: 'V10 Expert Trader',
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

// Indicators use sampled TICKS, not time-based candles. They are useful
// diagnostics for direction, not evidence of next-digit predictability.
class TickIndicators {
  final double ema20, ema50, rsi14, macd, macdSignal, atr14;
  final String direction;
  final int agreement;
  const TickIndicators(this.ema20, this.ema50, this.rsi14,
      this.macd, this.macdSignal, this.atr14, this.direction, this.agreement);

  static List<double> emaSeries(List<double> xs, int period) {
    final output = <double>[];
    final alpha = 2.0 / (period + 1);
    var value = xs.first;
    for (final x in xs) {
      value += alpha * (x - value);
      output.add(value);
    }
    return output;
  }

  static TickIndicators? calculate(Iterable<double> prices) {
    final p = prices.toList();
    if (p.length < 60) return null;
    final e20 = emaSeries(p, 20);
    final e50 = emaSeries(p, 50);
    final e12 = emaSeries(p, 12);
    final e26 = emaSeries(p, 26);
    final macds = List<double>.generate(p.length, (i) => e12[i] - e26[i]);
    final signal = emaSeries(macds, 9);
    var gains = 0.0;
    var losses = 0.0;
    var absoluteMove = 0.0;
    for (var i = p.length - 14; i < p.length; i++) {
      final change = p[i] - p[i - 1];
      gains += max(0.0, change);
      losses += max(0.0, -change);
      absoluteMove += change.abs();
    }
    final rsi = losses == 0 ? (gains == 0 ? 50.0 : 100.0)
        : 100.0 - 100.0 / (1.0 + gains / losses);
    final atr = absoluteMove / 14; // Mean absolute tick change; NOT candle ATR.
    final upVotes = [e20.last > e50.last, e20.last > e20[e20.length - 2],
      macds.last > signal.last, rsi > 50, p.last > e20.last]
        .where((v) => v).length;
    final downVotes = [e20.last < e50.last, e20.last < e20[e20.length - 2],
      macds.last < signal.last, rsi < 50, p.last < e20.last]
        .where((v) => v).length;
    final up = upVotes >= 4 && upVotes > downVotes;
    final down = downVotes >= 4 && downVotes > upVotes;
    final agreement = max(upVotes, downVotes) * 20;
    return TickIndicators(e20.last, e50.last, rsi, macds.last,
        signal.last, atr, up ? 'UP' : down ? 'DOWN' : 'WAIT', agreement);
  }
}

// Real closed 1-minute OHLC bars, aggregated into completed 5m and 15m bars.
class PriceBar {
  final int epoch;
  final double open, high, low, close;
  const PriceBar(this.epoch, this.open, this.high, this.low, this.close);
  static PriceBar? fromApi(dynamic raw) {
    if (raw is! Map) return null;
    final t = int.tryParse('${raw['epoch']}');
    final o = double.tryParse('${raw['open']}');
    final h = double.tryParse('${raw['high']}');
    final l = double.tryParse('${raw['low']}');
    final c = double.tryParse('${raw['close']}');
    if (t == null || o == null || h == null || l == null || c == null ||
        ![o,h,l,c].every((v) => v.isFinite)) return null;
    return PriceBar(t,o,h,l,c);
  }
}

List<PriceBar> aggregateClosed(List<PriceBar> oneMinute, int minutes) {
  final groups = <int,List<PriceBar>>{};
  for (final b in oneMinute) {
    final start = (b.epoch ~/ (minutes*60)) * minutes*60;
    groups.putIfAbsent(start, () => []).add(b);
  }
  final result = <PriceBar>[];
  for (final entry in groups.entries) {
    final g = entry.value..sort((a,b) => a.epoch.compareTo(b.epoch));
    if (g.length != minutes || g.first.epoch != entry.key ||
        g.last.epoch != entry.key + (minutes-1)*60) continue;
    result.add(PriceBar(entry.key, g.first.open,
      g.map((b)=>b.high).reduce(max), g.map((b)=>b.low).reduce(min), g.last.close));
  }
  result.sort((a,b)=>a.epoch.compareTo(b.epoch));
  return result;
}

class CandleReading {
  final String direction;
  final double rsi, atr, macd, signal;
  final bool extended;
  const CandleReading(this.direction,this.rsi,this.atr,this.macd,this.signal,this.extended);
  static CandleReading? calculate(List<PriceBar> bars) {
    if (bars.length < 55) return null;
    final prices = bars.map((b)=>b.close).toList();
    final ema20 = TickIndicators.emaSeries(prices,20);
    final ema50 = TickIndicators.emaSeries(prices,50);
    final e12 = TickIndicators.emaSeries(prices,12);
    final e26 = TickIndicators.emaSeries(prices,26);
    final macds = List<double>.generate(prices.length,(i)=>e12[i]-e26[i]);
    final signal = TickIndicators.emaSeries(macds,9).last;
    var gains=0.0, losses=0.0, tr=0.0;
    for (var i=bars.length-14; i<bars.length; i++) {
      final change=prices[i]-prices[i-1];
      gains+=max(0,change); losses+=max(0,-change);
      tr+=max(bars[i].high-bars[i].low,
        max((bars[i].high-prices[i-1]).abs(),(bars[i].low-prices[i-1]).abs()));
    }
    final rsi=losses==0 ? (gains==0 ? 50.0 : 100.0) : 100-100/(1+gains/losses);
    final atr=tr/14;
    if (!atr.isFinite || atr<=0) return null;
    final first=bars.sublist(bars.length-12,bars.length-6);
    final second=bars.sublist(bars.length-6);
    final higher=second.map((b)=>b.high).reduce(max)>first.map((b)=>b.high).reduce(max) &&
      second.map((b)=>b.low).reduce(min)>first.map((b)=>b.low).reduce(min);
    final lower=second.map((b)=>b.high).reduce(max)<first.map((b)=>b.high).reduce(max) &&
      second.map((b)=>b.low).reduce(min)<first.map((b)=>b.low).reduce(min);
    final up=ema20.last>ema50.last && ema20.last>ema20[ema20.length-2] &&
      prices.last>ema20.last && macds.last>signal && rsi>=51 && rsi<=70 && higher;
    final down=ema20.last<ema50.last && ema20.last<ema20[ema20.length-2] &&
      prices.last<ema20.last && macds.last<signal && rsi>=30 && rsi<=49 && lower;
    final extended=(prices.last-ema20.last).abs()/atr>2.1 || (ema20.last-ema50.last).abs()/atr>3;
    return CandleReading(up?'UP':down?'DOWN':'WAIT',rsi,atr,macds.last,signal,extended);
  }
}

class MultiFrameReading {
  final CandleReading one, five, fifteen;
  final DateTime updated;
  const MultiFrameReading(this.one,this.five,this.fifteen,this.updated);
  String get direction => !one.extended && !five.extended &&
    one.direction==five.direction && five.direction==fifteen.direction ? one.direction : 'WAIT';
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
  TickIndicators? get indicators => TickIndicators.calculate(prices);
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
  final candleReadings = <String, MultiFrameReading>{};
  final candleErrors = <String,String>{};
  Timer? persistenceClock;
  bool restoring = true;
  bool recordsDirty = false;
  Timer? clock;
  Timer? reconnectTimer;
  bool reconnectEnabled = false;
  int reconnectAttempts = 0;
  bool _manualDisconnect = false;
  bool _resumePending = false;
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
  // Independent automatic observations. These NEVER place broker orders.
  bool automaticObservations = false;
  final Map<String, DateTime> nextCycle = {};
  final Map<String, String> signalStrategy = {};
  final Map<String, int> signalBarrier = {};
  static const cycleLength = Duration(seconds: 10);
  static const minimumHistory = 100;
  String strategyFor(MarketState m) {
    // Alternating categories permit separately measured strategies; no claim of edge.
    final n = observations.where((o) => o.market == m.symbol).length;
    return const ['Matches', 'Differs', 'Even', 'Odd', 'Over', 'Under'][n % 6];
  }
  int barrierFor(MarketState m, String type) {
    if (type == 'Matches' || type == 'Differs') return m.frequentDigit ?? 5;
    if (type == 'Over' || type == 'Under') return 4;
    return 0;
  }
  Observation? activeFor(String symbol) {
    for (final o in observations) {
      if (o.market == symbol && o.pending) return o;
    }
    return null;
  }
  void runAutomaticCycles() {
    for (final o in observations.where((o) => o.pending && DateTime.now().difference(o.deadline).inSeconds > 20)) {
      o.status = 'EXPIRED • NO LIVE TICK'; recordsDirty = true;
    }
    if (!automaticObservations || !foreground || !broker.connected || emergencyStopped) return;
    final now = DateTime.now();
    var changed = false;
    for (final symbol in symbols) {
      final m = states[symbol]!;
      if (!m.fresh || m.total < minimumHistory || activeFor(symbol) != null) continue;
      if (now.isBefore(nextCycle[symbol] ?? DateTime.fromMillisecondsSinceEpoch(0))) continue;
      final type = strategyFor(m);
      final n = barrierFor(m, type);
      observations.insert(0, Observation(symbol, type, n, m.tickSequence, now));
      recordsDirty = true;
      signalStrategy[symbol] = type;
      signalBarrier[symbol] = n;
      nextCycle[symbol] = now.add(cycleLength);
      changed = true;
    }
    if (observations.length > 1000) observations.removeRange(1000, observations.length);
    if (changed && mounted) setState(() {});
  }
  void stopAutomaticCycles() {
    setState(() { automaticObservations = false; status = 'Automatic observations stopped • no broker orders'; });
  }


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    broker.onTick = handleTick;
    unawaited(restoreRecords());
    broker.onDisconnect = (message) {
      if (!mounted) return;
      setState(() { status = message; realArmed = false; automaticObservations = false; for (final o in observations.where((o) => o.pending)) { o.status = 'CANCELLED • DISCONNECTED'; } unresolvedOrder = activeContract != null || orderBusy; });
      if (reconnectEnabled && !_manualDisconnect && foreground) _scheduleReconnect();
    };
    persistenceClock = Timer.periodic(const Duration(seconds: 5), (t) {
      if (!mounted) { t.cancel(); return; }
      if (recordsDirty) unawaited(saveRecords());
    });
    clock = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted && foreground) { runAutomaticCycles(); setState(() {}); }
    });
  }
  void _scheduleReconnect() {
    if (!mounted || !foreground || !reconnectEnabled || _manualDisconnect ||
        broker.connected || connecting || reconnectTimer != null) return;
    // Back off after failures rather than repeatedly hammering Deriv.
    final seconds = min(60, 2 * (1 << min(reconnectAttempts, 5)));
    reconnectTimer = Timer(Duration(seconds: seconds), () {
      reconnectTimer = null;
      if (mounted && foreground && reconnectEnabled && !_manualDisconnect && !broker.connected) {
        unawaited(connect(retrying: true));
      }
    });
    message('Connection lost • retrying in ${seconds}s');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      reconnectTimer?.cancel();
      reconnectTimer = null;
      _resumePending = reconnectEnabled;
      if (mounted) setState(() {
        realArmed = false;
        automaticObservations = false;
        for (final o in observations.where((o) => o.pending)) {
          o.status = 'CANCELLED • BACKGROUND';
        }
        status = 'Paused in background • no new orders';
      });
    } else if (mounted) {
      if (broker.connected) {
        setState(() => status = '${mode.toUpperCase()} connected');
      } else if (_resumePending && reconnectEnabled && !_manualDisconnect) {
        _resumePending = false;
        _scheduleReconnect();
      }
    }
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    clock?.cancel();
    persistenceClock?.cancel();
    unawaited(saveRecords());
    reconnectTimer?.cancel();
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
  Future<void> connect({bool retrying = false}) async {
    if (connecting || broker.connected) return;
    if (appId.text.trim().isEmpty || pat.text.trim().isEmpty) {
      message('Enter App ID and PAT to log in');
      return;
    }
    if (!retrying) {
      _manualDisconnect = false;
      reconnectEnabled = true;
      reconnectAttempts = 0;
    }
    reconnectTimer?.cancel();
    reconnectTimer = null;
    setState(() { connecting = true; status = 'Connecting to ${mode.toUpperCase()}…'; });
    try {
      await broker.connect(appId.text.trim(), pat.text.trim(), mode: mode);
      if (!mounted) return;
      reconnectAttempts = 0;
      message('${mode.toUpperCase()} connected • ${broker.account}');
      await loadMarkets();
      // Never clear an unresolved order until its broker settlement is checked.
      if (activeContract != null) {
        final matches = trades.where((t) => t.id == activeContract).toList();
        if (matches.isNotEmpty) unawaited(monitor(matches.first));
      }
      // Reconnection never re-arms real trading or automatically places orders.
      // An interrupted purchase remains unresolved until independently checked.
      if (mounted && activeContract != null) {
        setState(() { unresolvedOrder = true; status = 'Reconnected • verify open contract $activeContract'; });
      }
    } catch (e) {
      if (mounted) {
        reconnectAttempts++;
        message('Connection failed: $e');
      }
    } finally {
      if (mounted) {
        setState(() => connecting = false);
        if (!broker.connected && reconnectEnabled && foreground && !_manualDisconnect) {
          _scheduleReconnect();
        }
      }
    }
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
      if (broker.connected) unawaited(loadClosedCandles());
    } catch (e) { message('Market load failed: $e'); }
    finally { if (mounted) setState(() => loading = false); }
  }
  Future<void> loadClosedCandles() async {
    for (final symbol in symbols) {
      if (!broker.connected || !mounted) break;
      try {
        final response = await broker.request({
          'ticks_history': symbol, 'end': 'latest', 'style': 'candles',
          'granularity': 60, 'count': 900,
        });
        final raw = response['candles'];
        if (raw is! List) throw StateError('No candle data');
        final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
        final bars = raw.map(PriceBar.fromApi).whereType<PriceBar>()
          .where((b)=>b.epoch+60<=now).toList()
          ..sort((a,b)=>a.epoch.compareTo(b.epoch));
        final one=CandleReading.calculate(bars);
        final five=CandleReading.calculate(aggregateClosed(bars,5));
        final fifteen=CandleReading.calculate(aggregateClosed(bars,15));
        if (one==null || five==null || fifteen==null) {
          throw StateError('Insufficient complete 1m/5m/15m bars');
        }
        if (mounted) setState(() {
          candleReadings[symbol]=MultiFrameReading(one,five,fifteen,DateTime.now());
          candleErrors.remove(symbol);
        });
      } catch (e) {
        if (mounted) setState(() => candleErrors[symbol]='$e');
      }
    }
  }

  // Stores outcomes locally; PAT and App ID are deliberately never persisted.
  Future<void> saveRecords() async {
    if (restoring) return;
    try {
      final prefs=await SharedPreferences.getInstance();
      final data={
        'version':1,
        'observations': observations.take(1000).map((o)=>{
          'market':o.market,'strategy':o.strategy,'barrier':o.barrier,
          'started':o.started.toIso8601String(),'deadline':o.deadline.toIso8601String(),
          'actualDigit':o.actualDigit,'actualEpoch':o.actualEpoch,
          'won':o.won,'status':o.status,
        }).toList(),
        'trades': trades.take(500).map((t)=>{
          'market':t.market,'direction':t.direction,'id':t.id,
          'stake':t.stake,'profit':t.profit,'status':t.status,
        }).toList(),
        'activeContract':activeContract,'unresolvedOrder':unresolvedOrder,
        'tradeCount':tradeCount,'consecutiveLosses':consecutiveLosses,
        'pnl':pnl,'lastOrder':lastOrder?.toIso8601String(),
      };
      await prefs.setString('v10_history_v1',jsonEncode(data));
      recordsDirty=false;
    } catch (e) { if (mounted) message('History save failed: $e'); }
  }

  Future<void> restoreRecords() async {
    try {
      final prefs=await SharedPreferences.getInstance();
      final raw=prefs.getString('v10_history_v1');
      if (raw==null) return;
      final root=jsonDecode(raw);
      if (root is! Map || root['version']!=1) return;
      final obs=root['observations'];
      if (obs is List) for (final item in obs) {
        if (item is! Map) continue;
        try {
          final start=DateTime.parse('${item['started']}');
          final o=Observation('${item['market']}','${item['strategy']}',
            (item['barrier'] as num).toInt(),0,start);
          o.actualDigit=(item['actualDigit'] as num?)?.toInt();
          o.actualEpoch=(item['actualEpoch'] as num?)?.toInt();
          o.won=item['won'] as bool?;
          o.status='${item['status']}';
          if (o.pending) o.status='INTERRUPTED • NOT SCORED';
          observations.add(o);
        } catch (_) {}
      }
      final savedTrades=root['trades'];
      if (savedTrades is List) for (final item in savedTrades) {
        if (item is! Map) continue;
        try {
          final t=TradeRecord('${item['market']}','${item['direction']}',
            '${item['id']}',(item['stake'] as num).toDouble());
          t.profit=(item['profit'] as num?)?.toDouble() ?? 0;
          t.status='${item['status']}';
          trades.add(t);
        } catch (_) {}
      }
      activeContract=root['activeContract'] as String?;
      unresolvedOrder=root['unresolvedOrder']==true || activeContract!=null;
      tradeCount=(root['tradeCount'] as num?)?.toInt() ?? 0;
      consecutiveLosses=(root['consecutiveLosses'] as num?)?.toInt() ?? 0;
      pnl=(root['pnl'] as num?)?.toDouble() ?? 0;
      lastOrder=root['lastOrder'] == null ? null : DateTime.tryParse('${root['lastOrder']}');
    } catch (e) { if (mounted) message('History restore failed: $e'); }
    finally { restoring=false; if (mounted) setState(() {}); }
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
          recordsDirty = true;
          nextCycle[symbol] = DateTime.now().add(const Duration(seconds: 1));
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
      recordsDirty = true;
      if (observations.length > 500) observations.removeLast();
      status = 'Observation locked • no broker order placed';
    });
  }
  int get evaluated => observations.where((o) => o.won != null).length;
  int get correct => observations.where((o) => o.won == true).length;
  int evaluatedFor(String symbol) => observations.where((o) => o.market == symbol && o.won != null).length;
  int correctFor(String symbol) => observations.where((o) => o.market == symbol && o.won == true).length;
  String rate(int wins, int total) => total == 0 ? 'Not measured' : '${(100 * wins / total).toStringAsFixed(1)}% ($wins/$total)';

  bool get canTrade => !restoring && broker.connected && foreground && !emergencyStopped && !orderBusy && !unresolvedOrder && activeContract == null &&
      tradeCount < 6 && consecutiveLosses < 2 && pnl > -1.00 &&
      stake.isFinite && stake >= 0.35 && stake <= (mode == 'real' ? 1.00 : 5.00) &&
      mode == 'demo' &&
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
      recordsDirty = true;
      final bought = await broker.request({'buy': proposalId, 'price': ask});
      final details = bought['buy'];
      if (details is! Map || details['contract_id'] == null) {
        throw StateError('Buy response uncertain; check ${mode.toUpperCase()} portfolio before retrying');
      }
      final id = '${details['contract_id']}';
      final record = TradeRecord(symbol, side, id, ask);
      setState(() {
        trades.insert(0, record);
        recordsDirty = true;
        activeContract = id;
        unresolvedOrder = false;
        tradeCount++;
        lastOrder = DateTime.now();
        status = '${mode.toUpperCase()} $side purchased • monitoring $id';
      });
      unawaited(monitor(record));
    } catch (e) {
      if (buyAttempted) { unresolvedOrder = true; recordsDirty = true; message('ORDER UNCERTAIN • check Deriv portfolio: $e'); }
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
            recordsDirty = true;
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
      setState(() { unresolvedOrder = true; recordsDirty = true; status = 'Contract status unresolved • verify ${mode.toUpperCase()} portfolio'; });
    }
  }
  Future<void> disconnect() async {
    _manualDisconnect = true;
    reconnectEnabled = false;
    reconnectTimer?.cancel();
    reconnectTimer = null;
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
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Automatic 10-second observations'),
        subtitle: const Text('All five markets • no automatic purchases'),
        value: automaticObservations,
        onChanged: broker.connected && foreground ? (v) => setState(() {
          automaticObservations = v;
          if (v) { nextCycle.clear(); status = 'Automatic observations active • demo observations only'; }
        }) : null,
      ),
      const Text('All five markets • live feed status • trend is not trade accuracy', style: TextStyle(fontSize: 12, color: Colors.white70)),
      const SizedBox(height: 8),
      ...symbols.map((s) {
        final m = states[s]!;
        final count = evaluatedFor(s);
        final pending = activeFor(s);
        final recent = m.digits.toList().reversed.take(9).toList().reversed.join('  ');
        final previous = observations.where((o) => o.market == s && o.won != null).toList();
        final latest = previous.isEmpty ? null : previous.first;
        return ListTile(contentPadding: EdgeInsets.zero,
          onTap: () => setState(() { selected = s; tab = 1; }),
          leading: CircleAvatar(backgroundColor: m.fresh ? Colors.green.withValues(alpha: .2) : Colors.white10,
            child: Icon(m.fresh ? Icons.sensors : Icons.hourglass_empty, color: m.fresh ? Colors.greenAccent : Colors.white54)),
          title: Text('Volatility ${s.substring(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('${m.trend} • ${m.total} ticks • ${m.fresh ? 'LIVE' : 'WAIT'}\n'
              'Signal: ${pending == null ? (latest == null ? 'ANALYZING' : '${latest.strategy.toUpperCase()} ${latest.barrier} • ${latest.status}') : '${pending.strategy.toUpperCase()} ${pending.barrier} • ${pending.remaining}s'}\n'
              'Recent digits: $recent\n'
              'Observed accuracy: ${rate(correctFor(s), count)} • Tick indicators: ${m.indicators?.direction ?? 'COLLECTING'} (${m.indicators?.agreement ?? 0}% agreement)'),
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
      Text('80% target: ${evaluated >= 200 ? (correct / evaluated * 100 >= 80 ? 'REACHED in sample' : 'NOT REACHED') : 'NOT VERIFIED • ${max(0, 200 - evaluated)} more observations to 200'}'),
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
        if (m.indicators case final i?) ...[
          Text('TICK INDICATORS • ${i.direction} • ${i.agreement}% indicator agreement',
            style: const TextStyle(fontWeight: FontWeight.bold, color: accent)),
          Text('EMA20 ${i.ema20.toStringAsFixed(m.precision ?? 3)}  |  EMA50 ${i.ema50.toStringAsFixed(m.precision ?? 3)}'),
          Text('RSI(14) ${i.rsi14.toStringAsFixed(1)}  |  MACD ${i.macd.toStringAsExponential(2)}'),
          Text('MACD signal ${i.macdSignal.toStringAsExponential(2)}  |  Mean tick move ${i.atr14.toStringAsExponential(2)}'),
          const Text('Calculated from tick prices, NOT 1m/5m/15m closed candles. Tick movement is not candle ATR or a digit-win probability.',
            style: TextStyle(fontSize: 11, color: Colors.white70)),
        ] else const Text('Collecting 60+ ticks for indicator analysis…'),
        const SizedBox(height: 12),
        if (candleReadings[selected] case final f?) ...[
          const SizedBox(height: 10),
          Text('CLOSED CANDLES • 1m ${f.one.direction} / 5m ${f.five.direction} / 15m ${f.fifteen.direction}',
            style: const TextStyle(fontWeight: FontWeight.bold, color: accent)),
          Text('Multi-timeframe agreement: ${f.direction} • Updated ${f.updated.toLocal()}'),
          Text('1m RSI ${f.one.rsi.toStringAsFixed(1)} • true-range ATR ${f.one.atr.toStringAsExponential(2)}'),
          const Text('Closed-candle trend agreement is not a next-digit win probability.',
            style: TextStyle(fontSize: 11, color: Colors.white70)),
        ] else Text('Closed-candle analysis: ${candleErrors[selected] ?? 'Loading 1m/5m/15m bars…'}'),
        OutlinedButton(onPressed: broker.connected ? loadClosedCandles : null,
          child: const Text('REFRESH CLOSED-CANDLE ANALYSIS')),
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
          reconnectEnabled = false; reconnectTimer?.cancel(); reconnectTimer = null; mode = v.first; realArmed = false; tradeCount = 0; consecutiveLosses = 0; pnl = 0; lastOrder = null;
          // Keep historical records across account-mode changes.
          stake = 0.35; status = '${mode.toUpperCase()} selected • not connected';
        })),
      if (mode == 'real') const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text(
        'REAL MONEY MODE • Orders are disabled in this unverified V10 build. Use DEMO for testing.',
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
    if (mode == 'real') panel('REAL-MONEY ORDERS', const Text('Disabled pending compilation, reconciliation tests and independent validation.')),
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
      'Observations and trade outcomes are saved locally; credentials are not. '
      'Automatic trading is disabled. Real-money mode is manually armed and unverified; do not treat observations as proof of profitability.')),
  ]);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(backgroundColor: surface, title: const Text('V10 • Expert Trader'),
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
