import 'dart:async';
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
    title: 'V8 PRO • Market Lab',
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
  int page=0, interval=60, threshold=75, scans=0, generation=0;
  bool connecting=false, scanning=false, refreshing=false;
  String account='', status='Disconnected', selected='R_25';
  DateTime? updated;
  DigitSample? sample;
  Setup? best;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    api.onLost = (reason) { stop(); if (mounted) setState(() { account=''; status=reason; }); };
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && scanning) stop('Paused in background');
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    generation++;
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
  Future<void> loadPrecision() async {
    try {
      final response = await api.request({'active_symbols':'brief','product_type':'basic'});
      final list = response['active_symbols'];
      if (list is! List) return;
      for (final row in list) {
        if (row is! Map) continue;
        final symbol='${row['symbol']}';
        final pip=double.tryParse('${row['pip']}');
        if (pip == null || pip <= 0) continue;
        final raw = pip.toString();
        final places = raw.contains('.') ? raw.split('.').last.length : 0;
        if (places>=0 && places<=10) precision[symbol]=places;
      }
    } catch (_) { /* The API may not expose active_symbols on this endpoint. */ }
  }
  Future<void> disconnect() async {
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
  Future<void> ticks() async {
    if (!api.online || refreshing) { note('Connect demo first'); return; }
    setState(() { refreshing=true; sample=null; status='Loading live tick history…'; });
    try {
      final response=await api.request({'ticks_history':selected,'end':'latest','style':'ticks','count':1000});
      final data=response['history'];
      if (data is! Map || data['prices'] is! List) throw StateError('Tick prices missing');
      final raw=data['prices'] as List;
      // Prefer API pip_size; otherwise use active_symbols pip metadata.
      var places=int.tryParse('${response['pip_size'] ?? data['pip_size'] ?? ''}');
      places ??= precision[selected];
      if (places==null || places<0 || places>10) {
        throw StateError('Quote precision unavailable. Cannot calculate trustworthy last digits.');
      }
      final counts=List<int>.filled(10,0);
      var total=0, last=0;
      for (final price in raw) {
        final n=double.tryParse('$price');
        if (n==null || !n.isFinite) continue;
        final formatted=n.toStringAsFixed(places);
        final digit=int.tryParse(formatted.substring(formatted.length-1));
        if (digit==null) continue;
        counts[digit]++; last=digit; total++;
      }
      if (total==0) throw StateError('No valid ticks returned');
      if (mounted) setState(() { sample=DigitSample(counts,last,places!,total); status='Loaded $total $selected ticks'; });
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
    panel('Connection',Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      TextField(controller:appId,decoration:const InputDecoration(labelText:'Deriv App ID')),
      TextField(controller:token,obscureText:true,autocorrect:false,enableSuggestions:false,decoration:const InputDecoration(labelText:'Demo PAT • never saved')),
      const SizedBox(height:12),Wrap(spacing:8,children:[
        FilledButton(onPressed:api.online||connecting?null:connect,child:Text(connecting?'Connecting…':'Connect demo')),
        OutlinedButton(onPressed:api.online?disconnect:null,child:const Text('Disconnect')),
      ]),if (account.isNotEmpty) label('Demo account: $account'),
    ])),
    panel('Market scanner',Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      label('Five markets • closed 1-minute candles • no orders placed'),
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
    panel('Live market radar',Column(children:markets.map((m)=>ListTile(dense:true,contentPadding:EdgeInsets.zero,title:Text(m,style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text(statuses[m]??'Not scanned'))).toList())),
    panel('Digit analysis',Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      DropdownButton<String>(isExpanded:true,value:selected,items:markets.map((m)=>DropdownMenuItem(value:m,child:Text(m))).toList(),onChanged:(m){if(m!=null)setState(() {selected=m;sample=null;});}),
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
  Widget signalHistory() => history.isEmpty?panel('Signal history',const Text('No qualified signals yet. Start the scanner on the Dashboard.')):Column(children:[
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
    panel('Scanner settings',Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('Interval: $interval seconds'),Slider(min:30,max:180,divisions:5,value:interval.toDouble(),onChanged:(v)=>setState(()=>interval=v.round())),
      Text('Minimum indicator agreement: $threshold/100'),Slider(min:60,max:95,divisions:7,value:threshold.toDouble(),onChanged:(v)=>setState(()=>threshold=v.round())),
      OutlinedButton(onPressed:()=>setState(() {history.clear();known.clear();best=null;}),child:const Text('Clear session history')),
    ])),
    panel('Known limitations',const Text('No automatic trading. No proven predictive AI. No background scanner. No stored token. Paper outcomes are estimates based on subsequent candle closes, not actual contract settlements. Session history is cleared on restart.')),
  ]);
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar:AppBar(backgroundColor:const Color(0xFFE8DCFA),title:const Text('V8 PRO • Market Lab'),actions:[Padding(padding:const EdgeInsets.only(right:16),child:Center(child:Text(api.online?'● DEMO':'○ OFFLINE',style:TextStyle(fontWeight:FontWeight.bold,color:api.online?Colors.green:Colors.grey))))]),
    body:Column(children:[
      Container(width:double.infinity,color:const Color(0xFFEDE4FC),padding:const EdgeInsets.symmetric(horizontal:16,vertical:10),child:Text(status,maxLines:2,overflow:TextOverflow.ellipsis)),
      Expanded(child:ListView(padding:const EdgeInsets.all(14),children:[if(page==0)dashboard() else if(page==1)signalHistory() else settings()])),
    ]),
    bottomNavigationBar:NavigationBar(selectedIndex:page,onDestinationSelected:(i)=>setState(()=>page=i),destinations:const [
      NavigationDestination(icon:Icon(Icons.dashboard_outlined),label:'Dashboard'),
      NavigationDestination(icon:Icon(Icons.history),label:'History'),
      NavigationDestination(icon:Icon(Icons.settings_outlined),label:'Settings'),
    ]),
  );
}
