import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

void main() => runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: TradingScreen()));

class DerivClient {
  WebSocketChannel? channel;
  StreamSubscription? subscription;
  Timer? heartbeat;
  final pending = <int, Completer<Map<String,dynamic>>>{};
  int nextId = 0;
  bool connected = false;
  void Function(String)? onDisconnect;
  Future<String> connectDemo(String appId, String pat) async {
    await close();
    final headers = {'Authorization':'Bearer $pat','Deriv-App-ID':appId};
    final response = await http.get(Uri.parse('https://api.derivws.com/trading/v1/options/accounts'),headers:headers).timeout(const Duration(seconds:20));
    if(response.statusCode!=200) throw StateError('Accounts HTTP ${response.statusCode}');
    final root=jsonDecode(response.body) as Map<String,dynamic>;
    final data=root['data'];
    final List<dynamic> accounts = data is List ? data : (data is Map && data['accounts'] is List ? data['accounts'] as List : <dynamic>[]);
    Map<String,dynamic>? demo;
    for(final item in accounts){if(item is Map && item['account_type']?.toString().toLowerCase()=='demo'){demo=Map<String,dynamic>.from(item);break;}}
    if(demo==null) throw StateError('No demo Options account found');
    final accountId=(demo['account_id']??demo['id'])?.toString();
    if(accountId==null||accountId.isEmpty) throw StateError('Demo account ID missing');
    final otp=await http.post(Uri.parse('https://api.derivws.com/trading/v1/options/accounts/${Uri.encodeComponent(accountId)}/otp'),headers:headers).timeout(const Duration(seconds:20));
    if(otp.statusCode!=200) throw StateError('OTP HTTP ${otp.statusCode}');
    final otpData=(jsonDecode(otp.body) as Map<String,dynamic>)['data'];
    final url=otpData is Map?otpData['url']?.toString():null;
    if(url==null) throw StateError('OTP URL missing');
    final uri=Uri.parse(url);
    if(uri.scheme!='wss'||uri.host!='api.derivws.com'||uri.path!='/trading/v1/options/ws/demo') throw StateError('Unexpected non-demo WebSocket URL');
    try {
      channel=WebSocketChannel.connect(uri);
      await channel!.ready.timeout(const Duration(seconds:15));
      connected=true;
      subscription=channel!.stream.listen((event){
        try{
          final msg=jsonDecode(event as String) as Map<String,dynamic>;
          final id=int.tryParse('${msg['req_id']}');
          final waiter=id==null?null:pending.remove(id);
          if(waiter!=null&&!waiter.isCompleted){
            if(msg['error']!=null) waiter.completeError(StateError('${msg['error']}'));
            else waiter.complete(msg);
          }
        }catch(_){ }
      },onError:(Object e)=>_lost('Connection error'),onDone:()=>_lost('Connection closed'));
      heartbeat=Timer.periodic(const Duration(seconds:30),(_){if(connected){call({'ping':1}).catchError((Object e){_lost('Heartbeat failed');return <String,dynamic>{};});}});
      return accountId;
    }catch(_){await close();rethrow;}
  }
  void _lost(String reason){if(!connected)return;connected=false;heartbeat?.cancel();_fail(StateError(reason));onDisconnect?.call(reason);}
  void _fail(Object e){for(final p in pending.values){if(!p.isCompleted)p.completeError(e);}pending.clear();}
  Future<Map<String,dynamic>> call(Map<String,dynamic> payload) async {
    if(!connected||channel==null)throw StateError('Not connected');
    final id=++nextId;
    final waiter=Completer<Map<String,dynamic>>();pending[id]=waiter;
    try{channel!.sink.add(jsonEncode({...payload,'req_id':id}));return await waiter.future.timeout(const Duration(seconds:20));}
    finally{pending.remove(id);}
  }
  Future<void> close()async{connected=false;heartbeat?.cancel();heartbeat=null;_fail(StateError('Disconnected'));await subscription?.cancel();subscription=null;await channel?.sink.close();channel=null;}
}

class TickSample {
  final int epoch, digit;
  final double quote;
  TickSample(this.epoch,this.digit,this.quote);
}
class Prediction {
  final String market, mode;
  final int digit, started, target;
  final double estimate;
  int? actual;
  bool? won;
  Prediction(this.market,this.mode,this.digit,this.started,this.target,this.estimate);
}

class TradingScreen extends StatefulWidget{const TradingScreen({super.key});@override State<TradingScreen> createState()=>_TradingScreenState();}
class _TradingScreenState extends State<TradingScreen> with WidgetsBindingObserver {
  static const markets=['R_10','R_25','R_50','R_75','R_100'];
  static const purple=Color(0xFF7135D5),blue=Color(0xFF1859E9);
  final storage=const FlutterSecureStorage();
  final appId=TextEditingController(),pat=TextEditingController();
  final client=DerivClient();
  final records=<Prediction>[];
  List<TickSample> ticks=[];
  String market='R_50',mode='Matches',status='Disconnected',account='';
  int tab=2,remaining=0,precision=2;
  bool connecting=false,loading=false;
  Prediction? active;
  Timer? countdown;
  int generation=0;
  @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);_restore();client.onDisconnect=(s){countdown?.cancel();if(mounted)setState((){status='Disconnected: $s';remaining=0;active=null;});};}
  Future<void> _restore()async{final saved=await storage.read(key:'appId')??'';if(mounted)setState(()=>appId.text=saved);}
  @override void didChangeAppLifecycleState(AppLifecycleState s){if(s!=AppLifecycleState.resumed){countdown?.cancel();if(mounted)setState((){active=null;remaining=0;status='Paused: app backgrounded';});}}
  Future<void> connect()async{
    if(connecting)return;
    if(appId.text.trim().isEmpty||pat.text.trim().isEmpty){setState(()=>status='Enter App ID and PAT in Settings');return;}
    setState((){connecting=true;status='Connecting to DEMO…';});
    try{await storage.write(key:'appId',value:appId.text.trim());final a=await client.connectDemo(appId.text.trim(),pat.text.trim());if(!mounted)return;setState((){account=a;status='Demo connected';});await refresh();}
    catch(e){if(mounted)setState(()=>status='Connection failed: $e');}
    finally{if(mounted)setState(()=>connecting=false);}
  }
  Future<void> disconnect()async{generation++;countdown?.cancel();await client.close();if(mounted)setState((){account='';active=null;remaining=0;status='Disconnected';});}
  // Digit extraction requires the market's exact pip precision; never use a rounded double string.
  int digitOf(dynamic raw,int places){final s=raw.toString();final v=double.tryParse(s);if(v==null)throw const FormatException('Invalid quote');final fixed=v.toStringAsFixed(places);return int.parse(fixed.substring(fixed.length-1));}
  Future<List<TickSample>> history({int count=1000,int? start})async{
    final request=<String,dynamic>{'ticks_history':market,'style':'ticks','end':'latest','count':count};
    if(start!=null){request.remove('count');request['start']=start;}
    final result=await client.call(request);
    final h=result['history'];if(h is! Map||h['prices'] is! List||h['times'] is! List)throw StateError('Missing tick history');
    final prices=h['prices'] as List,times=h['times'] as List;
    final n=min(prices.length,times.length);
    final samples=<TickSample>[];
    for(var i=0;i<n;i++){
      final e=int.tryParse('${times[i]}'),q=double.tryParse('${prices[i]}');
      if(e!=null&&q!=null)samples.add(TickSample(e,digitOf(prices[i],precision),q));
    }
    samples.sort((a,b)=>a.epoch.compareTo(b.epoch));return samples;
  }
  Future<void> refresh()async{
    if(!client.connected||loading)return;
    setState((){loading=true;status='Refreshing $market live history…';});
    try{
      // active_symbols supplies the authoritative display precision for each symbol.
      final response=await client.call({'active_symbols':'brief','product_type':'basic'});
      final symbols=response['active_symbols'];
      if(symbols is List){for(final s in symbols){if(s is Map&&s['symbol']==market){final pip=double.tryParse('${s['pip']}');if(pip!=null&&pip>0){final decimals=pip.toString().split('.').last;precision=decimals=='0'?0:decimals.length;}break;}}}
      final result=await history();if(result.length<100)throw StateError('Insufficient ticks');
      if(mounted)setState((){ticks=result;status='Loaded ${result.length} $market ticks • demo connected';});
    }catch(e){if(mounted)setState(()=>status='Refresh failed: $e');}
    finally{if(mounted)setState(()=>loading=false);}
  }
  int chooseDigit(List<TickSample> sample,String selected){
    final frequency=List<int>.filled(10,0);
    for(final t in sample.skip(max(0,sample.length-200)))frequency[t.digit]++;
    if(selected=='Even'||selected=='Odd'){
      final allowed=selected=='Even'?[0,2,4,6,8]:[1,3,5,7,9];allowed.sort((a,b)=>frequency[b].compareTo(frequency[a]));return allowed.first;
    }
    if(selected=='Over')return 5;
    if(selected=='Under')return 4;
    if(selected=='Differs'){final ds=List<int>.generate(10,(i)=>i);ds.sort((a,b)=>frequency[a].compareTo(frequency[b]));return ds.first;}
    final ds=List<int>.generate(10,(i)=>i);ds.sort((a,b)=>frequency[b].compareTo(frequency[a]));return ds.first;
  }
  bool resultFor(String selected,int prediction,int actual){switch(selected){case 'Even':return actual.isEven;case 'Odd':return actual.isOdd;case 'Over':return actual>prediction;case 'Under':return actual<prediction;case 'Differs':return actual!=prediction;default:return actual==prediction;}}
  double baseline(String selected,int digit){switch(selected){case 'Even':case 'Odd':return .5;case 'Over':return (9-digit)/10;case 'Under':return digit/10;case 'Differs':return .9;default:return .1;}}
  Future<void> predict(String selected)async{
    if(!client.connected){setState(()=>status='Connect DEMO in Settings first');return;}
    if(active!=null||loading)return;
    mode=selected;
    await refresh();if(!mounted||ticks.length<100||!client.connected)return;
    final latest=ticks.last;
    final digit=chooseDigit(ticks,selected);
    final p=Prediction(market,selected,digit,latest.epoch,latest.epoch+10,baseline(selected,digit));
    final id=++generation;
    setState((){active=p;remaining=10;status='Prediction active • waiting for tick at/after +10s';});
    countdown?.cancel();
    countdown=Timer.periodic(const Duration(seconds:1),(timer){if(!mounted||id!=generation){timer.cancel();return;}setState(()=>remaining=max(0,remaining-1));if(remaining==0){timer.cancel();settle(p,id);}});
  }
  Future<void> settle(Prediction p,int id)async{
    if(!client.connected)return;
    try{
      // Check first actual tick at/after the fixed target epoch, not an arbitrary latest tick.
      TickSample? actual;
      for(var attempt=0;attempt<5&&actual==null;attempt++){
        final result=await history(start:p.started);
        for(final t in result){if(t.epoch>=p.target){actual=t;break;}}
        if(actual==null)await Future.delayed(const Duration(seconds:2));
      }
      if(id!=generation||!mounted)return;
      if(actual==null)throw StateError('No expiry tick received');
      p.actual=actual.digit;p.won=resultFor(p.mode,p.digit,actual.digit);
      setState((){records.insert(0,p);active=null;status='Result: ${p.won!?'CORRECT':'INCORRECT'} • actual digit ${p.actual}';});
    }catch(e){if(id==generation&&mounted)setState((){active=null;status='Settlement failed (not counted): $e';});}
  }
  @override void dispose(){generation++;countdown?.cancel();WidgetsBinding.instance.removeObserver(this);client.close();appId.dispose();pat.dispose();super.dispose();}
  Widget tile(String name,Color color){final selected=mode==name;return GestureDetector(onTap:()=>predict(name),child:Container(height:78,alignment:Alignment.center,decoration:BoxDecoration(color:color,borderRadius:BorderRadius.circular(18),border:selected?Border.all(color:Colors.black,width:3):null),child:Text(name,style:const TextStyle(color:Colors.white,fontSize:20,fontWeight:FontWeight.bold))));}
  Widget panel(Widget child)=>Container(width:double.infinity,padding:const EdgeInsets.all(22),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(30),boxShadow:[BoxShadow(color:Colors.black.withValues(alpha:.12),blurRadius:5,offset:const Offset(0,2))]),child:child);
  Widget analyzer(){final p=active;final last=records.isEmpty?null:records.first;final up=ticks.length>20&&ticks.last.quote>ticks[ticks.length-20].quote;final sample=ticks.length>70?ticks.sublist(ticks.length-70):ticks;final wins=records.where((r)=>r.won==true).length;
    return ListView(padding:const EdgeInsets.all(24),children:[
      Text('Loaded ${ticks.length} $market ticks • ${client.connected?'live refresh available':'connect demo'}',style:const TextStyle(fontSize:15)),const SizedBox(height:18),
      panel(Column(children:[Row(children:[Expanded(child:tile('Even',blue)),const SizedBox(width:14),Expanded(child:tile('Odd',purple))]),const SizedBox(height:14),Row(children:[Expanded(child:tile('Over',const Color(0xFF078D51))),const SizedBox(width:14),Expanded(child:tile('Under',const Color(0xFFE31E23)))]),const SizedBox(height:14),Row(children:[Expanded(child:tile('Matches',blue)),const SizedBox(width:14),Expanded(child:tile('Differs',purple))])])),
      const SizedBox(height:22),panel(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        const Text('Expert Analysis Tool',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),const SizedBox(height:24),const Text('QUICK STRATEGY • LIVE MARKET ANALYSIS',style:TextStyle(color:purple,fontWeight:FontWeight.bold)),const SizedBox(height:14),Text('Market: $market  •  ${client.connected?'Demo connected':'Disconnected'}',style:const TextStyle(fontWeight:FontWeight.w600)),const SizedBox(height:16),
        Row(children:[Expanded(child:tile('Matches',blue)),const SizedBox(width:12),Container(width:110,height:110,alignment:Alignment.center,decoration:BoxDecoration(shape:BoxShape.circle,color:purple,border:Border.all(color:const Color(0xFFE7D8FF),width:7)),child:Text('${p?.digit??last?.digit??'–'}',style:const TextStyle(color:Colors.white,fontSize:46,fontWeight:FontWeight.bold))),const SizedBox(width:12),Expanded(child:tile('Differs',blue))]),
        const SizedBox(height:12),Center(child:Text(p!=null?'Countdown: $remaining seconds':last==null?'Tap a contract to analyze':'Result: ${last.won==true?'CORRECT':'INCORRECT'} • digit ${last.actual}',textAlign:TextAlign.center)),const Divider(height:34),
        const Text('CURRENT TREND',style:TextStyle(color:Colors.black54,fontWeight:FontWeight.bold)),const SizedBox(height:10),Text('${up?'Uptrend ↗':'Downtrend ↘'}',style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold)),const SizedBox(height:12),SizedBox(height:105,width:double.infinity,child:CustomPaint(painter:TrendPainter(sample.map((e)=>e.quote).toList(),purple))),const Divider(height:34),
        const Text('CONFIDENCE • BASELINE ESTIMATE',style:TextStyle(color:Colors.black54,fontWeight:FontWeight.bold)),const SizedBox(height:12),Text('${((p?.estimate??baseline(mode,chooseDigit(ticks.isEmpty?[TickSample(0,0,0)]:ticks,mode)))*100).toStringAsFixed(0)}%',style:const TextStyle(color:purple,fontSize:30,fontWeight:FontWeight.bold)),const SizedBox(height:6),LinearProgressIndicator(value:p?.estimate??baseline(mode,0),color:purple,backgroundColor:const Color(0xFFEDE3F8),minHeight:9),const SizedBox(height:12),const Text('Baseline only, not a verified predictive probability. Digit outcomes are not reliably predicted by price-trend indicators.',style:TextStyle(color:Colors.black54,fontSize:12)),const SizedBox(height:12),Text('Actualization: ${records.length} settled • $wins correct • ${records.isEmpty?'–':(wins*100/records.length).toStringAsFixed(1)}% observed accuracy'),const SizedBox(height:8),Text(status,style:const TextStyle(fontSize:12,color:Colors.black54)),
      ])),const SizedBox(height:20),FilledButton(onPressed:client.connected&&!loading&&active==null?refresh:null,child:Text(loading?'Refreshing…':'Refresh live market')),
    ]);
  }
  Widget settings()=>ListView(padding:const EdgeInsets.all(24),children:[const Text('Deriv DEMO Connection',style:TextStyle(fontSize:23,fontWeight:FontWeight.bold)),const SizedBox(height:16),TextField(controller:appId,decoration:const InputDecoration(labelText:'Deriv App ID',border:OutlineInputBorder())),const SizedBox(height:14),TextField(controller:pat,obscureText:true,autocorrect:false,enableSuggestions:false,decoration:const InputDecoration(labelText:'Deriv PAT (not saved)',border:OutlineInputBorder())),const SizedBox(height:14),FilledButton(onPressed:connecting?null:connect,child:Text(connecting?'Connecting…':'Connect DEMO')),OutlinedButton(onPressed:client.connected?disconnect:null,child:const Text('Disconnect')),Text('Account: $account'),Text(status)]);
  Widget historyTab()=>ListView(padding:const EdgeInsets.all(18),children:[Text('Prediction history • ${records.length} settled',style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold)),for(final p in records)Card(child:ListTile(title:Text('${p.market} • ${p.mode} • ${p.digit}'),subtitle:Text('Actual: ${p.actual} • target epoch ${p.target}'),trailing:Text(p.won==true?'CORRECT':'INCORRECT',style:TextStyle(color:p.won==true?Colors.green:Colors.red))))]);
  Widget dashboard()=>ListView(padding:const EdgeInsets.all(24),children:[const Text('Select volatility market',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold)),const SizedBox(height:14),for(final s in markets)Card(child:ListTile(title:Text(s),subtitle:Text(s==market?'Selected':'Tap to select'),trailing:s==market?const Icon(Icons.check_circle,color:purple):null,onTap:(){if(active!=null)return;setState((){market=s;ticks=[];status='Market changed; refresh required';});refresh();})),const SizedBox(height:14),Text(status)]);
  @override Widget build(BuildContext context)=>Scaffold(backgroundColor:const Color(0xFFF3EDFC),appBar:AppBar(toolbarHeight:84,backgroundColor:const Color(0xFFE0D2F1),title:const Text('V8 PRO • Expert Trader',style:TextStyle(fontSize:23)),actions:[Padding(padding:const EdgeInsets.only(right:18),child:Center(child:Text(client.connected?'● DEMO':'○ DEMO',style:TextStyle(color:client.connected?Colors.green:Colors.grey,fontWeight:FontWeight.bold))))]),body:IndexedStack(index:tab,children:[dashboard(),historyTab(),analyzer(),settings()]),bottomNavigationBar:NavigationBar(selectedIndex:tab,onDestinationSelected:(i)=>setState(()=>tab=i),destinations:const [NavigationDestination(icon:Icon(Icons.dashboard_outlined),label:'Dashboard'),NavigationDestination(icon:Icon(Icons.history),label:'History'),NavigationDestination(icon:Icon(Icons.pin_outlined),label:'Analyzer'),NavigationDestination(icon:Icon(Icons.settings_outlined),label:'Settings')]));
}
class TrendPainter extends CustomPainter{
  final List<double> values;final Color color;TrendPainter(this.values,this.color);
  @override void paint(Canvas canvas,Size size){if(values.length<2)return;final lo=values.reduce(min),hi=values.reduce(max),span=max(hi-lo,1e-10);final path=Path();for(var i=0;i<values.length;i++){final x=size.width*i/(values.length-1),y=size.height-8-(values[i]-lo)/span*(size.height-16);if(i==0)path.moveTo(x,y);else path.lineTo(x,y);}canvas.drawPath(path,Paint()..color=color..strokeWidth=2.5..style=PaintingStyle.stroke);}
  @override bool shouldRepaint(covariant TrendPainter old)=>true;
}
