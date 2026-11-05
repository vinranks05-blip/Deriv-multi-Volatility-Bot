import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'deriv_v13_market_data.dart';

void main() => runApp(const V13App());
const bg = Color(0xff030d26), panel = Color(0xff10234b);
const cyan = Color(0xff00d8ff), blue = Color(0xff1385ff);
const green = Color(0xff00e5a0), red = Color(0xffff5275);

class V13App extends StatelessWidget {
  const V13App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.fromSeed(seedColor: cyan, brightness: Brightness.dark)),
    home: const Dashboard());
}

class Forecast {
  final int digit, sourceEpoch, strategy, sourceCount;
  final DateTime issued;
  final double estimate;
  final String method;
  const Forecast(this.digit, this.sourceEpoch, this.sourceCount, this.strategy, this.issued, this.estimate, this.method);
}
class Result {
  final String symbol, mode;
  final int predicted, actual, epoch;
  final bool correct;
  Result(this.symbol, this.mode, this.predicted, this.actual, this.epoch, this.correct);
  Map<String, dynamic> toJson() => {'symbol':symbol,'mode':mode,'predicted':predicted,'actual':actual,'epoch':epoch,'correct':correct};
  factory Result.fromJson(Map<String,dynamic> j) => Result('${j['symbol']}', '${j['mode']}', (j['predicted'] as num).toInt(), (j['actual'] as num).toInt(), (j['epoch'] as num).toInt(), j['correct'] == true);
}
class Market {
  final String symbol, name;
  final int precision;
  Market(this.symbol,this.name,this.precision);
  List<V13Tick> ticks = [];
  Forecast? forecast;
  DateTime? lastSeen;
  String trend = 'COLLECTING', method = 'COLLECTING';
  double? rsi, macd, movement;
  double holdout = 0, baseline = 0;
  int testCount = 0;
  double mlHoldout = 0, mlBaseline = 0;
  int mlTestCount = 0;
  List<double> mlScores = List<double>.filled(10, 0.1);
  bool mlSelected = false;
  int lastEvaluationCount = 0;
  bool get live => lastSeen != null && DateTime.now().difference(lastSeen!).inSeconds < 15;
  int? get lastDigit => ticks.isEmpty ? null : ticks.last.lastDigit;
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override State<Dashboard> createState() => _DashboardState();
}
class _DashboardState extends State<Dashboard> {
  final data = V13MarketData();
  final markets = [
    Market('R_10','Volatility 10',3), Market('R_25','Volatility 25',3),
    Market('R_50','Volatility 50',4), Market('R_75','Volatility 75',4),
    Market('R_100','Volatility 100',2), Market('1HZ10V','Volatility 10 (1s)',2),
    Market('1HZ25V','Volatility 25 (1s)',2), Market('1HZ50V','Volatility 50 (1s)',2),
    Market('1HZ75V','Volatility 75 (1s)',2), Market('1HZ100V','Volatility 100 (1s)',2),
  ];
  final results = <Result>[];
  final logs = <String>[];
  final alerts = <String>[];
  final journal = TextEditingController();
  final subscriptions = <StreamSubscription>[];
  Timer? clock;
  int tab = 0, strategy = 0, scanRemaining = 10, tickCount = 0;
  String selected = 'R_25';
  bool autoScan = true, notifications = true;
  String connection = 'CONNECTING';
  static const modes = ['Matches','Even/Odd','Over/Under'];
  Market market(String symbol) => markets.firstWhere((m) => m.symbol == symbol);

  @override void initState() {
    super.initState();
    _load();
    subscriptions.add(data.ticks.listen(_onTick));
    subscriptions.add(data.historyUpdates.listen(_onHistory));
    subscriptions.add(data.errors.listen((e) {
      if (!mounted) return;
      _log(e);
      setState(() => connection = data.connected ? 'PUBLIC LIVE' : 'RECONNECTING');
    }));
    subscriptions.add(data.symbols.listen((s) { _log('Available volatility symbols: ${s.length}'); }));
    for (final m in markets) { data.watch(m.symbol); }
    data.connect();
    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        connection = data.connected ? (tickCount > 0 ? 'PUBLIC LIVE' : 'SUBSCRIBING') : 'RECONNECTING';
        scanRemaining = scanRemaining <= 1 ? 10 : scanRemaining - 1;
      });
      if (autoScan && scanRemaining == 10) _scan();
    });
  }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      autoScan = p.getBool('v13_autoScan') ?? true;
      notifications = p.getBool('v13_alerts') ?? true;
      journal.text = p.getString('v13_journal') ?? '';
      for (final raw in p.getStringList('v13_results') ?? []) {
        try { results.add(Result.fromJson(Map<String,dynamic>.from(_decode(raw)))); } catch (_) {}
      }
    });
  }
  dynamic _decode(String raw) => jsonDecode(raw);
  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('v13_autoScan',autoScan);
    await p.setBool('v13_alerts',notifications);
    await p.setString('v13_journal',journal.text);
    await p.setStringList('v13_results',results.take(300).map((r)=>jsonEncode(r.toJson())).toList());
  }
  void _log(String msg) {
    logs.insert(0, '${DateTime.now().toIso8601String().substring(11,19)}  $msg');
    if (logs.length > 150) logs.removeLast();
  }
  void _onHistory(String symbol) {
    if (!mounted) return;
    final m = market(symbol);
    m.ticks = List.of(data.history[symbol] ?? []);
    _indicators(m);
    _log('History ${m.symbol}: ${m.ticks.length} ticks');
    setState(() {});
  }
  void _onTick(V13Tick tick) {
    if (!mounted) return;
    final m = market(tick.symbol);
    m.ticks = List.of(data.history[tick.symbol] ?? []);
    m.lastSeen = DateTime.now();
    tickCount++;
    if (tickCount % 5 == 0) _indicators(m);
    _settle(m, tick);
    setState(() => connection = 'PUBLIC LIVE');
  }
  void _indicators(Market m) {
    if (m.ticks.length < 50) return;
    final xs = m.ticks.skip(max(0,m.ticks.length-300)).map((t)=>t.price).toList();
    double ema(int period) {
      var v = xs.first;
      final k = 2/(period+1);
      for (final x in xs.skip(1)) { v += k*(x-v); }
      return v;
    }
    final a = ema(20), b = ema(50);
    m.trend = a > b ? 'UP' : a < b ? 'DOWN' : 'SIDEWAYS';
    var gain=0.0, loss=0.0, move=0.0;
    for (var i=xs.length-14; i<xs.length; i++) {
      final d=xs[i]-xs[i-1];
      if(d>0) gain+=d; else loss-=d;
      move+=d.abs();
    }
    m.rsi = loss==0 ? (gain==0 ? 50.0 : 100.0) : 100-100/(1+gain/loss);
    m.macd = ema(12)-ema(26);
    m.movement=move/14;
  }
  List<double> _scores(List<V13Tick> xs, int method) {
    final counts=List<double>.filled(10,1);
    final recent=List<double>.filled(10,1);
    final transitions=List<double>.filled(10,1);
    final previous=xs.last.lastDigit;
    for(var i=0;i<xs.length;i++) {
      final d=xs[i].lastDigit;
      counts[d]++;
      if(i>=xs.length-50) recent[d]++;
      if(i>0 && xs[i-1].lastDigit==previous) transitions[d]++;
    }
    List<double> norm(List<double> a) { final total=a.reduce((x,y)=>x+y); return a.map((v)=>v/total).toList(); }
    final global=norm(counts), local=norm(recent), conditional=norm(transitions);
    if(method==0) return global;
    if(method==1) return local;
    final n=transitions.reduce((x,y)=>x+y)-10;
    final w=n/(n+50);
    return List.generate(10,(i)=>w*conditional[i]+(1-w)*global[i]);
  }
  int _best(List<double> p) {
    var best=0;
    for(var i=1;i<10;i++) { if(p[i]>p[best]) best=i; }
    return best;
  }
  // V13.2: Train a small multiclass softmax model on older tick sequences.
  // The newest 30% is strictly held out; all features precede their label.
  List<double> _features(List<V13Tick> xs, int i) {
    final x = List<double>.filled(31, 0);
    x[0] = 1;
    x[1 + xs[i].lastDigit] = 1;
    x[11 + xs[i - 1].lastDigit] = 1;
    final start = max(0, i - 49);
    for (var j = start; j <= i; j++) {
      x[21 + xs[j].lastDigit] += 1 / (i - start + 1);
    }
    return x;
  }
  List<double> _mlProb(List<List<double>> w, List<double> x) {
    final z = List<double>.generate(10, (d) {
      var sum = 0.0;
      for (var k = 0; k < 31; k++) { sum += w[d][k] * x[k]; }
      return sum;
    });
    final top = z.reduce(max);
    final exps = z.map((v) => exp(v - top)).toList();
    final total = exps.reduce((a, b) => a + b);
    return exps.map((v) => v / total).toList();
  }
  void _trainML(Market m) {
    final xs = m.ticks.length > 1200
        ? m.ticks.sublist(m.ticks.length - 1200) : m.ticks;
    if (xs.length < 250) { m.mlTestCount = 0; m.mlSelected = false; return; }
    final cut = (xs.length * .7).floor();
    final w = List.generate(10, (_) => List<double>.filled(31, 0));
    // Train on older examples, stepping by two to limit mobile CPU usage.
    for (var pass = 0; pass < 5; pass++) {
      for (var i = 50; i < cut - 1; i += 2) {
        final x = _features(xs, i);
        final p = _mlProb(w, x);
        final actual = xs[i + 1].lastDigit;
        for (var d = 0; d < 10; d++) {
          final delta = .035 * ((d == actual ? 1.0 : 0.0) - p[d]);
          for (var k = 0; k < 31; k++) { w[d][k] += delta * x[k]; }
        }
      }
    }
    final counts = List<int>.filled(10, 0);
    for (var i = 0; i < cut; i++) { counts[xs[i].lastDigit]++; }
    var majority = 0;
    for (var d = 1; d < 10; d++) {
      if (counts[d] > counts[majority]) majority = d;
    }
    var right = 0, base = 0, n = 0;
    for (var i = cut; i < xs.length - 1; i++) {
      final actual = xs[i + 1].lastDigit;
      if (_best(_mlProb(w, _features(xs, i))) == actual) right++;
      if (actual == majority) base++;
      n++;
    }
    m.mlTestCount = n;
    m.mlHoldout = n == 0 ? 0 : 100 * right / n;
    m.mlBaseline = n == 0 ? 0 : 100 * base / n;
    m.mlScores = _mlProb(w, _features(xs, xs.length - 1));
  }
  // Chronological holdout; choose a model only from training history.
  // The holdout remains untouched by model selection.
  void _evaluate(Market m) {
    final xs=m.ticks;
    if(xs.length<250) { m.testCount=0; m.method='COLLECTING'; return; }
    final cut=(xs.length*.7).floor();
    final train=xs.sublist(0,cut);
    final wins=List<int>.filled(3,0);
    for(var i=100;i<train.length-1;i+=5) {
      final actual=train[i+1].lastDigit;
      final h=train.sublist(max(0,i-199),i+1);
      for(var k=0;k<3;k++) { if(_best(_scores(h,k))==actual) wins[k]++; }
    }
    var chosen=0;
    for(var k=1;k<3;k++) { if(wins[k]>wins[chosen]) chosen=k; }
    final trainingCounts=List<int>.filled(10,0);
    for(final t in train) { trainingCounts[t.lastDigit]++; }
    var baselineDigit=0;
    for(var d=1;d<10;d++) { if(trainingCounts[d]>trainingCounts[baselineDigit]) baselineDigit=d; }
    var right=0, baseline=0, tested=0;
    for(var i=cut;i<xs.length-1;i++) {
      final h=xs.sublist(max(0,i-199),i+1);
      final actual=xs[i+1].lastDigit;
      if(_best(_scores(h,chosen))==actual) right++;
      if(actual==baselineDigit) baseline++;
      tested++;
    }
    m.method=['Frequency','Recent 50','Transition blend'][chosen];
    m.testCount=tested;
    m.holdout=tested==0?0:100*right/tested;
    m.baseline=tested==0?0:100*baseline/tested;
    _trainML(m);
    // Select ML only if it beats the statistical model and the baseline
    // on chronological holdout. These are exploratory, not guaranteed odds.
    m.mlSelected = m.mlTestCount >= 50 &&
        m.mlHoldout > m.holdout + 2 && m.mlHoldout > m.mlBaseline + 2;
    if (m.mlSelected) m.method = 'ML softmax';
    m.lastEvaluationCount = xs.length;
  }
  void _predict(Market m) {
    if(!m.live || m.forecast!=null || m.ticks.length<250) return;
    if (m.lastEvaluationCount == 0 || m.ticks.length - m.lastEvaluationCount >= 100) _evaluate(m);
    final method=['Frequency','Recent 50','Transition blend'].indexOf(m.method);
    final p=m.mlSelected ? m.mlScores : _scores(m.ticks.skip(max(0,m.ticks.length-200)).toList(),max(0,method));
    final digit=_best(p);
    m.forecast=Forecast(digit,m.ticks.last.epoch,m.ticks.length,strategy,DateTime.now(),p[digit]*100,m.method);
  }
  void _scan() {
    for(final m in markets) { _predict(m); }
    if(mounted) setState((){});
  }
  void _settle(Market m,V13Tick tick) {
    final f=m.forecast;
    if(f==null || tick.epoch < f.sourceEpoch ||
        (tick.epoch == f.sourceEpoch && m.ticks.length <= f.sourceCount)) return;
    // A genuine NEXT-TICK forecast: score the first subsequent live tick.
    final actual=tick.lastDigit;
    final correct=switch(f.strategy) {
      0 => actual==f.digit,
      1 => actual.isEven==f.digit.isEven,
      _ => actual>f.digit,
    };
    results.insert(0,Result(m.symbol,modes[f.strategy],f.digit,actual,tick.epoch,correct));
    if(results.length>300) results.removeLast();
    if(notifications) {
      alerts.insert(0,'${m.name}: ${correct?'CORRECT':'INCORRECT'} ${f.digit} → $actual');
      if(alerts.length>80) alerts.removeLast();
    }
    m.forecast=null;
    _save();
  }
  List<Result> _filtered({String? symbol,String? mode}) => results.where((r)=>(symbol==null||r.symbol==symbol)&&(mode==null||r.mode==mode)).toList();
  String _rate(List<Result> xs) => xs.isEmpty?'—':'${(100*xs.where((r)=>r.correct).length/xs.length).toStringAsFixed(1)}%';
  Widget _card(Widget child) => Container(margin:const EdgeInsets.only(bottom:12),padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(16),border:Border.all(color:blue.withOpacity(.45))),child:child);
  Widget _pill(String value,{Color color=cyan}) => Container(padding:const EdgeInsets.symmetric(horizontal:10,vertical:6),decoration:BoxDecoration(color:color.withOpacity(.15),borderRadius:BorderRadius.circular(16)),child:Text(value,style:TextStyle(color:color,fontSize:11,fontWeight:FontWeight.bold)));
  Widget _metric(String value,String label) => Expanded(child:_card(Column(children:[Text(value,style:const TextStyle(fontSize:21,fontWeight:FontWeight.bold,color:cyan)),Text(label,style:const TextStyle(fontSize:10))])));
  Widget _marketCard(Market m) {
    final f=m.forecast;
    return _card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Row(children:[Expanded(child:Text(m.name,style:const TextStyle(fontSize:17,fontWeight:FontWeight.bold))),_pill(m.live?'● LIVE':'● WAIT',color:m.live?green:Colors.orange)]),
      Text(m.symbol,style:const TextStyle(color:Colors.white60)),const SizedBox(height:12),
      Row(children:[Container(width:70,height:70,alignment:Alignment.center,decoration:const BoxDecoration(shape:BoxShape.circle,gradient:LinearGradient(colors:[blue,cyan])),child:Text(f?.digit.toString()??'⌛',style:const TextStyle(fontSize:33,fontWeight:FontWeight.bold))),const SizedBox(width:16),
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(f==null?'NEXT DIGIT • WAITING':'NEXT DIGIT • ${f.digit}',style:const TextStyle(fontWeight:FontWeight.bold)),Text(f==null?'Awaiting scan':'Model score ${f.estimate.toStringAsFixed(1)}% (uncalibrated)',style:const TextStyle(fontSize:12,color:Colors.amber)),Text('Trend ${m.trend} • ${m.ticks.length} ticks',style:const TextStyle(fontSize:12))]))]),
      const SizedBox(height:8),Text('Holdout: ${m.testCount==0?'collecting':'${m.holdout.toStringAsFixed(1)}% (${m.testCount} tests)'} • ${m.method}',style:const TextStyle(fontSize:11,color:Colors.white70)),
    ]));
  }
  Widget _radar() {
    final sample=_filtered(mode:modes[strategy]);
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Row(children:[_pill(connection,color:data.connected?green:Colors.orange),const Spacer(),Text('${markets.where((m)=>m.live).length}/10 feeds')]),
      const SizedBox(height:15),const Text('Volatility Predictions',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),
      const Text('Experimental NEXT-TICK digit forecasts',style:TextStyle(fontSize:12,color:Colors.white70)),
      Wrap(spacing:6,children:List.generate(3,(i)=>ChoiceChip(label:Text(modes[i]),selected:strategy==i,onSelected:(_)=>setState(()=>strategy=i)))),
      const SizedBox(height:12),Row(children:[_metric(_rate(sample),'OBSERVED ACCURACY'),const SizedBox(width:8),_metric('${sample.length}','OBSERVATIONS')]),
      Row(children:[_metric('${markets.where((m)=>m.live).length}','LIVE FEEDS'),const SizedBox(width:8),_metric('${markets.where((m)=>m.forecast!=null).length}','PENDING')]),
      _card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Matches Success Monitor',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),const SizedBox(height:7),
        for(final n in [10,50,100,300]) Text('Last $n: ${_rate(sample.take(n).toList())} (${min(n,sample.length)} observations)'),
        const SizedBox(height:8),const Text('Model scores are not win probabilities. Random-digit Matches has an approximately 10% chance baseline.',style:TextStyle(fontSize:11,color:Colors.white60))])),
      Row(children:[const Text('All markets',style:TextStyle(fontSize:19,fontWeight:FontWeight.bold)),const Spacer(),const Text('AUTO'),Switch(value:autoScan,onChanged:(v){setState(()=>autoScan=v);_save();})]),
      ...markets.map(_marketCard)
    ]);
  }
  Widget _analyzer() {
    final m=market(selected);
    final counts=List<int>.generate(10,(d)=>m.ticks.where((t)=>t.lastDigit==d).length);
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('Expert Analyzer',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),
      _card(DropdownButton<String>(isExpanded:true,value:selected,items:markets.map((m)=>DropdownMenuItem(value:m.symbol,child:Text(m.name))).toList(),onChanged:(v){if(v!=null)setState(()=>selected=v);})),
      _card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Row(children:[Expanded(child:Text(m.name,style:const TextStyle(fontSize:19,fontWeight:FontWeight.bold))),_pill(m.live?'LIVE':'WAIT',color:m.live?green:Colors.orange)]),
        Text('Trend: ${m.trend}',style:const TextStyle(fontSize:21,color:cyan)),
        Text('Last digit: ${m.lastDigit??'—'} • ${m.ticks.length} ticks'),
        Text('Tick RSI: ${m.rsi?.toStringAsFixed(1)??'—'} • MACD: ${m.macd?.toStringAsFixed(5)??'—'}'),
        Text('Mean tick movement: ${m.movement?.toStringAsFixed(5)??'—'}'),
        const SizedBox(height:10),SizedBox(height:100,child:CustomPaint(painter:SparkPainter(m.ticks.map((t)=>t.price).toList()),child:const SizedBox.expand())),
        const Text('Tick chart; indicators are not closed-candle signals.',style:TextStyle(fontSize:11,color:Colors.white60))])),
      _card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Digit Distribution',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
        for(var d=0;d<10;d++) Padding(padding:const EdgeInsets.symmetric(vertical:4),child:Row(children:[SizedBox(width:24,child:Text('$d')),Expanded(child:LinearProgressIndicator(value:m.ticks.isEmpty?0:counts[d]/m.ticks.length,minHeight:8,color:cyan)),const SizedBox(width:10),Text(m.ticks.isEmpty?'—':'${(counts[d]*100/m.ticks.length).toStringAsFixed(1)}%')]))])),
      _card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Prediction / Validation',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
        Text('Next tick digit: ${m.forecast?.digit??'—'}'),Text('Model: ${m.method}'),Text('Estimate (uncalibrated): ${m.forecast==null?'—':'${m.forecast!.estimate.toStringAsFixed(1)}%'}'),
        Text('Holdout accuracy: ${m.testCount==0?'—':'${m.holdout.toStringAsFixed(1)}%'}'),
        Text('Training-majority baseline: ${m.testCount==0?'—':'${m.baseline.toStringAsFixed(1)}%'}'),
        Text('Unseen tests: ${m.testCount}'),Text('ML softmax holdout: ${m.mlTestCount==0?'—':'${m.mlHoldout.toStringAsFixed(1)}%'} • baseline ${m.mlBaseline.toStringAsFixed(1)}% • ${m.mlTestCount} tests'),Text('Forward Matches: ${_rate(_filtered(symbol:m.symbol,mode:'Matches'))}'),
        const Text('Holdout is historical; live forward accuracy is the stronger measure.',style:TextStyle(fontSize:11,color:Colors.white60))])),
      FilledButton(onPressed:(){_predict(m);setState((){});},child:const Text('PREDICT NEXT TICK'))
    ]);
  }
  Widget _trades() => Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Demo Orders',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),
    _card(const Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('PUBLIC DATA ONLY',style:TextStyle(color:Colors.amber,fontWeight:FontWeight.bold)),SizedBox(height:8),
      Text('Broker orders are locked. The public market-data socket cannot authenticate a demo account or place trades.'),SizedBox(height:8),
      Text('A separate PAT/OAuth → account ID → OTP → authenticated DEMO WebSocket flow is required before enabling purchase.'),SizedBox(height:8),
      Text('Planned risk limits: \$0.35 stake • 6 trades • 2 consecutive losses • session P/L −\$1 to +\$1 • daily loss \$2.'),SizedBox(height:8),
      Text('No real-money trading or automatic purchases.',style:TextStyle(color:Colors.white70))]))]);
  Widget _history() => Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Observation History',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),
    ...results.take(100).map((r)=>_card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${r.symbol} • ${r.mode} • ${r.correct?'CORRECT':'INCORRECT'}',style:TextStyle(color:r.correct?green:red,fontWeight:FontWeight.bold)),Text('${r.predicted} → ${r.actual} • ${r.epoch}')])))]);
  Widget _journal() => Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Trading Journal',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),
    Row(children:[_metric('${results.length}','OBSERVATIONS'),const SizedBox(width:8),_metric(_rate(results),'ACCURACY')]),
    _card(TextField(controller:journal,maxLines:5,decoration:const InputDecoration(labelText:'Your notes'))),
    FilledButton(onPressed:()async{await _save();if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Saved locally')));},child:const Text('SAVE NOTE'))]);
  Widget _alerts() => Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Alerts',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),
    _card(SwitchListTile(title:const Text('In-app observation alerts'),value:notifications,onChanged:(v){setState(()=>notifications=v);_save();})),...alerts.map((a)=>_card(Text(a)))]);
  Widget _settings() => Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Settings',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),
    _card(Column(children:[SwitchListTile(title:const Text('Automatic scanning'),value:autoScan,onChanged:(v){setState(()=>autoScan=v);_save();}),
      SwitchListTile(title:const Text('In-app alerts'),value:notifications,onChanged:(v){setState(()=>notifications=v);_save();}),
      const ListTile(title:Text('Connection'),subtitle:Text('Deriv public Options WebSocket • automatic reconnect')),
      const ListTile(title:Text('Trading mode'),subtitle:Text('Read-only scanner • demo orders disabled'))])),
    FilledButton(onPressed:() {data.connect();setState(()=>connection='CONNECTING');},child:const Text('RECONNECT MARKET FEED'))]);
  Widget _diagnostics() => Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Connection Diagnostics',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),
    _card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('Socket: $connection'),const Text('Account: PUBLIC DATA ONLY'),Text('Ticks received: $tickCount'),
      Text('Feeds live: ${markets.where((m)=>m.live).length}/10'),Text('Scan countdown: ${scanRemaining}s'),
      const Text('No PAT or account token is sent to the public endpoint.') ])),
    Row(children:[Expanded(child:OutlinedButton(onPressed:()=>data.connect(),child:const Text('RECONNECT'))),const SizedBox(width:8),Expanded(child:OutlinedButton(onPressed:()=>setState(()=>logs.clear()),child:const Text('CLEAR LOG')))]),
    ...logs.take(100).map((line)=>Padding(padding:const EdgeInsets.symmetric(vertical:3),child:SelectableText(line,style:const TextStyle(fontSize:11,fontFamily:'monospace'))))]);
  @override Widget build(BuildContext context) {
    final pages=[_radar,_analyzer,_trades,_history,_journal,_alerts,_settings,_diagnostics];
    const names=['Radar','Analyzer','Trades','History','Journal','Alerts','Settings','Logs'];
    const icons=[Icons.radar,Icons.bar_chart,Icons.swap_horiz,Icons.history,Icons.article_outlined,Icons.notifications_outlined,Icons.settings_outlined,Icons.terminal];
    return Scaffold(appBar:AppBar(backgroundColor:panel,title:const Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('V13.2 Expert Trader PRO',style:TextStyle(fontSize:19,fontWeight:FontWeight.bold)),Text('Deriv • Experimental market scanner',style:TextStyle(fontSize:11,color:Colors.white70))]),actions:[Padding(padding:const EdgeInsets.only(right:10),child:Center(child:_pill('PUBLIC DATA',color:green)))]),
      body:SafeArea(child:Column(children:[Expanded(child:ListView(padding:const EdgeInsets.all(14),children:[pages[tab]()])),
        Container(height:69,color:panel,child:ListView.builder(scrollDirection:Axis.horizontal,itemCount:names.length,itemBuilder:(context,i)=>InkWell(onTap:()=>setState(()=>tab=i),child:Container(width:max(66.0,MediaQuery.sizeOf(context).width/6.2),padding:const EdgeInsets.symmetric(vertical:7),decoration:BoxDecoration(color:tab==i?blue.withOpacity(.2):Colors.transparent,borderRadius:BorderRadius.circular(12)),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[Icon(icons[i],size:22,color:tab==i?cyan:Colors.white70),const SizedBox(height:3),Text(names[i],style:TextStyle(fontSize:10,color:tab==i?cyan:Colors.white70))])))))])));
  }
  @override void dispose() { clock?.cancel();for(final s in subscriptions){s.cancel();}data.dispose();journal.dispose();super.dispose(); }
}
class SparkPainter extends CustomPainter {
  final List<double> values;
  SparkPainter(this.values);
  @override void paint(Canvas canvas,Size size) {
    if(values.length<2)return;
    final a=values.length>80?values.sublist(values.length-80):values;
    final lo=a.reduce(min),hi=a.reduce(max),range=max(hi-lo,.00001);
    final path=Path();
    for(var i=0;i<a.length;i++) {
      final x=i*size.width/(a.length-1),y=size.height-(a[i]-lo)/range*size.height;
      if(i==0)path.moveTo(x,y);else path.lineTo(x,y);
    }
    canvas.drawPath(path,Paint()..color=cyan..style=PaintingStyle.stroke..strokeWidth=2);
  }
  @override bool shouldRepaint(covariant SparkPainter old)=>true;
}
