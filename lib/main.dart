import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

void main() => runApp(const V8App());

const markets = <String>['R_10', 'R_25', 'R_50', 'R_75', 'R_100'];
const purple = Color(0xFF6C36D7);

class V8App extends StatelessWidget {
  const V8App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'V8 PRO • Expert Trader',
    theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: purple), scaffoldBackgroundColor: const Color(0xFFF4EEFF)),
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

  Future<void> close() async {
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

Setup? assess(String symbol, List<Candle> bars) {
  if (bars.length < 100) return null;
  final c = bars.map((b) => b.close).toList();
  final f = ema(c,20), s = ema(c,50), f0 = ema(c.sublist(0,c.length-1),20);
  final momentum = rsi(c);
  final ranges = <double>[];
  for (var i=1;i<bars.length;i++) {
    ranges.add(max(bars[i].high-bars[i].low,max((bars[i].high-c[i-1]).abs(),(bars[i].low-c[i-1]).abs())));
  }
  final atr = ranges.skip(ranges.length-14).reduce((a,b)=>a+b)/14;
  if (atr <= 0) return null;
  final plus = <double>[], minus = <double>[];
  for (var i=1;i<bars.length;i++) {
    final up = bars[i].high-bars[i-1].high;
    final down = bars[i-1].low-bars[i].low;
    plus.add(up>down && up>0 ? up : 0);
    minus.add(down>up && down>0 ? down : 0);
  }
  final p = plus.skip(plus.length-14).reduce((a,b)=>a+b)/14;
  final m = minus.skip(minus.length-14).reduce((a,b)=>a+b)/14;
  final adxProxy = (p+m)==0 ? 0.0 : 100*(p-m).abs()/(p+m);
  // This is a directional-movement strength proxy, not Wilder ADX.
  final macd = ema(c,12)-ema(c,26);
  final prior = ema(c.sublist(0,c.length-1),12)-ema(c.sublist(0,c.length-1),26);
  final bull = f>s && f>f0 && c.last>f && momentum>=53 && momentum<=70 && macd>0 && macd>prior;
  final bear = f<s && f<f0 && c.last<f && momentum>=30 && momentum<=47 && macd<0 && macd<prior;
  if (!bull && !bear) return null;
  final sep = (f-s).abs()/atr;
  if (sep < .15 || sep > 3 || adxProxy < 18) return null;
  final score = (55 + min(20.0,sep*9) + min(15.0,adxProxy*.22) + min(10.0,(momentum-50).abs()*.7)).clamp(0.0,100.0).toDouble();
  return Setup(symbol,bull?'CALL':'PUT','EMA20/50 + RSI + MACD alignment; movement proxy ${adxProxy.toStringAsFixed(1)}',score,momentum,adxProxy,c.last,bars.last.epoch);
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

  String strategy='Even';
  double demoStake=0.35;
  bool connecting=false, scanning=false, refreshing=false;
  String account='', status='Disconnected', selected='R_25';
  DateTime? updated;
  DigitSample? sample;
  Setup? best;
  Timer? _digitTimer;
  bool _pollingTick=false;
  bool liveDigits=false;
  final Queue<int> _recentDigits=Queue<int>();
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
    api.onLost = (reason) { autoTrade=false; unresolvedOrder=activeContractId!=null || orderBusy; _stopLiveDigits(); stop(); if (mounted) setState(() { account=''; status=reason; }); };
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) { _stopLiveDigits(); if (scanning) stop('Paused in background'); }
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
  Future<List<Candle>> candles(String symbol, {int count=180}) async {
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
          if (setup==null) { statuses[m]='No confirmed setup'; }
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

  bool get canTrade => api.online && !orderBusy && !unresolvedOrder &&
      activeContractId==null && tradeCount<maxTrades &&
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
    _digitTimer?.cancel();
    _digitTimer=null;
    _digitReceivedAt=null;
    _latestTickEpoch=null;
  }

  void _changeDigitMarket(String market) {
    _stopLiveDigits();
    setState(() {selected=market;sample=null;_recentDigits.clear();_digitError=null;});
  }

  int? _digitFromPrice(dynamic raw,int places) {
    final n=double.tryParse('$raw');
    if(n==null || !n.isFinite) return null;
    final formatted=n.toStringAsFixed(places);
    return int.tryParse(formatted.substring(formatted.length-1));
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
        sample=DigitSample(counts,digit,places,_recentDigits.length);
        _digitReceivedAt=DateTime.now();
        _digitError=null;
      });
    } catch(e) {
      if(mounted && liveDigits) setState(()=>_digitError='Live quote update failed. Retrying…');
    } finally { _pollingTick=false; }
  }

  void _startLiveDigits() {
    if(!api.online || sample==null) return;
    _digitTimer?.cancel();
    liveDigits=true;
    _digitReceivedAt=DateTime.now();
    _digitTimer=Timer.periodic(const Duration(milliseconds:250),(timer) {
      if(!mounted || !api.online || !liveDigits) {timer.cancel();return;}
      if(timer.tick%8==0) { _pollLatestDigit(); }
      if(mounted && page==2) setState(() {});
    });
    _pollLatestDigit();
  }

  Future<void> ticks() async {
    if (!api.online || refreshing) { note('Connect demo first'); return; }
    _stopLiveDigits();
    final requestedMarket=selected;
    setState(() { refreshing=true; sample=null; status='Loading live tick history…'; });
    try {
      final response=await api.request({'ticks_history':selected,'end':'latest','style':'ticks','count':1000});
      final data=response['history'];
      if (data is! Map || data['prices'] is! List) throw StateError('Tick prices missing');
      final raw=data['prices'] as List;
      final places=await resolvePrecision(selected,response);
      final counts=List<int>.filled(10,0);
      var total=0, last=0;
      _recentDigits.clear();
      for (final price in raw) {
        final digit=_digitFromPrice(price,places);
        if (digit==null) continue;
        counts[digit]++; last=digit; total++;
        _recentDigits.addLast(digit);
      }
      if (total==0) throw StateError('No valid ticks returned');
      if (!mounted || selected!=requestedMarket || !api.online) return;
      setState(() { sample=DigitSample(counts,last,places,total); status='Loaded $total $selected ticks • live updates enabled'; });
      _startLiveDigits();
    } catch (e) { note('Tick analysis failed: $e'); }
    finally { if (mounted) setState(() => refreshing=false); }
  }

  Widget panel(String title,Widget child) => Card(
    margin:const EdgeInsets.only(bottom:14),color:Colors.white,
    shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(20)),
    child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(title,style:const TextStyle(fontSize:19,fontWeight:FontWeight.w800)),const SizedBox(height:14),child,
    ])),
  );
  Widget label(String text) => Text(text,style:const TextStyle(fontSize:14,color:Color(0xFF635C71)));
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
    panel('Safety',const Text('Demo research tool. No real or demo orders are executed. Signal scores are indicator agreement, not calibrated probabilities. Paper outcomes are not broker contract results.')),
  ]);
  Widget digitGrid() {
    final d=sample;
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(d==null?'No tick sample loaded':'${d.total} ticks • ${d.precision} decimal places • last digit ${d.last}'),
      const SizedBox(height:10),GridView.count(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),crossAxisCount:5,mainAxisSpacing:8,crossAxisSpacing:8,childAspectRatio:.95,children:List.generate(10,(i)=>Container(
        decoration:BoxDecoration(color:const Color(0xFFF1E9FF),borderRadius:BorderRadius.circular(13)),
        child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[Text('$i',style:const TextStyle(fontSize:21,fontWeight:FontWeight.bold)),Text(d==null?'—':'${d.pct(i).toStringAsFixed(1)}%',style:const TextStyle(fontSize:12))]),
      ))),
      if(d!=null)...[const SizedBox(height:12),Text('Even: ${[0,2,4,6,8].map((i)=>d.pct(i)).reduce((a,b)=>a+b).toStringAsFixed(1)}%  •  Odd: ${[1,3,5,7,9].map((i)=>d.pct(i)).reduce((a,b)=>a+b).toStringAsFixed(1)}%'),const SizedBox(height:5),label('Historical frequencies only; they do not predict the next digit.')],
    ]);
  }
  Widget analyzer() => Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
    panel('Market & strategy',Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      DropdownButton<String>(value:selected,isExpanded:true,items:markets.map((m)=>DropdownMenuItem(value:m,child:Text(m))).toList(),onChanged:(m){if(m!=null)_changeDigitMarket(m);}),
      GridView.count(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),crossAxisCount:2,mainAxisSpacing:8,crossAxisSpacing:8,childAspectRatio:2.9,
        children:['Even','Odd','Over','Under'].map((s)=>FilledButton(
          style:FilledButton.styleFrom(backgroundColor:s=='Even'?const Color(0xFF1659E9):s=='Odd'?purple:s=='Over'?const Color(0xFF11A365):const Color(0xFFE62C34),
          side:strategy==s?const BorderSide(color:Colors.black,width:3):BorderSide.none),
          onPressed:()=>setState(()=>strategy=s),child:Text(s,style:const TextStyle(fontWeight:FontWeight.bold)),
        )).toList()),
      const SizedBox(height:8),label('Selected: $strategy • informational only'),
      if(strategy=='Over'||strategy=='Under')...[
        const SizedBox(height:8),Text('Digit barrier: $targetDigit'),
        Slider(value:targetDigit.toDouble(),min:0,max:9,divisions:9,onChanged:(v)=>setState(()=>targetDigit=v.round())),
      ],
    ])),
    panel('Live Analysis',Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Center(child:Text(selected,style:const TextStyle(fontSize:18,fontWeight:FontWeight.bold))),
      const SizedBox(height:14),Center(child:digitDial()),
      const SizedBox(height:8),Center(child:Text(sample==null?'Load 1,000 ticks to begin':
        digitVisible?'New market tick replaces this digit immediately':
        'No new tick in 10 seconds • waiting for the next quote',textAlign:TextAlign.center)),
      if(_digitError!=null)...[const SizedBox(height:8),Center(child:label(_digitError!))],
      if(sample!=null) Center(child:label('${sample!.total} recent ticks • last observed digit')), 
      const SizedBox(height:12),FilledButton.icon(onPressed:api.online&&!refreshing?ticks:null,icon:const Icon(Icons.refresh),label:Text(refreshing?'Loading…':'Live ticks • refresh')),
    ])),
    panel('AI Market Analyzer • rule-based',Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('Current trend',style:Theme.of(context).textTheme.labelLarge),
      const SizedBox(height:4),Text(best==null?'Awaiting confirmed market analysis':'${best!.symbol}: ${best!.direction} • EMA / RSI / MACD agreement',style:const TextStyle(fontWeight:FontWeight.bold)),
      const SizedBox(height:14),Text('Pattern detected',style:Theme.of(context).textTheme.labelLarge),
      const SizedBox(height:4),Text(sample==null?'Load live ticks to view digit distribution.':
        'Observed ${sample!.total} ticks. ${strategy=='Even'? 'Even':strategy=='Odd'?'Odd':strategy} is descriptive, not a prediction.'),
      const SizedBox(height:14),Row(mainAxisAlignment:MainAxisAlignment.spaceEvenly,children:[
        FilledButton.tonal(onPressed:()=>setState(()=>strategy='Matches'),child:const Text('Matches')),
        CircleAvatar(radius:39,backgroundColor:digitVisible && sample!.last.isEven?const Color(0xFF159F70):purple,child:Text(digitVisible?'${sample!.last}':'—',style:const TextStyle(color:Colors.white,fontSize:30,fontWeight:FontWeight.bold))),
        FilledButton.tonal(onPressed:()=>setState(()=>strategy='Differs'),child:const Text('Differs')),
      ]),
      const SizedBox(height:6),Center(child:label('Latest observed digit • 10-second expiry • not a prediction')),
    ])),
    panel('Number Distribution Percentages',digitGrid()),
    panel('Strategy statistics',Builder(builder:(context){
      final d=sample;
      if(d==null) return const Text('Connect demo and load live ticks.');
      final percent=strategy=='Even'?[0,2,4,6,8].fold<double>(0,(v,i)=>v+d.pct(i)):
        strategy=='Odd'?[1,3,5,7,9].fold<double>(0,(v,i)=>v+d.pct(i)):
        strategy=='Over'?List.generate(10,(i)=>i).where((i)=>i>targetDigit).fold<double>(0,(v,i)=>v+d.pct(i)):
        strategy=='Under'?List.generate(10,(i)=>i).where((i)=>i<targetDigit).fold<double>(0,(v,i)=>v+d.pct(i)):
        strategy=='Matches'?d.pct(targetDigit):100-d.pct(targetDigit);
      return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('$strategy • ${percent.toStringAsFixed(1)}% of sampled ticks',style:const TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
        const SizedBox(height:8),const Text('Historical frequency is not the probability of the next result.'),
        if(strategy=='Matches'||strategy=='Differs')...[
          const SizedBox(height:8),Text('Reference digit: $targetDigit'),
          Slider(value:targetDigit.toDouble(),min:0,max:9,divisions:9,onChanged:(v)=>setState(()=>targetDigit=v.round())),
        ],
      ]);
    })),
  ]);

  Widget digitDial() {
    final visible=digitVisible;
    final even=visible && sample!.last.isEven;
    final tone=even?const Color(0xFF159F70):purple;
    return SizedBox(width:196,height:196,child:Stack(alignment:Alignment.center,children:[
      SizedBox(width:190,height:190,child:CircularProgressIndicator(
        value:digitCountdownProgress,strokeWidth:9,
        backgroundColor:const Color(0xFFECE3FA),color:tone,
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
      Text('${s.score.toStringAsFixed(0)}/100 agreement'),label(s.detail),label('RSI ${s.rsi.toStringAsFixed(1)} • Proxy ${s.adx.toStringAsFixed(1)}'),
      label('Candle: ${DateTime.fromMillisecondsSinceEpoch(s.epoch*1000)}'),
    ]))),
  ]);
  Widget settings() => Column(children:[
    panel('Demo execution • manual / automatic',Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      SwitchListTile(title:const Text('Automatic DEMO trading'),subtitle:const Text('Off by default • only fresh qualifying signals'),
        value:autoTrade,onChanged:(v) {
          if(v && !api.online) {note('Connect demo before enabling auto');return;}
          if(v && !canTrade) {note('Risk limit or unresolved trade prevents auto');return;}
          setState(()=>autoTrade=v);
        }),
      Text('Demo stake: \$${demoStake.toStringAsFixed(2)}'),
      Slider(value:demoStake,min:0.35,max:2,divisions:33,onChanged:(v)=>setState(()=>demoStake=v)),
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
      Text('Minimum indicator agreement: $threshold/100'),Slider(min:60,max:95,divisions:7,value:threshold.toDouble(),onChanged:(v)=>setState(()=>threshold=v.round())),
      OutlinedButton(onPressed:()=>setState(() {history.clear();known.clear();best=null;}),child:const Text('Clear signal history')),
    ])),
    panel('Limitations',const Text('Demo only. Automatic trading works while scanner is running in foreground. A disconnected or closed app cannot guarantee settlement monitoring. Review Deriv portfolio after interruptions. Trading has risk even with virtual funds.')),
  ]);
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar:AppBar(backgroundColor:const Color(0xFFE8DCFA),title:const Text('V8 PRO • Expert Trader'),actions:[Padding(padding:const EdgeInsets.only(right:16),child:Center(child:Text(api.online?'● DEMO':'○ OFFLINE',style:TextStyle(fontWeight:FontWeight.bold,color:api.online?Colors.green:Colors.grey))))]),
    body:Column(children:[
      Container(width:double.infinity,color:const Color(0xFFEDE4FC),padding:const EdgeInsets.symmetric(horizontal:16,vertical:10),child:Text(status,maxLines:2,overflow:TextOverflow.ellipsis)),
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
