import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

void main() => runApp(const V8App());

const markets = <String>['R_10', 'R_25', 'R_50', 'R_75', 'R_100'];
const purple = Color(0xFF438CFF);
const navy = Color(0xFF09162B);
const panelNavy = Color(0xFF152742);

class V8App extends StatelessWidget {
  const V8App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'V8 PRO • Expert Trader',
    theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: purple), brightness: Brightness.dark, scaffoldBackgroundColor: navy),
    home: const LabHome(),
  );
}

class DerivApi {
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _sub;
  Timer? _ping;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _id = 0;
  bool online = false;
  void Function(String)? onLost;
  void Function(Map<String, dynamic>)? onTick;
  String? tickSubscriptionId;
  // Trading is possible only over an OTP-authenticated demo socket.
  bool get demoSocket => online;


  Future<String> connect(String appId, String token) async {
    await close();
    const base = 'https://api.derivws.com';
    final headers = {'Authorization': 'Bearer $token', 'Deriv-App-ID': appId};
    final response = await http.get(Uri.parse('$base/trading/v1/options/accounts'), headers: headers).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw StateError('Account HTTP ${response.statusCode}');
    final root = jsonDecode(response.body);
    if (root is! Map) throw StateError('Invalid account response');
    final data = root['data'];
    final raw = data is List ? data : (data is Map ? data['accounts'] : null);
    if (raw is! List) throw StateError('Accounts unavailable');
    Map<String, dynamic>? demo;
    for (final item in raw) {
      if (item is Map && item['account_type']?.toString().toLowerCase() == 'demo') {
        demo = Map<String, dynamic>.from(item);
        break;
      }
    }
    if (demo == null) throw StateError('No demo Options account');
    final account = '${demo['account_id'] ?? demo['id'] ?? ''}';
    if (account.isEmpty) throw StateError('Demo account ID missing');
    final otp = await http.post(Uri.parse('$base/trading/v1/options/accounts/${Uri.encodeComponent(account)}/otp'), headers: headers).timeout(const Duration(seconds: 20));
    if (otp.statusCode != 200) throw StateError('Demo OTP HTTP ${otp.statusCode}');
    final body = jsonDecode(otp.body);
    final otpData = body is Map ? body['data'] : null;
    final url = otpData is Map ? otpData['url']?.toString() : null;
    if (url == null) throw StateError('Demo WebSocket URL missing');
    final uri = Uri.parse(url);
    if (uri.scheme != 'wss' || uri.host != 'api.derivws.com' || uri.path != '/trading/v1/options/ws/demo') {
      throw StateError('Unexpected WebSocket destination');
    }
    try {
      _socket = WebSocketChannel.connect(uri);
      await _socket!.ready.timeout(const Duration(seconds: 20));
      online = true;
      _sub = _socket!.stream.listen((event) {
        try {
          final value = jsonDecode(event as String);
          if (value is! Map) return;
          final message = Map<String, dynamic>.from(value);
          if (message['msg_type'] == 'tick' && message['tick'] is Map) {
            final sub = message['subscription'];
            if (sub is Map && sub['id'] != null) tickSubscriptionId = '${sub['id']}';
            onTick?.call(message);
          }
          final id = int.tryParse('${message['req_id']}');
          final c = id == null ? null : _pending.remove(id);
          if (c == null || c.isCompleted) return;
          if (message['error'] != null) {
            c.completeError(StateError('${message['error']}'));
          } else {
            c.complete(message);
          }
        } catch (_) {}
      }, onError: (_) => _lost('Network error'), onDone: () => _lost('Connection closed'));
      _ping = Timer.periodic(const Duration(seconds: 30), (_) async {
        try { if (online) await request({'ping': 1}); } catch (_) { _lost('Heartbeat failed'); }
      });
      return account;
    } catch (_) { await close(); rethrow; }
  }

  void _lost(String reason) {
    if (!online) return;
    online = false;
    _ping?.cancel();
    for (final c in _pending.values) { if (!c.isCompleted) c.completeError(StateError(reason)); }
    _pending.clear();
    onLost?.call(reason);
  }

  Future<Map<String, dynamic>> request(Map<String, dynamic> body) async {
    if (!online || _socket == null) throw StateError('Connect demo first');
    final id = ++_id;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    try {
      _socket!.sink.add(jsonEncode({...body, 'req_id': id}));
      return await c.future.timeout(const Duration(seconds: 22));
    } finally { _pending.remove(id); }
  }

  Future<void> unsubscribeTicks() async {
    final id = tickSubscriptionId;
    tickSubscriptionId = null;
    if (id != null && online) {
      try { await request({'forget': id}); } catch (_) {}
    }
  }

  Future<void> close() async {
    tickSubscriptionId = null;
    online = false;
    _ping?.cancel();
    _ping = null;
    for (final c in _pending.values) { if (!c.isCompleted) c.completeError(StateError('Disconnected')); }
    _pending.clear();
    await _sub?.cancel();
    _sub = null;
    await _socket?.sink.close();
    _socket = null;
  }
}

class Candle {
  final int epoch;
  final double open, high, low, close;
  const Candle(this.epoch, this.open, this.high, this.low, this.close);
  static Candle? parse(dynamic value) {
    if (value is! Map) return null;
    final t = int.tryParse('${value['epoch']}');
    final o = double.tryParse('${value['open']}');
    final h = double.tryParse('${value['high']}');
    final l = double.tryParse('${value['low']}');
    final c = double.tryParse('${value['close']}');
    if (t == null || o == null || h == null || l == null || c == null || ![o,h,l,c].every((v) => v.isFinite)) return null;
    return Candle(t,o,h,l,c);
  }
}

class Setup {
  final String symbol, direction, detail;
  final double score, rsi, adx, entry;
  final int epoch;
  String result = 'PENDING';
  Setup(this.symbol, this.direction, this.detail, this.score, this.rsi, this.adx, this.entry, this.epoch);
}

double ema(List<double> xs, int period) {
  var e = xs.first;
  final k = 2 / (period + 1);
  for (final x in xs.skip(1)) { e = x*k + e*(1-k); }
  return e;
}

double rsi(List<double> xs) {
  var gains = 0.0, losses = 0.0;
  for (var i = xs.length - 14; i < xs.length; i++) {
    final d = xs[i] - xs[i-1];
    gains += max(0, d); losses += max(0, -d);
  }
  if (losses == 0) return gains == 0 ? 50 : 100;
  return 100 - 100/(1+gains/losses);
}

// V8 PRO Expert Mode 2.0: independent, CLOSED-candle multi-timeframe checks.
// Scores measure indicator agreement, never predicted win probability.
List<Candle> aggregateBars(List<Candle> bars, int minutes) {
  final period = minutes * 60;
  final groups = <int,List<Candle>>{};
  for (final b in bars) {
    final key = (b.epoch ~/ period) * period;
    groups.putIfAbsent(key, () => <Candle>[]).add(b);
  }
  final result = <Candle>[];
  for (final entry in groups.entries) {
    final group = entry.value..sort((a,b) => a.epoch.compareTo(b.epoch));
    // Only complete groups; never use an unfinished higher-timeframe candle.
    if (group.length != minutes || group.first.epoch != entry.key ||
        group.last.epoch != entry.key + (minutes-1)*60) continue;
    result.add(Candle(entry.key,group.first.open,
      group.map((b)=>b.high).reduce(max),group.map((b)=>b.low).reduce(min),group.last.close));
  }
  result.sort((a,b)=>a.epoch.compareTo(b.epoch));
  return result;
}

class FrameReading {
  final String trend;
  final double momentum, atr, strength;
  final bool up, down, extended;
  const FrameReading(this.trend,this.momentum,this.atr,this.strength,this.up,this.down,this.extended);
}

FrameReading? readFrame(List<Candle> bars) {
  if (bars.length < 55) return null;
  final c=bars.map((b)=>b.close).toList();
  final fast=ema(c,20),slow=ema(c,50);
  final priorFast=ema(c.sublist(0,c.length-1),20);
  final momentum=rsi(c);
  final tr=<double>[];
  for (var i=1;i<bars.length;i++) {
    tr.add(max(bars[i].high-bars[i].low,
      max((bars[i].high-c[i-1]).abs(),(bars[i].low-c[i-1]).abs())));
  }
  final atr=tr.sublist(tr.length-14).reduce((a,b)=>a+b)/14;
  if(atr<=0 || !atr.isFinite) return null;
  final macd=ema(c,12)-ema(c,26);
  final oldMacd=ema(c.sublist(0,c.length-1),12)-ema(c.sublist(0,c.length-1),26);
  final rising=fast>slow && fast>priorFast && c.last>fast && macd>0 && macd>=oldMacd;
  final falling=fast<slow && fast<priorFast && c.last<fast && macd<0 && macd<=oldMacd;
  final separation=(fast-slow).abs()/atr;
  final recent=bars.sublist(bars.length-12);
  final first=recent.sublist(0,6), second=recent.sublist(6);
  final high1=first.map((b)=>b.high).reduce(max);
  final high2=second.map((b)=>b.high).reduce(max);
  final low1=first.map((b)=>b.low).reduce(min);
  final low2=second.map((b)=>b.low).reduce(min);
  final higher=high2>high1 && low2>low1;
  final lower=high2<high1 && low2<low1;
  final extended=(c.last-fast).abs()/atr>2.1 || separation>3.0;
  final up=rising && higher && momentum>=51 && momentum<=70;
  final down=falling && lower && momentum>=30 && momentum<=49;
  return FrameReading(up?'BULLISH':down?'BEARISH':'MIXED',momentum,atr,separation,up,down,extended);
}

Setup? assess(String symbol,List<Candle> bars) {
  // 15m EMA50 requires at least 750 minutes of history.
  final one=readFrame(bars);
  final five=readFrame(aggregateBars(bars,5));
  final fifteen=readFrame(aggregateBars(bars,15));
  if(one==null || five==null || fifteen==null) return null;
  final bull=one.up && five.up && fifteen.up;
  final bear=one.down && five.down && fifteen.down;
  if(!bull && !bear) return null;
  if(one.extended || five.extended || one.strength<0.16) return null;
  final direction=bull?'CALL':'PUT';
  final strength=min(15.0,one.strength*8);
  final alignment=min(10.0,five.strength*5);
  final score=(72.0+strength+alignment).clamp(0.0,95.0).toDouble();
  final detail='PRO 2.0 • 1m ${one.trend}, 5m ${five.trend}, 15m ${fifteen.trend}; '
    'higher-timeframe confirmation; structure + EMA20/50 + MACD + RSI; '
    'ATR entry filter; RSI ${one.momentum.toStringAsFixed(1)}. '
    'Indicator agreement only, NOT a win probability.';
  return Setup(symbol,direction,detail,score,one.momentum,one.strength*100,bars.last.close,bars.last.epoch);
}

class DigitSample {
  final List<int> counts;
  final int last;
  final int precision;
  final int total;
  DigitSample(this.counts,this.last,this.precision,this.total);
  double pct(int n) => total==0 ? 0 : counts[n]*100/total;
}

class DemoTrade {
  final String symbol, side, contractId;
  final double stake;
  String status='OPEN';
  double profit=0;
  DemoTrade(this.symbol,this.side,this.contractId,this.stake);
}

class LabHome extends StatefulWidget {
  const LabHome({super.key});
  @override
  State<LabHome> createState() => _LabHomeState();
}

class _LabHomeState extends State<LabHome> with WidgetsBindingObserver {
  final api = DerivApi();
  final appId = TextEditingController();
  final token = TextEditingController();
  final statuses = <String,String>{for (final m in markets) m:'Not scanned'};
  final history = <Setup>[];
  final known = <String>{};
  final precision = <String,int>{};
  int page=0, interval=60, threshold=75, scans=0, generation=0, targetDigit=5;
  bool autoTrade=false, orderBusy=false, unresolvedOrder=false;
  int maxTrades=6, maxConsecutiveLosses=2, tradeCount=0, lossStreak=0;
  double maxSessionLoss=1.00, sessionPnl=0;
  String? activeContractId;
  final List<DemoTrade> demoTrades=[];
  final Set<String> tradedSignals={};
  DateTime? lastOrderAt;

  String? livePrice;
  bool resumeLiveOnForeground=false;
  String strategy='Even';
  DateTime? predictionDeadline;
  String? lockedPrediction;
  String? lockedMarket;
  int? lockedBarrier;
  int? revealedDigit;
  String predictionOutcome='Tap Matches or Differs to start a 10-second observation.';
  final Map<String,List<int>> predictionStats={}; // [correct, evaluated]
  int predictionRound=0;
  int? suggestedDigit;
  double? suggestedFrequency;
  int get actualized => (predictionStats['Matches'] ?? [0,0])[1];
  int get actualizedWins => (predictionStats['Matches'] ?? [0,0])[0];
  void chooseBestDigit() {
    final d=sample;
    if(d==null || d.total<100) { suggestedDigit=null; suggestedFrequency=null; return; }
    final ranked=List<int>.generate(10,(i)=>i)..sort((a,b)=>d.counts[b].compareTo(d.counts[a]));
    suggestedDigit=ranked.first;
    suggestedFrequency=d.pct(ranked.first);
  }
  bool get predictionActive => predictionDeadline!=null && revealedDigit==null;
  int get predictionRemaining => predictionDeadline==null ? 0 :
      (predictionDeadline!.difference(DateTime.now()).inMilliseconds / 1000).ceil().clamp(0,10).toInt();
  void startPrediction() {
    if (!api.online || !liveDigits || sample==null || predictionActive) return;
    if(strategy=='Matches' && sample!.total<100) {note('Collect at least 100 ticks');return;}
    setState(() {
      predictionRound++;
      lockedPrediction=strategy;
      lockedMarket=selected;
      if(strategy=='Matches') chooseBestDigit();
      lockedBarrier=strategy=='Matches' ? suggestedDigit : targetDigit;
      revealedDigit=null;
      predictionDeadline=DateTime.now().add(const Duration(seconds:10));
      predictionOutcome='Prediction locked. Waiting for first tick at or after deadline…';
    });
  }
  bool _predictionCorrect(String type,int digit,int barrier) {
    switch(type) {
      case 'Even': return digit.isEven;
      case 'Odd': return digit.isOdd;
      case 'Over': return digit>barrier;
      case 'Under': return digit<barrier;
      case 'Matches': return digit==barrier;
      case 'Differs': return digit!=barrier;
      default: return false;
    }
  }
  void _observePredictionDigit(int digit) {
    if (!predictionActive || predictionDeadline==null || lockedMarket!=selected) return;
    if (DateTime.now().isBefore(predictionDeadline!)) return;
    final type=lockedPrediction!;
    final success=_predictionCorrect(type,digit,lockedBarrier!);
    final stats=predictionStats.putIfAbsent(type,()=>[0,0]);
    stats[1]++;
    if(success) stats[0]++;
    revealedDigit=digit;
    predictionOutcome=success?'CORRECT prediction':'INCORRECT prediction';
  }

  double demoStake=0.35;
  bool connecting=false, scanning=false, refreshing=false;
  String account='', status='Disconnected', selected='R_25';
  DateTime? updated;
  DigitSample? sample;
  Setup? best;
  Timer? _digitTimer;
  bool _pollingTick=false;
  bool streamingTicks=false;
  bool liveDigits=false;
  final Queue<int> _recentDigits=Queue<int>();
  final Queue<double> _recentPrices=Queue<double>();
  void _recordPrice(dynamic raw) {
    final price=double.tryParse("$raw");
    if(price==null || !price.isFinite) return;
    _recentPrices.addLast(price);
    while(_recentPrices.length>240) { _recentPrices.removeFirst(); }
  }
  String get liveTrend {
    if(_recentPrices.length<20) return "Collecting live prices";
    final p=_recentPrices.toList();
    final short=p.sublist(p.length-10).reduce((a,b)=>a+b)/10;
    final long=p.sublist(p.length-20).reduce((a,b)=>a+b)/20;
    final movement=p.skip(1).toList().asMap().entries.fold<double>(0,(sum,e)=>sum+(e.value-p[e.key]).abs())/(p.length-1);
    if(movement==0) return "Sideways ↔";
    final difference=(short-long)/movement;
    if(difference>0.65) return "Uptrend ↗";
    if(difference< -0.65) return "Downtrend ↘";
    return "Sideways ↔";
  }
  int? get liveAgreement {
    if(_recentPrices.length<20) return null;
    final p=_recentPrices.toList();
    final delta=p.last-p[p.length-10];
    final up=p.skip(1).toList().asMap().entries.where((e)=>e.value>p[e.key]).length;
    final down=p.skip(1).toList().asMap().entries.where((e)=>e.value<p[e.key]).length;
    final total=up+down;
    if(total==0) return 0;
    final direction=liveTrend.startsWith("Up")?1:liveTrend.startsWith("Down")?-1:0;
    final votes=direction==1?up:direction==-1?down:total~/2;
    final alignment=(votes/total*100).round();
    return ((alignment+(direction==0?40:delta.sign==direction?80:20))/2).round().clamp(0,100);
  }
  String get livePattern {
    if(_recentPrices.length<20) return "Waiting for at least 20 prices";
    final p=_recentPrices.toList();
    final a=p.sublist(p.length-20,p.length-10);
    final b=p.sublist(p.length-10);
    if(b.reduce(max)>a.reduce(max) && b.reduce(min)>a.reduce(min)) return "Higher highs and higher lows";
    if(b.reduce(max)<a.reduce(max) && b.reduce(min)<a.reduce(min)) return "Lower highs and lower lows";
    return "Mixed price structure • wait for confirmation";
  }
  int? _latestTickEpoch;
  DateTime? _digitReceivedAt;
  String? _digitError;
  int get digitSecondsRemaining {
    if (_digitReceivedAt==null || sample==null) return 0;
    final elapsed=DateTime.now().difference(_digitReceivedAt!).inMilliseconds;
    return (10-(elapsed/1000).floor()).clamp(0,10).toInt();
  }
  double get digitCountdownProgress {
    if (_digitReceivedAt==null || sample==null) return 0;
    final elapsed=DateTime.now().difference(_digitReceivedAt!).inMilliseconds;
    return (1-elapsed/10000).clamp(0.0,1.0).toDouble();
  }
  bool get digitVisible => liveDigits && digitCountdownProgress>0 && sample!=null;


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    api.onTick = _handleStreamTick;
    api.onLost = (reason) { autoTrade=false; unresolvedOrder=activeContractId!=null || orderBusy; _stopLiveDigits(); stop(); if (mounted) setState(() { account=''; status=reason; }); };
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      resumeLiveOnForeground=liveDigits;
      _stopLiveDigits();
      if (scanning) stop('Paused in background');
    } else if (resumeLiveOnForeground && api.online && !refreshing) {
      resumeLiveOnForeground=false;
      unawaited(ticks());
    }
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    generation++;
    autoTrade=false;
    _stopLiveDigits();
    api.close();
    appId.dispose(); token.dispose();
    super.dispose();
  }
  void note(String text) { if (mounted) setState(() => status=text); }
  Future<void> connect() async {
    if (connecting || api.online) return;
    if (appId.text.trim().isEmpty || token.text.trim().isEmpty) { note('Enter App ID and demo PAT'); return; }
    setState(() { connecting=true; status='Connecting to demo…'; });
    try {
      final a = await api.connect(appId.text.trim(),token.text.trim());
      if (!mounted) { await api.close(); return; }
      setState(() { account=a; status='Demo connected'; });
      await loadPrecision();
    } catch (e) { note('Connection failed: $e'); }
    finally { if (mounted) setState(() => connecting=false); }
  }
  int? _precisionValue(dynamic raw) {
    if (raw == null) return null;
    final text = '$raw'.trim();
    final integer = int.tryParse(text);
    if (integer != null && integer >= 0 && integer <= 10) return integer;
    final n = double.tryParse(text);
    if (n == null || n <= 0 || n >= 1) return null;
    // A pip increment such as 0.001 represents three decimal places.
    final normalized = n.toStringAsFixed(10).replaceFirst(RegExp(r'0+$'), '');
    final dot = normalized.indexOf('.');
    return dot < 0 ? 0 : normalized.length - dot - 1;
  }

  Future<void> loadPrecision() async {
    try {
      final response = await api.request({'active_symbols':'full'});
      final list = response['active_symbols'];
      if (list is! List) return;
      for (final row in list) {
        if (row is! Map) continue;
        final symbol = '${row['symbol']}';
        final places = _precisionValue(row['pip_size']) ?? _precisionValue(row['pip']);
        if (places != null) precision[symbol] = places;
      }
    } catch (_) { /* Fallback to live tick metadata below. */ }
  }

  Future<int> resolvePrecision(String symbol, Map<String,dynamic> historyResponse) async {
    final history = historyResponse['history'];
    final fromHistory = _precisionValue(historyResponse['pip_size']) ??
        (history is Map ? _precisionValue(history['pip_size']) : null);
    if (fromHistory != null) return precision[symbol] = fromHistory;
    if (precision[symbol] != null) return precision[symbol]!;
    // The latest tick carries authoritative quote precision on Deriv's API.
    final quote = await api.request({'ticks':symbol});
    final tick = quote['tick'];
    final fromTick = tick is Map ? _precisionValue(tick['pip_size']) : null;
    if (fromTick != null) return precision[symbol] = fromTick;
    // Preserve exact decimal places only if the server sent prices as strings.
    final prices = history is Map ? history['prices'] : null;
    if (prices is List && prices.isNotEmpty && prices.every((p)=>p is String)) {
      final decimals = prices.cast<String>().map((p) => p.contains('.') ? p.split('.').last.length : 0).toSet();
      if (decimals.length == 1 && decimals.first > 0 && decimals.first <= 10) {
        return precision[symbol] = decimals.first;
      }
    }
    throw StateError('Quote precision missing from API. Cannot safely calculate last digits.');
  }
  Future<void> disconnect() async {
    autoTrade=false;
    _stopLiveDigits();
    stop();
    await api.close();
    if (mounted) setState(() { account=''; status='Disconnected'; sample=null; });
  }
  void stop([String reason='Scan stopped']) {
    generation++;
    if (mounted) setState(() { scanning=false; status=reason; });
  }
  Future<List<Candle>> candles(String symbol, {int count=900}) async {
    final response = await api.request({'ticks_history':symbol,'end':'latest','style':'candles','granularity':60,'count':count});
    final raw=response['candles'];
    if (raw is! List) throw StateError('Candle history unavailable');
    final now=DateTime.now().millisecondsSinceEpoch~/1000;
    final values=raw.map(Candle.parse).whereType<Candle>().where((b)=>b.epoch+60<=now-2).toList();
    values.sort((a,b)=>a.epoch.compareTo(b.epoch));
    return values;
  }
  Future<void> scan() async {
    if (!api.online || scanning) { note('Connect demo first'); return; }
    final run=++generation;
    setState(() { scanning=true; status='Scanning five markets'; });
    while (mounted && scanning && run==generation && api.online) {
      final found=<Setup>[];
      for (final m in markets) {
        if (!mounted || !scanning || run!=generation) break;
        try {
          final bars=await candles(m);
          if (!mounted || run!=generation) break;
          final setup=assess(m,bars);
          if (setup==null) { statuses[m]='NO TRADE • 1m/5m/15m disagreement, incomplete data, or entry filter'; }
          else {
            statuses[m]='${setup.direction} • ${setup.score.toStringAsFixed(0)}/100 agreement';
            if (setup.score>=threshold) {
              found.add(setup);
              final key='$m:${setup.epoch}:${setup.direction}';
              if (known.add(key)) {
                history.insert(0,setup);
                if (history.length>100) history.removeLast();
              }
            }
          }
        } catch (e) { statuses[m]='Data unavailable: $e'; }
        if (mounted) setState(() {});
      }
      if (!mounted || run!=generation || !scanning) break;
      found.sort((a,b)=>b.score.compareTo(a.score));
      await checkOutcomes(run);
      if (!mounted || run!=generation) break;
      setState(() { best=found.isEmpty?null:found.first; scans++; updated=DateTime.now(); status=found.isEmpty?'Scan completed • no qualifying setup':'Best: ${found.first.symbol} ${found.first.direction}'; });
      if (autoTrade && best!=null && canTrade) {
        // Only act on the latest closed candle, never a stale recommendation.
        final signal=best!;
        final now=DateTime.now().millisecondsSinceEpoch~/1000;
        if(now-signal.epoch<120) await executeDemo(signal);
      }
      for (var i=0;i<interval && scanning && run==generation;i++) { await Future.delayed(const Duration(seconds:1)); }
    }
    if (mounted && run==generation) setState(() => scanning=false);
  }
  Future<void> checkOutcomes(int run) async {
    // Paper evaluation: close of the fifth completed 60-second candle after signal.
    // Not a broker contract outcome and does not include entry delays or payout.
    final now=DateTime.now().millisecondsSinceEpoch~/1000;
    final pending=history.where((s)=>s.result=='PENDING' && now>=s.epoch+360).toList();
    for (final symbol in pending.map((s)=>s.symbol).toSet()) {
      if (run!=generation || !api.online) return;
      try {
        final bars=await candles(symbol,count:180);
        for (final s in pending.where((x)=>x.symbol==symbol)) {
          final future=bars.where((b)=>b.epoch>=s.epoch+300).toList();
          if (future.isEmpty) continue;
          final exit=future.first.close;
          s.result=exit==s.entry?'DRAW':((s.direction=='CALL' && exit>s.entry)||(s.direction=='PUT' && exit<s.entry))?'WIN':'LOSS';
        }
      } catch (_) {}
    }
  }

  bool get canTrade => demoStake>=0.35 && demoStake<=10000 && demoStake.isFinite && api.online && !orderBusy && !unresolvedOrder &&
      activeContractId==null && tradeCount<maxTrades &&
      demoStake <= maxSessionLoss + sessionPnl &&
      lossStreak<maxConsecutiveLosses && sessionPnl > -maxSessionLoss &&
      (lastOrderAt==null || DateTime.now().difference(lastOrderAt!).inSeconds>=300);

  Future<void> reviewTrade(Setup signal) async {
    if(!canTrade) { note('Trade unavailable: connection, open contract or risk limit'); return; }
    final approved=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Approve DEMO trade'),
      content:Text('${signal.symbol} ${signal.direction}\n'
        'Stake: \$${demoStake.toStringAsFixed(2)}\nDuration: 5 minutes\n'
        'Indicator agreement: ${signal.score.toStringAsFixed(0)}/100\n\n'
        'This will purchase a contract using virtual demo funds.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('CANCEL')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('BUY DEMO'))],
    ));
    if(approved==true) await executeDemo(signal);
  }

  Future<void> executeDemo(Setup signal) async {
    if(!canTrade) {note('Trade blocked by risk or open-contract protection');return;}
    final now=DateTime.now().millisecondsSinceEpoch~/1000;
    if(now-signal.epoch>=180 || now<signal.epoch) {note('Signal expired');return;}
    final key='${signal.symbol}:${signal.epoch}:${signal.direction}';
    if(!tradedSignals.add(key)) {note('Already traded this candle');return;}
    setState(() {orderBusy=true;status='Requesting demo contract proposal…';});
    var buyAttempted=false;
    try {
      // CALL/PUT are Rise/Fall contract types; broker validates availability.
      final proposal=await api.request({
        'proposal':1,'amount':double.parse(demoStake.toStringAsFixed(2)),
        'basis':'stake','contract_type':signal.direction,
        'currency':'USD','duration':5,'duration_unit':'m',
        'underlying_symbol':signal.symbol,
      });
      final offer=proposal['proposal'];
      if(offer is! Map) throw StateError('No valid proposal from broker');
      final proposalId=offer['id']?.toString();
      final ask=double.tryParse('${offer['ask_price']}');
      if(proposalId==null || proposalId.isEmpty || ask==null || ask<=0 || ask>demoStake+0.011) {
        throw StateError('Proposal missing or price exceeds configured stake');
      }
      if(!mounted || !api.online) throw StateError('Disconnected before purchase');
      // Lock before sending: a timed-out buy may still have succeeded.
      buyAttempted=true;
      unresolvedOrder=true;
      final bought=await api.request({'buy':proposalId,'price':ask});
      final details=bought['buy'];
      if(details is! Map || details['contract_id']==null) {
        throw StateError('Buy response has no contract ID; verify account before retrying');
      }
      final id='${details['contract_id']}';
      final trade=DemoTrade(signal.symbol,signal.direction,id,ask);
      demoTrades.insert(0,trade);
      activeContractId=id;
      unresolvedOrder=false;
      tradeCount++;
      lastOrderAt=DateTime.now();
      note('DEMO contract $id purchased • monitoring settlement');
      // Poll until broker reports settlement; don't submit another trade while open.
      unawaited(monitorContract(trade));
    } catch(e) {
      if(buyAttempted) {
        autoTrade=false;
        note('BUY STATUS UNCERTAIN: $e. Auto OFF. Check Deriv account before reset.');
      } else {
        note('Demo proposal rejected: $e');
      }
    } finally {
      if(mounted) setState(()=>orderBusy=false);
    }
  }

  Future<void> monitorContract(DemoTrade trade) async {
    // The app must remain in foreground for settlement polling.
    while(mounted && api.online && activeContractId==trade.contractId) {
      try {
        final reply=await api.request({
          'proposal_open_contract':1,
          'contract_id':int.parse(trade.contractId),
        });
        final c=reply['proposal_open_contract'];
        if(c is! Map) throw StateError('Missing contract status');
        final sold=c['is_sold']==1 || c['is_sold']==true ||
          ['won','lost','sold'].contains('${c['status']}'.toLowerCase());
        if(sold) {
          final pnl=double.tryParse('${c['profit']}');
          if(pnl==null) throw StateError('Settlement profit unavailable');
          trade.profit=pnl;
          trade.status=pnl>0?'WIN':pnl<0?'LOSS':'DRAW';
          sessionPnl+=pnl;
          lossStreak=pnl<0?lossStreak+1:0;
          activeContractId=null;
          if(lossStreak>=maxConsecutiveLosses || sessionPnl<=-maxSessionLoss || tradeCount>=maxTrades) {
            autoTrade=false;
          }
          note('DEMO ${trade.status} • P/L \$${pnl.toStringAsFixed(2)}');
          return;
        }
      } catch(e) {
        // A missing status must never unlock a potentially open contract.
        note('Settlement check pending: $e');
      }
      await Future.delayed(const Duration(seconds:5));
    }
    if(activeContractId==trade.contractId) {
      autoTrade=false;
      unresolvedOrder=true;
      note('Contract status unresolved. Check demo account before new trades.');
    }
  }

  Future<void> confirmReconciled() async {
    if(!api.online || orderBusy) return;
    final confirm=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Reconcile demo account'),
      content:const Text('Only reset after checking your Deriv demo portfolio and confirming no open or unrecorded contracts. Risk counters remain unchanged.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('CANCEL')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('I VERIFIED'))],
    ));
    if(confirm==true && mounted) setState(() {
      activeContractId=null;unresolvedOrder=false;autoTrade=false;
      status='Reconciled manually • automatic mode remains OFF';
    });
  }

  void _stopLiveDigits() {
    liveDigits=false;
    streamingTicks=false;
    unawaited(api.unsubscribeTicks());
    _digitTimer?.cancel();
    _digitTimer=null;
    _digitReceivedAt=null;
    _latestTickEpoch=null;
    if (predictionActive) {
      predictionDeadline=null;
      predictionOutcome='Prediction cancelled: live feed stopped. No result recorded.';
    }
  }

  void _changeDigitMarket(String market) {
    _stopLiveDigits();
    setState(() {selected=market;sample=null;livePrice=null;_recentDigits.clear();_recentPrices.clear();_digitError=null;});
    if(api.online) unawaited(ticks());
  }

  int? _digitFromPrice(dynamic raw,int places) {
    final n=double.tryParse('$raw');
    if(n==null || !n.isFinite) return null;
    final formatted=n.toStringAsFixed(places);
    return int.tryParse(formatted.substring(formatted.length-1));
  }

  void _handleStreamTick(Map<String, dynamic> message) {
    if (!mounted || !liveDigits || !streamingTicks || sample == null) return;
    final tick = message['tick'];
    if (tick is! Map) return;
    final symbol = tick['symbol']?.toString();
    if (symbol != null && symbol != selected) return;
    final epoch = int.tryParse('${tick['epoch']}');
    final quote = tick['quote'];
    if (epoch == null || quote == null) return;
    final places = _precisionValue(tick['pip_size']) ?? precision[selected] ?? sample!.precision;
    final digit = _digitFromPrice(quote, places);
    if (digit == null) return;
    // Same-second ticks are valid. Do not reject them based on epoch alone.
    _latestTickEpoch = epoch;
    _recentDigits.addLast(digit);
    while (_recentDigits.length > 1000) { _recentDigits.removeFirst(); }
    final counts = List<int>.filled(10, 0);
    for (final n in _recentDigits) { counts[n]++; }
    setState(() {
      _recordPrice(quote);
      livePrice = double.tryParse('$quote')?.toStringAsFixed(places) ?? '$quote';
      sample = DigitSample(counts, digit, places, _recentDigits.length);
      _digitReceivedAt = DateTime.now();
      _digitError = null;
      _observePredictionDigit(digit);
      if(!predictionActive) chooseBestDigit();
    });
  }

  // Poll the latest quote every two seconds. New quotes replace the old
  // digit immediately; the ten-second timer is only a display expiry.
  Future<void> _pollLatestDigit() async {
    if(!mounted || !liveDigits || !api.online || _pollingTick || sample==null) return;
    _pollingTick=true;
    final symbol=selected;
    try {
      final response=await api.request({'ticks':symbol});
      final raw=response['tick'];
      if(raw is! Map || !mounted || !liveDigits || selected!=symbol) return;
      final epoch=int.tryParse('${raw['epoch']}');
      final quote=raw['quote'];
      if(epoch==null || quote==null) return;
      final places=_precisionValue(raw['pip_size']) ?? precision[symbol] ?? sample!.precision;
      final digit=_digitFromPrice(quote,places);
      if(digit==null) return;
      if(_latestTickEpoch!=null && epoch<=_latestTickEpoch!) return;
      _latestTickEpoch=epoch;
      _recentDigits.addLast(digit);
      while(_recentDigits.length>1000) { _recentDigits.removeFirst(); }
      final counts=List<int>.filled(10,0);
      for(final n in _recentDigits) { counts[n]++; }
      setState(() {
        _recordPrice(quote);
        livePrice=double.tryParse('$quote')?.toStringAsFixed(places) ?? '$quote';
        sample=DigitSample(counts,digit,places,_recentDigits.length);
        _digitReceivedAt=DateTime.now();
        _digitError=null;
        _observePredictionDigit(digit);
      if(!predictionActive) chooseBestDigit();
      });
    } catch(e) {
      if(mounted && liveDigits) setState(()=>_digitError='Live quote update failed. Retrying…');
    } finally { _pollingTick=false; }
  }

  void _startLiveDigits() {
    if(!api.online || sample==null) return;
    _digitTimer?.cancel();
    liveDigits=true;
    streamingTicks=false;
    _digitReceivedAt=DateTime.now();
    _digitTimer=Timer.periodic(const Duration(milliseconds:250),(timer) {
      if(!mounted || !api.online || !liveDigits) {timer.cancel();return;}
      if(timer.tick%8==0 && !streamingTicks) { _pollLatestDigit(); }
      if(mounted && page==2) setState(() {});
    });
    // Prefer push ticks; fall back to polling if subscription is unsupported.
    unawaited(() async {
      try {
        await api.unsubscribeTicks();
        if (!mounted || !liveDigits) return;
        final response = await api.request({'ticks': selected, 'subscribe': 1});
        if (response['tick'] is! Map) throw StateError('Tick subscription unavailable');
        if (!mounted || !liveDigits) return;
        streamingTicks = true;
        _handleStreamTick(response);
      } catch (_) {
        streamingTicks = false;
        if (mounted && liveDigits) _pollLatestDigit();
      }
    }());
  }

  Future<void> ticks() async {
    if (!api.online || refreshing) { note('Connect demo first'); return; }
    _stopLiveDigits();
    predictionDeadline=null; revealedDigit=null; lockedPrediction=null;
    final requestedMarket=selected;
    setState(() { refreshing=true; sample=null; livePrice=null; status='Loading live tick history…'; });
    try {
      final response=await api.request({'ticks_history':selected,'end':'latest','style':'ticks','count':1000});
      final data=response['history'];
      if (data is! Map || data['prices'] is! List) throw StateError('Tick prices missing');
      final raw=data['prices'] as List;
      final places=await resolvePrecision(selected,response);
      final counts=List<int>.filled(10,0);
      var total=0, last=0;
      _recentDigits.clear();
      _recentPrices.clear();
      for (final price in raw) {
        _recordPrice(price);
        final digit=_digitFromPrice(price,places);
        if (digit==null) continue;
        counts[digit]++; last=digit; total++;
        _recentDigits.addLast(digit);
      }
      if (total==0) throw StateError('No valid ticks returned');
      if (!mounted || selected!=requestedMarket || !api.online) return;
      setState(() { sample=DigitSample(counts,last,places,total); livePrice=double.tryParse('${raw.last}')?.toStringAsFixed(places) ?? '${raw.last}'; status='Loaded $total $selected ticks • live updates enabled'; });
      chooseBestDigit();
      _startLiveDigits();
    } catch (e) { note('Tick analysis failed: $e'); }
    finally { if (mounted) setState(() => refreshing=false); }
  }

  Widget panel(String title,Widget child) => Card(
    margin:const EdgeInsets.only(bottom:14),color:panelNavy,
    shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(20)),
    child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(title,style:const TextStyle(fontSize:19,fontWeight:FontWeight.w800)),const SizedBox(height:14),child,
    ])),
  );
  Widget label(String text) => Text(text,style:const TextStyle(fontSize:14,color:Color(0xFFB2C4DD)));
  Widget dashboard() => Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
    panel('Trading overview',Wrap(spacing:12,runSpacing:8,children:[
      Chip(avatar:const Icon(Icons.sensors,size:18),label:Text('Markets: ${markets.length}')),
      Chip(avatar:const Icon(Icons.analytics,size:18),label:Text('Signals: ${history.length}')),
      Chip(avatar:const Icon(Icons.shield_outlined,size:18),label:const Text('DEMO • TRADING ENABLED')),
    ])),
    panel('Connection',Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      TextField(controller:appId,decoration:const InputDecoration(labelText:'Deriv App ID')),
      TextField(controller:token,obscureText:true,autocorrect:false,enableSuggestions:false,decoration:const InputDecoration(labelText:'Demo PAT • never saved')),
      const SizedBox(height:12),Wrap(spacing:8,children:[
        FilledButton(onPressed:api.online||connecting?null:connect,child:Text(connecting?'Connecting…':'Connect demo')),
        OutlinedButton(onPressed:api.online?disconnect:null,child:const Text('Disconnect')),
      ]),if (account.isNotEmpty) label('Demo account: $account'),
    ])),
    panel('Market scanner',Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      label('Five markets • closed 1-minute candles • demo trades only'),
      const SizedBox(height:10),Wrap(spacing:8,children:[
        FilledButton.icon(onPressed:api.online&&!scanning?scan:null,icon:const Icon(Icons.play_arrow),label:const Text('Start scan')),
        OutlinedButton.icon(onPressed:scanning?()=>stop():null,icon:const Icon(Icons.stop),label:const Text('Stop')),
      ]),const SizedBox(height:8),label('Cycles: $scans  •  ${updated==null?'Never scanned':'Last: ${updated!.hour.toString().padLeft(2,'0')}:${updated!.minute.toString().padLeft(2,'0')}'}'),
    ])),
    panel('Best confirmed setup',best==null?const Text('No qualifying signal in the latest cycle.'):Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('${best!.symbol}  ${best!.direction}',style:const TextStyle(fontSize:27,fontWeight:FontWeight.bold,color:purple)),
      Text('${best!.score.toStringAsFixed(0)}/100 indicator agreement (NOT win probability)'),
      label(best!.detail),label('RSI ${best!.rsi.toStringAsFixed(1)} • Movement proxy ${best!.adx.toStringAsFixed(1)}'),
    ])),
    panel('Recommended trade • manual approval',Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(best==null?'Waiting for a qualified signal':'${best!.symbol} ${best!.direction} • ${best!.score.toStringAsFixed(0)}/100 agreement',style:const TextStyle(fontWeight:FontWeight.bold)),
      const SizedBox(height:8),
      FilledButton.icon(onPressed:best==null || !canTrade?null:()=>reviewTrade(best!),
        icon:const Icon(Icons.verified_user_outlined),label:const Text('Review & buy DEMO contract')),
      label('5-minute Rise/Fall • actual demo orders • never real money'),
    ])),
    panel('Demo trading performance',Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('Trades: $tradeCount / $maxTrades • P/L: \$${sessionPnl.toStringAsFixed(2)}'),
      Text('Loss streak: $lossStreak • Open: ${activeContractId??'None'}'),
      Text(unresolvedOrder?'TRADING LOCKED: reconcile demo account':'Auto mode: ${autoTrade?'ON':'OFF'}'),
    ])),
    panel('Live market radar',Column(children:markets.map((m)=>ListTile(dense:true,contentPadding:EdgeInsets.zero,title:Text(m,style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text(statuses[m]??'Not scanned'))).toList())),
    panel('Digit analysis',Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      DropdownButton<String>(isExpanded:true,value:selected,items:markets.map((m)=>DropdownMenuItem(value:m,child:Text(m))).toList(),onChanged:(m){if(m!=null)_changeDigitMarket(m);}),
      FilledButton.tonalIcon(onPressed:api.online&&!refreshing?ticks:null,icon:const Icon(Icons.refresh),label:Text(refreshing?'Loading…':'Load 1,000 live ticks')),
      const SizedBox(height:12),digitGrid(),
    ])),
    panel('Safety',const Text('Demo-only: manual and optional automatic DEMO purchase code is present but not yet end-to-end verified. REAL-money execution is disabled. Scores measure indicator agreement, not win probability. Paper outcomes are not broker contract results.')),
  ]);
  Widget digitGrid() {
    final d=sample;
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(d==null?'No tick sample loaded':'${d.total} ticks • ${d.precision} decimal places • last digit ${d.last}'),
      const SizedBox(height:10),GridView.count(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),crossAxisCount:5,mainAxisSpacing:8,crossAxisSpacing:8,childAspectRatio:.95,children:List.generate(10,(i)=>Container(
        decoration:BoxDecoration(color:const Color(0xFF263B59),borderRadius:BorderRadius.circular(13)),
        child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[Text('$i',style:const TextStyle(fontSize:21,fontWeight:FontWeight.bold)),Text(d==null?'—':'${d.pct(i).toStringAsFixed(1)}%',style:const TextStyle(fontSize:12))]),
      ))),
      if(d!=null)...[const SizedBox(height:12),Text('Even: ${[0,2,4,6,8].map((i)=>d.pct(i)).reduce((a,b)=>a+b).toStringAsFixed(1)}%  •  Odd: ${[1,3,5,7,9].map((i)=>d.pct(i)).reduce((a,b)=>a+b).toStringAsFixed(1)}%'),const SizedBox(height:5),label('Historical frequencies only; they do not predict the next digit.')],
    ]);
  }
  // Read-only statistics, not a calibrated probability of the next digit.
  double strategyFrequency(String type, int barrier) {
    final d=sample;
    if (d==null || d.total==0) return 0;
    final digits=List.generate(10,(i)=>i);
    return digits.where((i) {
      switch(type) {
        case 'Even': return i.isEven;
        case 'Odd': return i.isOdd;
        case 'Over': return i>barrier;
        case 'Under': return i<barrier;
        case 'Matches': return i==barrier;
        case 'Differs': return i!=barrier;
        default: return false;
      }
    }).fold<double>(0,(sum,i)=>sum+d.pct(i));
  }

  Widget expertOverview() {
    final d=sample;
    final freq=strategyFrequency(strategy,targetDigit);
    final stats=predictionStats[strategy]??[0,0];
    final observed=stats[1];
    return panel('Expert Strategy Analyzer',Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Text('Market: $selected',style:const TextStyle(fontSize:17,fontWeight:FontWeight.w700)),
      const SizedBox(height:8),
      Text('Selected contract: $strategy${['Over','Under','Matches','Differs'].contains(strategy)?' • barrier $targetDigit':''}',
        style:const TextStyle(fontSize:17,fontWeight:FontWeight.bold)),
      const SizedBox(height:12),
      Wrap(spacing:8,runSpacing:8,children:[
        Chip(label:Text(d==null?'No live sample':'${d.total} sampled ticks')),
        Chip(label:Text(d==null?'Frequency unavailable':'Historical frequency ${freq.toStringAsFixed(1)}%')),
        Chip(label:Text(observed==0?'No evaluated predictions':'Simulation ${stats[0]}/$observed correct')),
      ]),
      const SizedBox(height:10),
      Text(d==null?'Connect to demo and load ticks to begin analysis.':
        'This frequency describes past digits, not the chance of winning the next contract. ' 
        'The analyzer cannot reliably predict random digits.',
        style:const TextStyle(color:Color(0xFFB2C4DD))),
      const SizedBox(height:12),
      FilledButton.icon(
        onPressed:api.online&&!refreshing?ticks:null,
        icon:const Icon(Icons.analytics_outlined),
        label:Text(refreshing?'Analysing live data…':'Start Expert Analysis'),
      ),
      const SizedBox(height:8),
      const Text('Decision: OBSERVE • A broker quote and manual confirmation are required for any trade.',
        style:TextStyle(fontWeight:FontWeight.w700)),
    ]));
  }

  Widget predictionDisplay() {
    final active=predictionActive;
    final complete=lockedPrediction!=null && revealedDigit!=null;
    final progress=active ? (predictionRemaining/10).clamp(0.0,1.0) : 0.0;
    return panel('Prediction challenge • 10 seconds',Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      const Text('Choose a strategy above, then tap Predict. The choice stays locked while the market continues updating.'),
      const SizedBox(height:12),
      Text(lockedPrediction==null?'Choose a strategy':
        '$lockedMarket • $lockedPrediction${['Over','Under','Matches','Differs'].contains(lockedPrediction)?' $lockedBarrier':''}',
        textAlign:TextAlign.center,style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold)),
      const SizedBox(height:12),
      Center(child:SizedBox(height:180,width:180,child:Stack(alignment:Alignment.center,children:[
        SizedBox.expand(child:CircularProgressIndicator(value:progress,strokeWidth:12,
          backgroundColor:const Color(0xFF30415F),color:purple)),
        Column(mainAxisAlignment:MainAxisAlignment.center,children:[
          Text(active?'${predictionRemaining}':complete?'$revealedDigit':'—',
            style:const TextStyle(fontSize:68,fontWeight:FontWeight.w900,color:purple)),
          Text(active?'SECONDS':complete?'ACTUAL DIGIT':'READY',
            style:const TextStyle(fontWeight:FontWeight.bold)),
        ]),
      ]))),
      const SizedBox(height:12),
      Text(predictionOutcome,textAlign:TextAlign.center,
        style:TextStyle(fontWeight:FontWeight.w700,color:complete?
          (predictionOutcome.startsWith('CORRECT')?const Color(0xFF16845E):const Color(0xFFC52C40)):null)),
      const SizedBox(height:14),
      FilledButton.icon(onPressed:api.online&&liveDigits&&sample!=null&&!active?startPrediction:null,
        icon:const Icon(Icons.psychology_alt_outlined),
        label:Text(active?'Prediction locked…':complete?'Predict again':'Predict • Start 10s countdown')),
      const SizedBox(height:14),
      const Text('Simulated observation only • Not a Deriv purchase or contract settlement.',
        textAlign:TextAlign.center,style:TextStyle(color:Color(0xFF655E70))),
      const SizedBox(height:10),
      ...['Even','Odd','Over','Under','Matches','Differs'].map((type){
        final n=predictionStats[type]??[0,0];
        return Padding(padding:const EdgeInsets.symmetric(vertical:2),child:Text(
          '$type: ${n[0]}/${n[1]} correct${n[1]>0?' • ${(100*n[0]/n[1]).toStringAsFixed(1)}%':''}'));
      }),
    ]));
  }

  Widget analyzer() {
    const blue=Color(0xFF2674F5), green=Color(0xFF18AD7B), red=Color(0xFFDC5367);
    Widget choice(String type,Color color,{bool startOnTap=false}) => FilledButton(
      style:FilledButton.styleFrom(backgroundColor:color,minimumSize:const Size(0,53),
        shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(12)),
        side:strategy==type?const BorderSide(color:Colors.white,width:2):BorderSide.none),
      onPressed:predictionActive?null:(){setState(()=>strategy=type);if(startOnTap) startPrediction();},
      child:Text(type,style:const TextStyle(fontWeight:FontWeight.bold,fontSize:16)));
    final matchType=['Over','Under','Matches','Differs'].contains(strategy);
    final relevant=best!=null && best!.symbol==selected;
    final agreement=liveAgreement; // Show the current market reading independently of trade qualification.
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      panel('Expert Trader',Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
          const Chip(label:Text('Deriv Connector')),
          Chip(avatar:Icon(Icons.circle,size:12,color:api.online?green:red),label:Text(api.online?'DEMO connected':'Disconnected')),
        ]),
        const SizedBox(height:12),
        const Text('Market                        Volatility',style:TextStyle(fontWeight:FontWeight.w600)),
        Row(children:[
          Expanded(child:DropdownButton<String>(isExpanded:true,value:strategy,
            items:['Even','Odd','Over','Under','Matches','Differs'].map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),
            onChanged:predictionActive?null:(v){if(v!=null)setState(()=>strategy=v);})),
          const SizedBox(width:12),
          Expanded(child:DropdownButton<String>(isExpanded:true,value:selected,
            items:markets.map((m)=>DropdownMenuItem(value:m,child:Text('Volatility ${m.substring(2)}'))).toList(),
            onChanged:predictionActive?null:(m){if(m!=null)_changeDigitMarket(m);})),
        ]),
        const SizedBox(height:10),
        const Text('Contract Type                   Duration',style:TextStyle(fontWeight:FontWeight.w600)),
        Row(children:[
          Expanded(child:Text(matchType?'Digit $strategy':'Digits $strategy',style:const TextStyle(fontSize:16))),
          const SizedBox(width:14),const Expanded(child:Text('10 seconds (simulation)',style:TextStyle(fontSize:13))),
        ]),
        if(matchType)...[const SizedBox(height:8),Text('Reference digit / barrier: $targetDigit'),
          Slider(value:targetDigit.toDouble(),min:0,max:9,divisions:9,
            onChanged:predictionActive?null:(v)=>setState(()=>targetDigit=v.round()))],
      ])),
      panel('Live Market',Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Center(child:Text('Volatility ${selected.substring(2)} Index',style:const TextStyle(fontWeight:FontWeight.w700))),
        const SizedBox(height:6),
        Center(child:Text(livePrice??'—',style:const TextStyle(fontSize:36,color:blue,fontWeight:FontWeight.w900))),
        Center(child:Text(!api.online?'● Disconnected':sample==null?'● Waiting for market data':liveDigits?'● Live Data Connected':'● Feed paused',style:TextStyle(color:api.online&&liveDigits&&sample!=null?green:red))),
        const SizedBox(height:12),Row(children:[
          Expanded(child:FilledButton(style:FilledButton.styleFrom(backgroundColor:red),onPressed:liveDigits?_stopLiveDigits:null,child:const Text('Stop Analysis'))),
          const SizedBox(width:8),Expanded(child:FilledButton(style:FilledButton.styleFrom(backgroundColor:blue),onPressed:api.online&&!refreshing?ticks:null,child:Text(refreshing?'Loading…':sample==null?'Load live data':'Refresh'))),
        ]),
      ])),
      panel('Strategy Selector',Column(children:[
        Row(children:[Expanded(child:choice('Even',blue)),const SizedBox(width:10),Expanded(child:choice('Odd',purple))]),
        const SizedBox(height:10),
        Row(children:[Expanded(child:choice('Over',green)),const SizedBox(width:10),Expanded(child:choice('Under',red))]),
        const SizedBox(height:10),
        Row(children:[Expanded(child:choice('Matches',blue)),const SizedBox(width:10),Expanded(child:choice('Differs',purple))]),
      ])),
      panel('Expert Analysis Tool',Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        const Text('QUICK STRATEGY • LIVE MARKET ANALYSIS',style:TextStyle(fontSize:13,fontWeight:FontWeight.bold,color:purple)),
        const SizedBox(height:8),
        Text('Market: $selected  •  ${api.online?'Demo connected':'Disconnected'}',style:const TextStyle(fontWeight:FontWeight.w600)),
        const SizedBox(height:8),
        Row(children:[Expanded(child:choice('Matches',blue,startOnTap:true)),const SizedBox(width:10),
          SizedBox(width:78,height:78,child:Stack(alignment:Alignment.center,children:[
            SizedBox(width:76,height:76,child:CircularProgressIndicator(
              value:predictionActive?predictionRemaining/10:1,
              strokeWidth:5,backgroundColor:const Color(0xFF30415F),color:purple)),
            CircleAvatar(radius:32,backgroundColor:purple,child:Text(
              predictionActive?'$lockedBarrier':revealedDigit!=null?'$revealedDigit':suggestedDigit==null?'—':'$suggestedDigit',
              style:const TextStyle(fontSize:32,color:Colors.white,fontWeight:FontWeight.bold))),
          ])),const SizedBox(width:10),Expanded(child:choice('Differs',blue,startOnTap:true))]),
        const SizedBox(height:6),
        Center(child:Text(predictionActive?(predictionRemaining>0?'${predictionRemaining}s • target $lockedBarrier locked':'10s elapsed • awaiting next live tick'):
          revealedDigit!=null?'Result: $predictionOutcome':'Tap Matches for the strongest observed digit and 10-second countdown',
          textAlign:TextAlign.center,style:const TextStyle(fontSize:12))),
        const SizedBox(height:6),
        const Center(child:Text('Centre digit is the selected target, not a guaranteed prediction.',style:TextStyle(fontSize:11,color:Colors.white70),textAlign:TextAlign.center)),
        const SizedBox(height:8),
        Text('MATCHES ACTUALIZATION: $actualizedWins / $actualized • ${actualized==0?'—':(actualizedWins*100/actualized).toStringAsFixed(1)+'%'}',style:const TextStyle(fontWeight:FontWeight.bold)),
        Text('Top digit frequency: ${suggestedFrequency==null?'—':suggestedFrequency!.toStringAsFixed(1)+'%'} (historical, not win confidence)'),
        const Divider(height:26),
        const Text('CURRENT TREND',style:TextStyle(fontSize:13,color:Color(0xFFB2C4DD),fontWeight:FontWeight.bold)),
        const SizedBox(height:5),Text(!api.online?'Connect demo to analyse':sample==null?'Load market data to begin':liveTrend,style:const TextStyle(fontSize:17,fontWeight:FontWeight.bold)),
        if(_recentPrices.length>=2) SizedBox(height:110,child:CustomPaint(painter:TrendPainter(_recentPrices.toList()))),
        const Divider(height:26),
        const Text('CONFIDENCE LEVEL • INDICATOR AGREEMENT',style:TextStyle(fontSize:13,color:Color(0xFFB2C4DD),fontWeight:FontWeight.bold)),
        const SizedBox(height:5),Text(agreement==null?'Collecting live prices':'$agreement%',style:const TextStyle(fontSize:24,fontWeight:FontWeight.bold,color:purple)),
        const SizedBox(height:5),LinearProgressIndicator(value:(agreement??0)/100,minHeight:9,borderRadius:BorderRadius.circular(8),backgroundColor:const Color(0xFF30415F),color:purple),
        const Divider(height:26),
        const Text('PATTERN DETECTED',style:TextStyle(fontSize:13,color:Color(0xFFB2C4DD),fontWeight:FontWeight.bold)),
        const SizedBox(height:6),Text(sample==null?'Load live market data':livePattern),
        const SizedBox(height:7),const Text('Live score describes price-direction agreement, NOT predicted win probability.',style:TextStyle(fontSize:12,color:Colors.white70)),
        const SizedBox(height:10),const Text('RECOMMENDED STRATEGY',style:TextStyle(fontSize:13,fontWeight:FontWeight.bold,color:Color(0xFFB2C4DD))),
        const SizedBox(height:4),Text(sample==null?'WAIT • load live prices':liveTrend.startsWith('Sideways')?'NO TRADE • sideways market':relevant?'${best!.direction} • verify contract and risk':'OBSERVE • no qualified trade signal',style:const TextStyle(fontSize:17,fontWeight:FontWeight.w800,color:purple)),
        const SizedBox(height:5),const Text('Digit strategies are separate from price-trend signals. No digit outcome is guaranteed.',style:TextStyle(fontSize:12,color:Colors.white70)),
        const SizedBox(height:12),FilledButton.icon(onPressed:api.online&&!scanning?() async {if(sample==null) await ticks(); if(api.online&&!scanning) await scan();}:null,icon:const Icon(Icons.psychology),label:Text(scanning?'Analysing…':'Start Expert Analysis')),
      ])),
      panel('Number Distribution & Percentages',digitGrid()),
      // Prediction and market information are presented once, above.

    ]);
  }

  Widget digitDial() {
    final visible=digitVisible;
    final even=visible && sample!.last.isEven;
    final tone=even?const Color(0xFF159F70):purple;
    return SizedBox(width:196,height:196,child:Stack(alignment:Alignment.center,children:[
      SizedBox(width:190,height:190,child:CircularProgressIndicator(
        value:digitCountdownProgress,strokeWidth:9,
        backgroundColor:const Color(0xFF30415F),color:tone,
        strokeCap:StrokeCap.round,
      )),
      Column(mainAxisSize:MainAxisSize.min,children:[
        AnimatedSwitcher(duration:const Duration(milliseconds:220),transitionBuilder:(child,animation)=>
          FadeTransition(opacity:animation,child:ScaleTransition(scale:animation,child:child)),
          child:Text(visible?'${sample!.last}':'—',key:ValueKey(visible?'${sample!.last}-${_latestTickEpoch ?? 0}':'expired'),
            style:TextStyle(fontSize:78,fontWeight:FontWeight.w900,color:tone))),
        Text(visible?(even?'EVEN':'ODD'):'WAITING',style:TextStyle(fontWeight:FontWeight.w800,color:tone)),
        const SizedBox(height:4),
        Text(visible?'${digitSecondsRemaining}s remaining':'Waiting for tick',style:const TextStyle(fontSize:12)),
      ]),
    ]));
  }

  Widget signalHistory() => history.isEmpty && demoTrades.isEmpty?panel('Signal history',const Text('No qualified signals yet. Start the scanner on the Dashboard.')):Column(children:[
    panel('Broker DEMO trades',Column(children:[
      Text('Recorded: ${demoTrades.length} • P/L: \$${sessionPnl.toStringAsFixed(2)}'),
      ...demoTrades.map((t)=>ListTile(title:Text('${t.symbol} ${t.side} • ${t.status}'),
        subtitle:Text('Contract ${t.contractId} • Stake \$${t.stake.toStringAsFixed(2)} • P/L \$${t.profit.toStringAsFixed(2)}'))),
    ])),
    panel('Paper outcome tracking',Builder(builder:(context){
      final done=history.where((s)=>s.result!='PENDING').toList();
      final wins=done.where((s)=>s.result=='WIN').length;
      return Text('Signals: ${history.length}  •  Evaluated: ${done.length}  •  Paper wins: $wins\n${done.isEmpty?'No evaluated outcomes yet.':'Paper directional success: ${(wins*100/done.length).toStringAsFixed(1)}%'}\n\nMeasured against a later 5-minute candle close. This is NOT a broker trade win rate.');
    })),
    ...history.map((s)=>panel('${s.symbol}  ${s.direction}  •  ${s.result}',Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('${s.score.toStringAsFixed(0)}/100 agreement'),label(s.detail),label('RSI ${s.rsi.toStringAsFixed(1)} • ATR-normalized trend strength ${s.adx.toStringAsFixed(1)}'),
      label('Candle: ${DateTime.fromMillisecondsSinceEpoch(s.epoch*1000)}'),
    ]))),
  ]);
  // Evidence gate: observed broker DEMO settlements only, never paper signals.
  // A 70% observed rate is not a guarantee of future outcomes.
  int get settledDemoCount => demoTrades.where((t)=>t.status=='WIN' || t.status=='LOSS').length;
  int get settledDemoWins => demoTrades.where((t)=>t.status=='WIN').length;
  double get settledDemoRate => settledDemoCount==0?0:settledDemoWins/settledDemoCount;
  double get demoWinRateLowerBound {
    final n=settledDemoCount;
    if(n==0) return 0;
    const z=1.96;
    final p=settledDemoRate;
    final d=1+z*z/n;
    return (p+z*z/(2*n)-z*sqrt(p*(1-p)/n+z*z/(4*n*n)))/d;
  }
  Widget readinessPanel() {
    final n=settledDemoCount;
    final rate=(settledDemoRate*100).toStringAsFixed(1);
    final lower=(demoWinRateLowerBound*100).toStringAsFixed(1);
    final enough=n>=200;
    final thresholdMet=settledDemoRate>=0.70 && demoWinRateLowerBound>=0.70;
    return panel('Real-money readiness • LOCKED',Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('REAL-MONEY ORDERS ARE NOT IMPLEMENTED OR ENABLED.',style:TextStyle(fontWeight:FontWeight.bold,color:Colors.red)),
      const SizedBox(height:8),
      Text('Verified demo settlements: $n / 200 minimum'),
      Text('Broker demo win rate: $rate% • 95% lower confidence bound: $lower%'),
      Text('Evidence check: ${enough && thresholdMet?'TARGET OBSERVED':'NOT MET'}'),
      const SizedBox(height:8),
      const Text('Goal: observe at least 70–80% success across substantial, broker-settled demo trades, with the lower confidence bound at or above 70%. A high win rate alone does not prove profitability: payout, average loss, fees, slippage and drawdown matter.'),
      const SizedBox(height:8),
      const Text('Still required before real money: verified proposal/buy/settlement on demo, persisted broker transaction history, real-account authentication, manual confirmation showing broker payout and expiry, independent daily loss cap, and reconnection reconciliation.'),
      const SizedBox(height:8),
      const Text('No XML required. Real mode must be separately implemented and tested. Never use a real PAT with this demo-only build.'),
    ]));
  }
  Widget settings() => Column(children:[
    panel('Demo execution • manual / automatic',Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      SwitchListTile(title:const Text('Automatic DEMO trading'),subtitle:const Text('Off by default • only fresh qualifying signals'),
        value:autoTrade,onChanged:(v) {
          if(v && (demoStake<0.35 || !demoStake.isFinite)) {note('Enter a valid demo stake first');return;}
          if(v && !api.online) {note('Connect demo before enabling auto');return;}
          if(v && !canTrade) {note('Risk limit or unresolved trade prevents auto');return;}
          setState(()=>autoTrade=v);
        }),
      Text('Demo stake: \$${demoStake.toStringAsFixed(2)}'),
      TextFormField(initialValue:demoStake.toStringAsFixed(2),keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Stake (USD)',helperText:'Broker contract minimum/maximum applies • DEMO only'),onChanged:(text){final amount=double.tryParse(text);if(amount!=null && amount.isFinite && amount>=0.35 && amount<=10000){setState(()=>demoStake=amount);}else{setState(()=>demoStake=0);}}),
      Text('Max trades this session: $maxTrades'),
      Slider(value:maxTrades.toDouble(),min:1,max:10,divisions:9,onChanged:(v)=>setState(()=>maxTrades=v.round())),
      Text('Maximum consecutive losses: $maxConsecutiveLosses'),
      Slider(value:maxConsecutiveLosses.toDouble(),min:1,max:4,divisions:3,onChanged:(v)=>setState(()=>maxConsecutiveLosses=v.round())),
      Text('Session loss cutoff: \$${maxSessionLoss.toStringAsFixed(2)}'),
      Slider(value:maxSessionLoss,min:0.35,max:5,divisions:93,onChanged:(v)=>setState(()=>maxSessionLoss=v)),
      FilledButton.icon(onPressed:()=>setState(() {autoTrade=false;status='EMERGENCY STOP: no new demo purchases';}),
        icon:const Icon(Icons.stop_circle),label:const Text('EMERGENCY STOP • NO NEW TRADES')),
      if(unresolvedOrder) OutlinedButton(onPressed:confirmReconciled,child:const Text('Reconcile unresolved contract')),
      const Text('Stop prevents new purchases; it does not cancel an already purchased contract.'),
    ])),
    panel('Scanner settings',Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('Interval: $interval seconds'),Slider(min:30,max:180,divisions:5,value:interval.toDouble(),onChanged:(v)=>setState(()=>interval=v.round())),
      Text('Minimum PRO agreement: $threshold/100'),Slider(min:60,max:95,divisions:7,value:threshold.toDouble(),onChanged:(v)=>setState(()=>threshold=v.round())),
      OutlinedButton(onPressed:()=>setState(() {history.clear();known.clear();best=null;}),child:const Text('Clear signal history')),
    ])),
    readinessPanel(),
    panel('Expert Mode 2.0',const Text('Closed 1m, 5m and 15m candles • EMA20/50 • MACD • RSI • market structure • ATR entry filters. Conflicting timeframes produce NO TRADE. Scores are not win probabilities. Requires sufficient history.')),
    panel('Limitations',const Text('Demo only. Automatic trading works while scanner is running in foreground. A disconnected or closed app cannot guarantee settlement monitoring. Review Deriv portfolio after interruptions. Trading has risk even with virtual funds.')),
  ]);
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar:AppBar(backgroundColor:panelNavy,title:const Text('V8 PRO • Expert Trader'),actions:[Padding(padding:const EdgeInsets.only(right:16),child:Center(child:Text(api.online?'● DEMO':'○ OFFLINE',style:TextStyle(fontWeight:FontWeight.bold,color:api.online?Colors.green:Colors.grey))))]),
    body:Column(children:[
      Container(width:double.infinity,color:panelNavy,padding:const EdgeInsets.symmetric(horizontal:16,vertical:10),child:Text(status,maxLines:2,overflow:TextOverflow.ellipsis)),
      Expanded(child:ListView(padding:const EdgeInsets.all(14),children:[if(page==0)dashboard() else if(page==1)signalHistory() else if(page==2)analyzer() else settings()])),
    ]),
    floatingActionButton:page==2?null:FloatingActionButton.extended(
      onPressed:()=>setState(()=>page=2),backgroundColor:purple,foregroundColor:Colors.white,
      icon:const Icon(Icons.auto_graph),label:const Text('Expert Analysis')),
    bottomNavigationBar:NavigationBar(selectedIndex:page,onDestinationSelected:(i)=>setState(()=>page=i),destinations:const [
      NavigationDestination(icon:Icon(Icons.dashboard_outlined),label:'Dashboard'),
      NavigationDestination(icon:Icon(Icons.history),label:'History'),
      NavigationDestination(icon:Icon(Icons.pin_outlined),label:'Analyzer'),
      NavigationDestination(icon:Icon(Icons.settings_outlined),label:'Settings'),
    ]),
  );
}


class TrendPainter extends CustomPainter {
  final List<double> prices;
  TrendPainter(this.prices);
  @override void paint(Canvas canvas,Size size) {
    if(prices.length<2)return;
    final values=prices.length>60?prices.sublist(prices.length-60):prices;
    final lo=values.reduce(min),hi=values.reduce(max);
    final span=max(hi-lo,0.00000001);
    final path=Path();
    for(var i=0;i<values.length;i++){
      final x=size.width*i/(values.length-1);
      final y=size.height-8-(values[i]-lo)/span*(size.height-16);
      if(i==0)path.moveTo(x,y);else path.lineTo(x,y);
    }
    final rising=values.last>=values.first;
    canvas.drawPath(path,Paint()..color=rising?const Color(0xFF2EE6B8):const Color(0xFFFF788A)..style=PaintingStyle.stroke..strokeWidth=2.5..strokeCap=StrokeCap.round);
  }
  @override bool shouldRepaint(covariant TrendPainter old)=>true;
}
