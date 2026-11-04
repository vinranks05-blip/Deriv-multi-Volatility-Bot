
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const V12App());

const bg = Color(0xff030d26);
const panel = Color(0xff10234b);
const cyan = Color(0xff00d8ff);
const blue = Color(0xff1385ff);
const green = Color(0xff00e5a0);
const red = Color(0xffff5275);

class V12App extends StatelessWidget {
  const V12App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: bg,
          colorScheme: ColorScheme.fromSeed(
            seedColor: cyan,
            brightness: Brightness.dark,
          ),
        ),
        home: const Dashboard(),
      );
}

class TickPoint {
  final double quote;
  final int epoch;
  final int digit;

  TickPoint(this.quote, this.epoch, this.digit);
}

class Market {
  final String symbol;
  final String name;
  final int precision;
  final List<TickPoint> ticks = [];

  bool live = false;
  int? prediction;
  int? predictedEpoch;
  DateTime? predictionDeadline;
  int predictionStrategy = 0;
  String trend = 'WAIT';
  double agreement = 0;
  double nextDigitEstimate = 0;
  String predictionMethod = 'WAITING';
  double? rsi;
  double? macd;
  double? atr;
  int? lastSettledEpoch;
  DateTime? lastSeen;

  Market(this.symbol, this.name, this.precision);

  int? get lastDigit => ticks.isEmpty ? null : ticks.last.digit;

  double get frequency {
    if (prediction == null || ticks.isEmpty) return 0;
    return ticks.where((e) => e.digit == prediction).length /
        ticks.length *
        100;
  }
}

class Observation {
  final String symbol;
  final String strategy;
  final int predicted;
  final int observed;
  final int epoch;
  final bool correct;

  Observation(
    this.symbol,
    this.strategy,
    this.predicted,
    this.observed,
    this.epoch,
    this.correct,
  );

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'strategy': strategy,
        'predicted': predicted,
        'observed': observed,
        'epoch': epoch,
        'correct': correct,
      };

  factory Observation.fromJson(Map<String, dynamic> j) => Observation(
        j['symbol'],
        j['strategy'],
        j['predicted'],
        j['observed'],
        j['epoch'],
        j['correct'],
      );
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final markets = [
    Market('R_10', 'Volatility 10', 3),
    Market('R_25', 'Volatility 25', 3),
    Market('R_50', 'Volatility 50', 4),
    Market('R_75', 'Volatility 75', 4),
    Market('R_100', 'Volatility 100', 2),
    Market('1HZ10V', 'Volatility 10 (1s)', 2),
    Market('1HZ25V', 'Volatility 25 (1s)', 2),
    Market('1HZ50V', 'Volatility 50 (1s)', 2),
    Market('1HZ75V', 'Volatility 75 (1s)', 2),
    Market('1HZ100V', 'Volatility 100 (1s)', 2),
  ];

  final observations = <Observation>[];
  final alerts = <String>[];
  final unsupportedSymbols = <String>{};

  WebSocketChannel? channel;
  StreamSubscription? subscription;
  Timer? clock;
  Timer? reconnect;
  Timer? heartbeat;

  int tab = 0;
  int strategy = 0;
  int remaining = 10;
  int reconnectAttempts = 0;
  int connectionGeneration = 0;

  bool grid = false;
  bool autoScan = true;
  bool sound = true;
  bool autoReconnect = true;
  bool connecting = false;
  bool socketReady = false;

  String status = 'CONNECTING';
  String selected = 'R_25';
  String note = '';
  String accountStatus = 'NOT AUTHENTICATED';
  String accountId = '';
  String balanceText = '—';
  String authToken = '';
  final tokenController = TextEditingController();
  final diagnosticLogs = <String>[];
  DateTime? lastTick;
  int tickCount = 0;
  // Demo-only broker order state. Never auto-purchase or submit on real accounts.
  int orderSequence = 20000;
  int tradesPlaced = 0;
  int consecutiveLosses = 0;
  double sessionProfit = 0;
  bool orderPending = false;
  int? openContractId;
  bool contractRecoveryPending = false;
  bool purchaseUnconfirmed = false;
  int? activeBuyRequestId;
  String activeOrderSymbol = '';
  String activeOrderType = '';
  final Set<int> settledContracts = <int>{};
  String orderState = 'IDLE';
  final List<String> orderHistory = [];
  String orderType = 'DIGITMATCH';
  final TextEditingController barrierController = TextEditingController(text: '5');
  final TextEditingController stakeController = TextEditingController(text: '0.35');
  String currency = 'USD';
  bool get demoAuthorized => accountStatus == 'DEMO AUTHENTICATED';
  bool get canOrder => socketReady && demoAuthorized && !orderPending && !purchaseUnconfirmed && !contractRecoveryPending && openContractId == null &&
      tradesPlaced < 6 && consecutiveLosses < 2 && sessionProfit > -1.0 && sessionProfit < 1.0;
  void _sendOrderRequest(Map<String, dynamic> request) {
    final socket = channel;
    if (socket == null || !socketReady) { _log('ORDER', 'WebSocket is not connected'); return; }
    socket.sink.add(jsonEncode(request));
  }
  void _requestProposal() {
    if (!canOrder) { _log('ORDER', 'Blocked: demo auth, limits, or open order'); return; }
    final stake = double.tryParse(stakeController.text);
    final barrier = int.tryParse(barrierController.text);
    final needsBarrier = !['DIGITEVEN', 'DIGITODD'].contains(orderType);
    if (stake == null || stake < 0.35 || stake > 10 ||
        (needsBarrier && (barrier == null || barrier < 0 || barrier > 9))) {
      _log('ORDER', 'Invalid stake or barrier'); return;
    }
    final market = markets.firstWhere((m) => m.symbol == selected);
    if (!market.live) { _log('ORDER', 'Selected market feed is not live'); return; }
    setState(() { orderPending = true; orderState = 'REQUESTING PROPOSAL'; activeOrderSymbol = selected; activeOrderType = orderType; });
    _sendOrderRequest({'proposal': 1, 'amount': stake, 'basis': 'stake',
      'contract_type': orderType, 'currency': currency, 'duration': 10,
      'duration_unit': 't', 'symbol': selected,
      if (!['DIGITEVEN', 'DIGITODD'].contains(orderType)) 'barrier': barrier.toString(),
      'req_id': ++orderSequence});
    _log('ORDER', 'Requested proposal $orderType $selected; no purchase yet');
  }
  Future<void> _confirmPurchase(String proposalId, double askPrice) async {
    if (!mounted || !demoAuthorized || !orderPending) return;
    final approved = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Confirm DEMO purchase'),
      content: Text('$orderType on $selected\nPrice: $askPrice $currency\n'
        'This submits a real broker order on your DEMO account.'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('BUY DEMO'))]));
    if (!mounted) return;
    if (approved != true || !demoAuthorized) {
      setState(() { orderPending = false; orderState = 'CANCELLED'; }); return;
    }
    activeBuyRequestId = ++orderSequence;
    purchaseUnconfirmed = true;
    _sendOrderRequest({'buy': proposalId, 'price': askPrice, 'req_id': activeBuyRequestId});
    setState(() => orderState = 'PURCHASE SENT');
    _log('ORDER', 'Purchase submitted; awaiting broker confirmation');
  }
  void _orderMessage(Map<String, dynamic> j) {
    final type = j['msg_type'];
    if (type == 'proposal' && j['proposal'] is Map && orderPending) {
      final proposal = j['proposal'] as Map;
      final id = proposal['id']?.toString();
      final price = (proposal['ask_price'] as num?)?.toDouble();
      if (id != null && price != null) { _confirmPurchase(id, price); }
      else { setState(() { orderPending = false; orderState = 'INVALID PROPOSAL'; }); }
      return;
    }
    if (type == 'buy' && j['buy'] is Map) {
      final buy = j['buy'] as Map;
      final id = (buy['contract_id'] as num?)?.toInt();
      if (id == null) { _log('ORDER', 'Missing contract ID'); return; }
      setState(() { openContractId = id; orderPending = false; purchaseUnconfirmed = false; contractRecoveryPending = false; tradesPlaced++; orderState = 'OPEN #$id'; });
      orderHistory.insert(0, 'OPEN #$id • $activeOrderType • $activeOrderSymbol');
      _log('ORDER', 'Broker confirmed purchase #$id');
      _sendOrderRequest({'proposal_open_contract': 1, 'contract_id': id, 'subscribe': 1});
      return;
    }
    if (type == 'proposal_open_contract' && j['proposal_open_contract'] is Map) {
      final contract = j['proposal_open_contract'] as Map;
      final id = (contract['contract_id'] as num?)?.toInt();
      if (id == null || id != openContractId) return;
      if (contract['is_sold'] == 1 && !settledContracts.contains(id)) {
        final profit = (contract['profit'] as num?)?.toDouble();
        if (profit == null) { _log('ORDER', 'Sold but no verified profit returned'); return; }
        setState(() {
          settledContracts.add(id);
          contractRecoveryPending = false;
          sessionProfit += profit;
          consecutiveLosses = profit < 0 ? consecutiveLosses + 1 : 0;
          orderState = 'SETTLED #$id'; openContractId = null;
          orderHistory.insert(0, 'SETTLED #$id • P/L ${profit.toStringAsFixed(2)} $currency');
        });
        _log('ORDER', 'Settled #$id; broker P/L $profit $currency');
      }
    }
  }


  DateTime? lastMessage;

  @override
  void initState() {
    super.initState();
    _load();
    _log('APP', 'Diagnostics initialized');
    _connect();

    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;

      setState(() {
        remaining = remaining <= 1 ? 10 : remaining - 1;

        for (final m in markets) {
          if (m.lastSeen != null &&
              DateTime.now().difference(m.lastSeen!).inSeconds > 12) {
            m.live = false;
          }
        }
      });

      if (autoScan && remaining == 10) {
        _observe();
      }

      if (lastMessage != null &&
          DateTime.now().difference(lastMessage!).inSeconds > 35 &&
          (status == 'PUBLIC LIVE' || status == 'SUBSCRIBING')) {
        _reconnect();
      }
    });
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;

    setState(() {
      autoScan = p.getBool('autoScan') ?? true;
      autoReconnect = p.getBool('autoReconnect') ?? true;
      sound = p.getBool('sound') ?? true;
      note = p.getString('journalNote') ?? '';
      // Token is intentionally not persisted in unencrypted preferences.

      final raw = p.getStringList('observations') ?? [];

      for (final x in raw) {
        try {
          observations.add(
            Observation.fromJson(
              Map<String, dynamic>.from(jsonDecode(x)),
            ),
          );
        } catch (_) {}
      }
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();

    await p.setBool('autoScan', autoScan);
    await p.setBool('autoReconnect', autoReconnect);
    await p.setBool('sound', sound);
    await p.setStringList(
      'observations',
      observations.take(300).map((x) => jsonEncode(x.toJson())).toList(),
    );
  }

  
Future<void> _connect() async {
    if (!mounted || connecting) return;
    reconnect?.cancel();
    heartbeat?.cancel();
    final generation = ++connectionGeneration;
    connecting = true;
    socketReady = false;
    setState(() => status = 'CONNECTING');

    final oldSubscription = subscription;
    final oldChannel = channel;
    subscription = null;
    channel = null;
    await oldSubscription?.cancel();
    try { await oldChannel?.sink.close(); } catch (_) {}

    // Deriv Options API public market-data WebSocket (no token needed).
    // Demo trading requires a separate OTP-authenticated demo socket.
    const endpoints = [
      'wss://api.derivws.com/trading/v1/options/ws/public',
    ];
    WebSocketChannel? connectedSocket;
    for (final endpoint in endpoints) {
      if (!mounted || generation != connectionGeneration) return;
      WebSocketChannel? candidate;
      try {
        _log('SOCKET', 'Trying $endpoint');
        candidate = WebSocketChannel.connect(Uri.parse(endpoint));
        await candidate.ready.timeout(const Duration(seconds: 12));
        if (!mounted || generation != connectionGeneration) {
          await candidate.sink.close();
          return;
        }
        connectedSocket = candidate;
        _log('SOCKET', 'Handshake successful: $endpoint');
        break;
      } catch (error) {
        _log('SOCKET ERROR', '$endpoint: $error');
        try { await candidate?.sink.close(); } catch (_) {}
      }
    }
    if (!mounted || generation != connectionGeneration) {
      try { await connectedSocket?.sink.close(); } catch (_) {}
      return;
    }
    connecting = false;
    if (connectedSocket == null) {
      setState(() => status = 'CONNECTION FAILED');
      _addAlert('Public Deriv WebSocket handshake failed. Check network and connection logs.');
      _reconnect();
      return;
    }

    final ws = connectedSocket;
    channel = ws;
    socketReady = true;
    lastMessage = DateTime.now();
    // Reset retry counter only after receiving live market data.
    subscription = ws.stream.listen(
      _message,
      onError: (Object error) {
        if (!mounted || generation != connectionGeneration) return;
        _log('SOCKET ERROR', error.toString());
        _addAlert('Connection error: $error');
        _reconnect();
      },
      onDone: () {
        if (!mounted || generation != connectionGeneration) return;
        _log('SOCKET', 'Connection closed by server');
        _reconnect();
      },
      cancelOnError: true,
    );
    setState(() {
      status = 'SUBSCRIBING';
      accountStatus = 'PUBLIC DATA ONLY';
      accountId = '';
      balanceText = '—';
    });
    try {
      _log('SOCKET', 'Connected to public market data; demo orders disabled');
      for (final market in markets) {
        if (unsupportedSymbols.contains(market.symbol)) continue;
        ws.sink.add(jsonEncode({
          'ticks': market.symbol,
          'subscribe': 1,
        }));
        _log('FEED', 'Subscribed to ${market.symbol}');
      }
      heartbeat = Timer.periodic(const Duration(seconds: 25), (_) {
        if (!mounted || generation != connectionGeneration || !socketReady) return;
        try {
          ws.sink.add(jsonEncode({'ping': 1}));
        } catch (error) {
          _log('HEARTBEAT', error.toString());
          _reconnect();
        }
      });
    } catch (error) {
      _log('SOCKET ERROR', 'Subscription failed: $error');
      _reconnect();
    }
  }

  void _reconnect() {
    if (!mounted || reconnect?.isActive == true) return;
    connectionGeneration++;
    heartbeat?.cancel();
    subscription?.cancel();
    subscription = null;
    try { channel?.sink.close(); } catch (_) {}
    channel = null;
    socketReady = false;
    connecting = false;
    if (orderPending && purchaseUnconfirmed) {
      contractRecoveryPending = true;
      _log('ORDER', 'Purchase outcome unknown; trading blocked until reconciled');
    }
    orderPending = false;
    orderState = openContractId == null
        ? 'DISCONNECTED'
        : 'CONNECTION LOST — VERIFY CONTRACT IN DERIV';
    setState(() {
      status = autoReconnect ? 'RECONNECTING' : 'DISCONNECTED';
      accountStatus = 'NOT AUTHENTICATED';
      accountId = '';
      balanceText = '—';
      for (final m in markets) { m.live = false; }
    });
    if (!autoReconnect) return;
    final delay = min(30, 2 << min(reconnectAttempts++, 4));
    _log('RECONNECT', 'Retry in $delay seconds');
    reconnect = Timer(Duration(seconds: delay), _connect);
  }

  void _log(String category, String message) {
    if (!mounted) return;
    final time = DateTime.now().toIso8601String().split('T').last.split('.').first;
    diagnosticLogs.insert(0, '[$time] $category: $message');
    if (diagnosticLogs.length > 300) diagnosticLogs.removeLast();
  }

  void _authorize(String token) {
    // The public endpoint cannot authorize an account. Do not transmit PATs
    // to it or silently enable trading without an OTP-authenticated demo socket.
    tokenController.clear();
    authToken = '';
    _log('AUTH', 'Demo login unavailable in public-data build. OTP integration required.');
    _addAlert('Demo trading needs account ID, App ID and OTP-authenticated demo WebSocket.');
    setState(() => accountStatus = 'PUBLIC DATA ONLY');
  }

  void _addAlert(String message) {
    if (!mounted) return;

    setState(() {
      alerts.insert(0, message);
      if (alerts.length > 80) {
        alerts.removeLast();
      }
    });
  }

  void _message(dynamic raw) {
    try {
      final j = jsonDecode(raw as String) as Map<String, dynamic>;
      lastMessage = DateTime.now();

      if (j['error'] == null && j['msg_type'] == 'authorize' && j['authorize'] is Map) {
        final a = j['authorize'] as Map;
        accountId = a['loginid']?.toString() ?? '';
        currency = a['currency']?.toString() ?? 'USD';
        accountStatus = (a['is_virtual'] == 1 || a['is_virtual'] == true) ? 'DEMO AUTHENTICATED' : 'REAL ACCOUNT - READ ONLY';
        _log('AUTH', 'Authorized account $accountId');
        if (openContractId != null && demoAuthorized) {
          contractRecoveryPending = true;
          channel?.sink.add(jsonEncode({'proposal_open_contract': 1, 'contract_id': openContractId, 'subscribe': 1}));
          _log('ORDER', 'Rechecking open contract #$openContractId');
        }
        channel?.sink.add(jsonEncode({'balance': 1, 'subscribe': 1}));
        setState(() {});
        return;
      }
      if (j['msg_type'] == 'balance' && j['balance'] is Map) {
        final b = j['balance'] as Map;
        balanceText = '${b['balance'] ?? '—'} ${b['currency'] ?? ''}';
        setState(() {});
        return;
      }
      if (j['error'] != null) {
        if (['proposal', 'buy'].contains(j['msg_type']) || (j['echo_req'] is Map && ((j['echo_req'] as Map).containsKey('proposal') || (j['echo_req'] as Map).containsKey('buy')))) {
          orderPending = false; purchaseUnconfirmed = false; orderState = 'ORDER ERROR';
        }
        final error = j['error'];
        final message = error is Map
            ? (error['message']?.toString() ?? 'API error')
            : 'API error';

        final echo = j['echo_req'];
        final symbol =
            echo is Map ? echo['ticks']?.toString() : null;

        if (symbol != null &&
            (message.toLowerCase().contains('symbol') ||
                message.toLowerCase().contains('market'))) {
          unsupportedSymbols.add(symbol);
        }

        final code = error is Map ? error['code']?.toString() ?? 'unknown' : 'unknown';
        _log('DERIV ERROR', '$code: $message');
        if (j['echo_req'] is Map && (j['echo_req'] as Map).containsKey('authorize')) {
          accountStatus = 'AUTH FAILED';
          authToken = '';
          _log('AUTH', 'Authorization rejected; re-enter a valid demo token');
        }
        _addAlert('Deriv: $message');

        if (mounted) {
          setState(() {
            if (echo is Map && echo.containsKey('authorize')) {
              accountStatus = 'AUTH FAILED';
            } else if (symbol != null) {
              if (tickCount == 0) status = 'FEED ERROR';
            }
          });
        }
        return;
      }

      if (['proposal', 'buy', 'proposal_open_contract'].contains(j['msg_type'])) { _orderMessage(j); return; }
      if (j['msg_type'] != 'tick') return;

      final t = j['tick'];
      if (t is! Map) return;

      Market? m;
      for (final market in markets) {
        if (market.symbol == t['symbol']) {
          m = market;
          break;
        }
      }

      if (m == null ||
          t['quote'] is! num ||
          t['epoch'] is! num) {
        return;
      }

      final q = (t['quote'] as num).toDouble();
      final epoch = (t['epoch'] as num).toInt();
      final rawPrecision = t['pip_size'];
      final precision =
          rawPrecision is num ? rawPrecision.toInt() : m.precision;

      if (precision < 0 || precision > 10) return;

      final formatted = q.toStringAsFixed(precision);
      final digit = int.tryParse(
        formatted.substring(formatted.length - 1),
      );

      if (digit == null) return;

      if (m.ticks.isNotEmpty &&
          m.ticks.last.epoch == epoch &&
          m.ticks.last.quote == q) {
        return;
      }

      m.ticks.add(TickPoint(q, epoch, digit));

      if (m.ticks.length > 200) {
        m.ticks.removeAt(0);
      }

      m.lastSeen = DateTime.now();
      lastTick = DateTime.now();
      tickCount++;
      if (m.ticks.length == 1) _log('FEED', '${m.symbol} first tick');
      m.live = true;
      reconnectAttempts = 0;

      _trend(m);
      _settle(m);

      if (mounted) {
        setState(() => status = 'PUBLIC LIVE');
      }
    } catch (error) {
      _addAlert('Market data parsing error: $error');
    }
  }

  void _trend(Market m) {
    if (m.ticks.length < 50) {
      m.trend = 'COLLECTING';
      return;
    }

    final xs = m.ticks.map((e) => e.quote).toList();

    double ema(int n) {
      var a = xs.first;
      final k = 2 / (n + 1);

      for (final x in xs.skip(1)) {
        a = x * k + a * (1 - k);
      }

      return a;
    }

    final a = ema(20);
    final b = ema(50);

    m.trend = a > b
        ? 'UP'
        : a < b
            ? 'DOWN'
            : 'SIDEWAYS';

    // Tick-derived indicators, NOT 1m/5m/15m closed-candle signals.
    var gains = 0.0;
    var losses = 0.0;
    for (var i = xs.length - 14; i < xs.length; i++) {
      final delta = xs[i] - xs[i - 1];
      if (delta > 0) { gains += delta; } else { losses -= delta; }
    }
    m.rsi = losses == 0 ? (gains == 0 ? 50.0 : 100.0)
        : 100.0 - 100.0 / (1.0 + gains / losses);
    double emaFor(int period) {
      var value = xs.first;
      final factor = 2.0 / (period + 1);
      for (final x in xs.skip(1)) { value += factor * (x - value); }
      return value;
    }
    m.macd = emaFor(12) - emaFor(26);
    var sumMovement = 0.0;
    for (var i = xs.length - 14; i < xs.length; i++) {
      sumMovement += (xs[i] - xs[i - 1]).abs();
    }
    m.atr = sumMovement / 14; // Mean tick movement; not candle ATR.
    m.agreement = ((a - b).abs() /
            (xs.last.abs() + 0.0001) *
            10000)
        .clamp(0, 100)
        .toDouble();
  }

  // V12.2: One-step-ahead digit forecast. Uses only past ticks.
  // A smoothed first-order transition model is blended with marginal
  // digit frequencies; it is not trained on the future settlement tick.
  // This is an experimental forecast, NOT a calibrated win probability.
  List<double> _nextDigitScores(Market m) {
    final history = m.ticks;
    final global = List<double>.filled(10, 1.0); // Laplace smoothing
    final conditional = List<double>.filled(10, 1.0);
    if (history.isEmpty) return List<double>.filled(10, 0.1);
    final previous = history.last.digit;
    for (var i = 0; i < history.length; i++) {
      global[history[i].digit]++;
      if (i > 0 && history[i - 1].digit == previous) {
        conditional[history[i].digit]++;
      }
    }
    final globalSum = global.reduce((a, b) => a + b);
    final conditionalSum = conditional.reduce((a, b) => a + b);
    // Shrink conditional estimates toward the unconditional distribution.
    final transitions = conditionalSum - 10;
    final weight = transitions / (transitions + 50.0);
    return List.generate(10, (d) =>
      weight * conditional[d] / conditionalSum +
      (1 - weight) * global[d] / globalSum);
  }

  void _predict(Market m) {
    if (!m.live || m.ticks.length < 100 || m.prediction != null) return;
    final scores = _nextDigitScores(m);
    var best = 0;
    for (var i = 1; i < 10; i++) {
      if (scores[i] > scores[best]) best = i;
    }
    m.prediction = best;
    m.nextDigitEstimate = scores[best] * 100;
    m.predictionMethod = 'Transition + frequency';
    m.predictedEpoch = m.ticks.last.epoch;
    m.predictionStrategy = strategy;
    m.predictionDeadline = DateTime.now().add(const Duration(seconds: 10));
  }

  void _observe() {
    for (final m in markets) {
      if (m.live &&
          m.ticks.length >= 100 &&
          m.prediction == null) {
        _predict(m);
      }
    }

    if (mounted) setState(() {});
  }

  void _settle(Market m) {
    if (m.prediction == null ||
        m.predictionDeadline == null ||
        m.predictedEpoch == null) {
      return;
    }

    final deadline =
        m.predictionDeadline!.millisecondsSinceEpoch ~/ 1000;

    if (m.ticks.last.epoch < deadline ||
        m.ticks.last.epoch <= m.predictedEpoch!) {
      return;
    }

    final eligible = m.ticks.where((t) => t.epoch >= deadline && t.epoch > m.predictedEpoch!).toList();
    if (eligible.isEmpty) return;
    final tick = eligible.first;
    if (m.lastSettledEpoch == tick.epoch) return;
    m.lastSettledEpoch = tick.epoch;

    final predicted = m.prediction!;
    final observed = tick.digit;
    final mode = m.predictionStrategy;

    final correct = switch (mode) {
      0 => observed == predicted,
      1 => observed.isEven == predicted.isEven,
      _ => observed > predicted,
    };

    observations.insert(
      0,
      Observation(
        m.symbol,
        ['Matches', 'Even/Odd', 'Over/Under'][mode],
        predicted,
        observed,
        tick.epoch,
        correct,
      ),
    );

    if (observations.length > 300) {
      observations.removeLast();
    }

    if (sound) {
      _addAlert(
        '${m.name}: ${correct ? 'CORRECT' : 'INCORRECT'}'
        ' • $predicted → $observed',
      );
    }

    m.prediction = null;
    m.predictedEpoch = null;
    m.predictionDeadline = null;

    _save();
  }

  @override
  void dispose() {
    tokenController.dispose();
    barrierController.dispose();
    stakeController.dispose();
    clock?.cancel();
    reconnect?.cancel();
    heartbeat?.cancel();
    subscription?.cancel();
    channel?.sink.close();
    super.dispose();
  }

  Widget _card(
    Widget child, {
    EdgeInsets padding = const EdgeInsets.all(16),
  }) =>
      Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: padding,
        decoration: BoxDecoration(
          color: panel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: blue.withOpacity(.5)),
        ),
        child: child,
      );

  Widget _pill(String text, {Color color = cyan}) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 9,
          vertical: 5,
        ),
        decoration: BoxDecoration(
          color: color.withOpacity(.15),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      );

  Widget _metric(String value, String label) => Expanded(
        child: _card(
          Column(
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: cyan,
                ),
              ),
              Text(
                label,
                style: const TextStyle(fontSize: 10),
              ),
            ],
          ),
        ),
      );

  Widget _marketCard(Market m) {
    final n = m.prediction;

    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  m.name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              _pill(
                m.live ? '● LIVE' : '● WAIT',
                color: m.live ? green : Colors.orange,
              ),
            ],
          ),
          Text(
            m.symbol,
            style: const TextStyle(color: Colors.white60),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    const Text(
                      'NEXT DIGIT',
                      style: TextStyle(fontSize: 10),
                    ),
                    Container(
                      width: 72,
                      height: 72,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [blue, cyan],
                        ),
                      ),
                      child: Text(
                        n?.toString() ?? '⌛',
                        style: const TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: Column(
                  children: [
                    Text(
                      n == null
                          ? 'COLLECTING'
                          : 'Model estimate ${m.nextDigitEstimate.toStringAsFixed(1)}% (unvalidated)',
                      style: const TextStyle(
                        color: Colors.amber,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      n == null
                          ? 'WAITING FOR DATA'
                          : 'NEXT SCAN IN ${remaining}s',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      'Trend: ${m.trend} • ${m.ticks.length} ticks',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          const Text(
            'Historical frequency is not a verified win probability.',
            style: TextStyle(
              fontSize: 10,
              color: Colors.white54,
            ),
          ),
        ],
      ),
    );
  }

  // V12.1: Results are observations, never broker trade outcomes.
  List<Observation> _filteredResults({String? symbol, String? mode}) =>
      observations.where((o) =>
        (symbol == null || o.symbol == symbol) &&
        (mode == null || o.strategy == mode)).toList();

  String _successRate(List<Observation> sample) => sample.isEmpty
      ? '—'
      : '${(100 * sample.where((o) => o.correct).length / sample.length).toStringAsFixed(1)}%';

  Widget _successMonitor() {
    final selectedMode = ['Matches', 'Even/Odd', 'Over/Under'][strategy];
    final selected = _filteredResults(mode: selectedMode);
    final correct = selected.where((o) => o.correct).length;
    Widget window(int size) {
      final sample = selected.take(size).toList();
      return Expanded(child: _metric(_successRate(sample),
          'LAST $size (${sample.length})'));
    }
    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Prediction Success Monitor',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
        const SizedBox(height: 5),
        Text('$selectedMode • observed outcomes, not trading wins',
          style: const TextStyle(color: Colors.white70, fontSize: 12)),
        const SizedBox(height: 10),
        Row(children: [
          _metric(_successRate(selected), 'SUCCESS RATE'),
          const SizedBox(width: 7),
          _metric('${selected.length}', 'OBSERVATIONS'),
        ]),
        Row(children: [
          _metric('$correct', 'CORRECT'),
          const SizedBox(width: 7),
          _metric('${selected.length - correct}', 'INCORRECT'),
        ]),
        Row(children: [window(10), const SizedBox(width: 5), window(50)]),
        Row(children: [window(100), const SizedBox(width: 5), window(300)]),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const Text('Next-digit forecast (experimental)',
          style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 5),
        ...markets.map((m) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(m.name, style: const TextStyle(fontSize: 12))),
            Text(m.prediction == null ? 'Collecting' :
              'Digit ${m.prediction} • model ${m.nextDigitEstimate.toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 12, color: cyan)),
          ]),
        )),
        const Text('Transition + frequency forecast. The percentage is a model estimate, '
          'not validated confidence; evaluation uses a future tick after the scan deadline.',
          style: TextStyle(color: Colors.white60, fontSize: 11)),
        const SizedBox(height: 10),
        const Text('Success by market',
          style: TextStyle(fontWeight: FontWeight.bold)),
        ...markets.map((m) {
          final sample = _filteredResults(symbol: m.symbol, mode: selectedMode);
          final successes = sample.where((o) => o.correct).length;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              Expanded(child: Text(m.name, style: const TextStyle(fontSize: 12))),
              Text('$successes/${sample.length}  ${_successRate(sample)}',
                style: const TextStyle(fontSize: 12)),
            ]),
          );
        }),
        const SizedBox(height: 5),
        const Text('Each percentage uses only settled observations for the selected strategy. '
          'Model estimates are not verified win probabilities. '
          'Small samples are unreliable; outcomes do not establish profitability.',
          style: TextStyle(color: Colors.white60, fontSize: 11)),
      ],
    ));
  }

  Widget _radar() {
    final valid = markets.where((m) => m.live).length;
    final strategyResults = _filteredResults(
      mode: ['Matches', 'Even/Odd', 'Over/Under'][strategy]);
    final accuracy = strategyResults.isEmpty
        ? null
        : 100 * strategyResults.where((o) => o.correct).length /
            strategyResults.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _pill(
              status,
              color: status == 'PUBLIC LIVE'
                  ? green
                  : Colors.orange,
            ),
            const Spacer(),
            Text('$valid/${markets.length} feeds'),
          ],
        ),
        const SizedBox(height: 14),
        const Text(
          'Volatility Predictions',
          style: TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.bold,
          ),
        ),
        const Text(
          'Live digit observations across Volatility Indices',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          children: List.generate(
            3,
            (i) => ChoiceChip(
              label: Text(
                ['Matches', 'Even / Odd', 'Over / Under'][i],
              ),
              selected: strategy == i,
              onSelected: (_) {
                setState(() => strategy = i);
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        _successMonitor(),
        Row(
          children: [
            _metric(
              accuracy == null
                  ? '—'
                  : '${accuracy.toStringAsFixed(1)}%',
              'OBSERVED ACCURACY',
            ),
            const SizedBox(width: 7),
            _metric(
              '${strategyResults.length}',
              'OBSERVATIONS',
            ),
          ],
        ),
        Row(
          children: [
            _metric('$valid', 'LIVE FEEDS'),
            const SizedBox(width: 7),
            _metric(
              '${markets.where((m) => m.prediction != null).length}',
              'ANALYZING',
            ),
          ],
        ),
        Row(
          children: [
            const Text(
              'All markets',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            IconButton(
              onPressed: () => setState(() => grid = !grid),
              icon: Icon(
                grid ? Icons.view_agenda : Icons.grid_view,
              ),
            ),
            Switch(
              value: autoScan,
              onChanged: (v) {
                setState(() => autoScan = v);
                _save();
              },
            ),
          ],
        ),
        ...markets.map(_marketCard),
      ],
    );
  }

  Widget _analyzer() {
    final m = markets.firstWhere(
      (m) => m.symbol == selected,
    );

    final counts = List.generate(
      10,
      (i) => m.ticks.where((x) => x.digit == i).length,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Expert Analyzer',
          style: TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.bold,
          ),
        ),
        _card(
          DropdownButton<String>(
            isExpanded: true,
            value: selected,
            items: markets
                .map(
                  (m) => DropdownMenuItem(
                    value: m.symbol,
                    child: Text(m.name),
                  ),
                )
                .toList(),
            onChanged: (s) {
              if (s != null) {
                setState(() => selected = s);
              }
            },
          ),
        ),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      m.name,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  _pill(
                    m.live ? 'LIVE' : 'WAIT',
                    color: m.live ? green : Colors.orange,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Trend: ${m.trend}',
                style: const TextStyle(
                  fontSize: 22,
                  color: cyan,
                ),
              ),
              Text(
                'Last digit: ${m.lastDigit ?? '—'} • ${m.ticks.length} ticks',
              ),
              Text('Tick RSI: ${m.rsi?.toStringAsFixed(1) ?? '—'} • MACD: ${m.macd?.toStringAsFixed(5) ?? '—'}'),
              Text('Mean tick movement: ${m.atr?.toStringAsFixed(5) ?? '—'}'),
              const Text('Tick indicators only; not closed-candle or validated win probability.', style: TextStyle(fontSize: 11, color: Colors.white60)),
              const SizedBox(height: 16),
              SizedBox(
                height: 100,
                child: CustomPaint(
                  painter: SparkPainter(
                    m.ticks.map((e) => e.quote).toList(),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Live tick chart (not closed candles)',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white60,
                ),
              ),
            ],
          ),
        ),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Digit Distribution',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                ),
              ),
              for (int i = 0; i < 10; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 20,
                        child: Text('$i'),
                      ),
                      Expanded(
                        child: LinearProgressIndicator(
                          value: m.ticks.isEmpty
                              ? 0
                              : counts[i] / m.ticks.length,
                          color: cyan,
                          minHeight: 8,
                          backgroundColor: Colors.white12,
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 52,
                        child: Text(
                          m.ticks.isEmpty
                              ? '—'
                              : '${(counts[i] * 100 / m.ticks.length).toStringAsFixed(1)}%',
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        FilledButton(
          onPressed: () {
            setState(() => _predict(m));
          },
          child: const Text('REFRESH ANALYSIS'),
        ),
      ],
    );
  }

  Widget _trades() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Demo Orders', style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
    _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Account: $accountStatus'), Text('Order: $orderState'),
      if (contractRecoveryPending || purchaseUnconfirmed) const Text('Trading locked: verify unresolved purchase in Deriv before restarting.', style: TextStyle(color: Colors.amber)),
      Text('Session P/L: ${sessionProfit.toStringAsFixed(2)} $currency'),
      Text('Trades: $tradesPlaced/6 • Consecutive losses: $consecutiveLosses/2'),
      if (!demoAuthorized) const Text('DEMO authorization required. Real accounts are read-only.',
        style: TextStyle(color: Colors.amber)),
      DropdownButton<String>(isExpanded: true, value: selected,
        items: markets.map((m) => DropdownMenuItem(value: m.symbol, child: Text(m.name))).toList(),
        onChanged: openContractId == null ? (v) { if (v != null) setState(() => selected = v); } : null),
      DropdownButton<String>(isExpanded: true, value: orderType,
        items: const [
          DropdownMenuItem(value: 'DIGITMATCH', child: Text('Matches')),
          DropdownMenuItem(value: 'DIGITDIFF', child: Text('Differs')),
          DropdownMenuItem(value: 'DIGITEVEN', child: Text('Even')),
          DropdownMenuItem(value: 'DIGITODD', child: Text('Odd')),
          DropdownMenuItem(value: 'DIGITOVER', child: Text('Over')),
          DropdownMenuItem(value: 'DIGITUNDER', child: Text('Under')),
        ], onChanged: (v) { if (v != null) setState(() => orderType = v); }),
      TextField(controller: barrierController, keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Barrier digit (0–9; when applicable)')),
      TextField(controller: stakeController, keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Stake (USD; minimum 0.35)')),
      const SizedBox(height: 10),
      FilledButton(onPressed: canOrder ? _requestProposal : null,
        child: const Text('GET PROPOSAL → CONFIRM DEMO BUY')),
      const Text('10 ticks duration. Broker may reject unsupported contracts. '
        'No automated purchases; purchase requires confirmation.',
        style: TextStyle(fontSize: 11, color: Colors.white60)),
    ])),
    ...orderHistory.take(30).map((x) => _card(Text(x))),
  ]);

  Widget _history() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Observation History',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          ...observations.take(100).map(
                (o) => _card(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${o.symbol} • ${o.strategy} • '
                        '${o.correct ? 'CORRECT' : 'INCORRECT'}',
                        style: TextStyle(
                          color: o.correct ? green : red,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Predicted ${o.predicted} • '
                        'Observed ${o.observed} • '
                        'Epoch ${o.epoch}',
                      ),
                    ],
                  ),
                ),
              ),
        ],
      );

  Widget _journal() {
    final wins = observations.where((x) => x.correct).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Trading Journal',
          style: TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.bold,
          ),
        ),
        Row(
          children: [
            _metric('${observations.length}', 'TOTAL'),
            const SizedBox(width: 6),
            _metric('$wins', 'CORRECT'),
            const SizedBox(width: 6),
            _metric(
              '${observations.length - wins}',
              'INCORRECT',
            ),
          ],
        ),
        _card(
          Text(
            'Observed accuracy: '
            '${observations.isEmpty ? 'Not measured' : '${(wins * 100 / observations.length).toStringAsFixed(1)}%'}'
            '\nObservations are not broker trades.',
          ),
        ),
        _card(
          TextField(
            controller: TextEditingController(text: note)
              ..selection = TextSelection.collapsed(
                offset: note.length,
              ),
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Your notes',
              hintText: 'Write a trading observation...',
            ),
            onChanged: (v) => note = v,
          ),
        ),
        FilledButton(
          onPressed: () async {
            final p = await SharedPreferences.getInstance();
            await p.setString('journalNote', note);

            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Note saved locally'),
                ),
              );
            }
          },
          child: const Text('SAVE NOTE'),
        ),
      ],
    );
  }

  Widget _alerts() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Alerts',
            style: TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.bold,
            ),
          ),
          _card(
            SwitchListTile(
              title: const Text('Observation alerts'),
              subtitle: const Text(
                'Local result notifications in the app',
              ),
              value: sound,
              onChanged: (v) {
                setState(() => sound = v);
                _save();
              },
            ),
          ),
          ...alerts.take(80).map(
                (a) => _card(Text(a)),
              ),
        ],
      );

  Widget _diagnostics() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Connection Diagnostics', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
      _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Socket: $status'), Text('Account: $accountStatus'),
        Text('Account ID: ${accountId.isEmpty ? '—' : accountId}'),
        Text('Balance: $balanceText'), Text('Ticks received: $tickCount'),
        Text('Reconnect attempts: $reconnectAttempts'),
        Text('Unresolved purchase: $purchaseUnconfirmed • Recovery lock: $contractRecoveryPending'),
        Text('Last tick: ${lastTick?.toIso8601String() ?? 'Never'}'),
      ])),
      _card(Column(children: [
        const Text('Public market data connection. Demo account login and trading are disabled until OTP authentication is integrated.'),
      ])),
      Row(children: [
        Expanded(child: OutlinedButton(onPressed: () { reconnect?.cancel(); _reconnect(); if (!autoReconnect) _connect(); }, child: const Text('RECONNECT'))),
        const SizedBox(width: 8),
        Expanded(child: OutlinedButton(onPressed: () { setState(() => diagnosticLogs.clear()); }, child: const Text('CLEAR LOG'))),
      ]),
      ...diagnosticLogs.take(100).map((line) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: SelectableText(line, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')))),
    ],
  );

  Widget _settings() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Settings',
            style: TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.bold,
            ),
          ),
          _card(
            Column(
              children: [
                SwitchListTile(
                  title: const Text('Automatic scanning'),
                  value: autoScan,
                  onChanged: (v) {
                    setState(() => autoScan = v);
                    _save();
                  },
                ),
                SwitchListTile(
                  title: const Text('Auto reconnect'),
                  value: autoReconnect,
                  onChanged: (v) {
                    setState(() => autoReconnect = v);
                    _save();
                  },
                ),
                SwitchListTile(
                  title: const Text('In-app alerts'),
                  value: sound,
                  onChanged: (v) {
                    setState(() => sound = v);
                    _save();
                  },
                ),
                const ListTile(
                  title: Text('Market feed'),
                  subtitle: Text(
                    'Deriv public WebSocket • app_id 1089',
                  ),
                ),
                const ListTile(
                  title: Text('Trading mode'),
                  subtitle: Text(
                    'Public scanning; demo orders require verified demo authorization',
                  ),
                ),
              ],
            ),
          ),
          FilledButton(
            onPressed: () {
              reconnect?.cancel();
              _reconnect();
              if (!autoReconnect) _connect();
            },
            child: const Text('RECONNECT MARKET FEED'),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final pages = <Widget Function()>[
      _radar,
      _analyzer,
      _trades,
      _history,
      _journal,
      _alerts,
      _settings,
      _diagnostics,
    ];

    final names = [
      'Radar',
      'Analyzer',
      'Trades',
      'History',
      'Journal',
      'Alerts',
      'Settings',
      'Logs',
    ];

    final icons = [
      Icons.radar,
      Icons.bar_chart,
      Icons.swap_horiz,
      Icons.history,
      Icons.article_outlined,
      Icons.notifications_outlined,
      Icons.settings_outlined,
      Icons.terminal,
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: panel,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'V12.2 Expert Trader PRO',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'Deriv • Demo market scanner',
              style: TextStyle(
                fontSize: 11,
                color: Colors.white70,
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Center(
              child: _pill(
                accountStatus == 'DEMO AUTHENTICATED' ? 'DEMO' : 'PUBLIC DATA',
                color: green,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(14),
                children: [pages[tab]()],
              ),
            ),
            Container(
              height: 69,
              decoration: BoxDecoration(
                color: panel,
                border: Border(
                  top: BorderSide(
                    color: blue.withOpacity(.4),
                  ),
                ),
              ),
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: names.length,
                itemBuilder: (context, i) => InkWell(
                  onTap: () {
                    setState(() => tab = i);
                  },
                  child: Container(
                    width: MediaQuery.sizeOf(context).width / 6.2,
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    decoration: BoxDecoration(
                      color: tab == i
                          ? blue.withOpacity(.2)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          icons[i],
                          size: 22,
                          color: tab == i
                              ? cyan
                              : Colors.white70,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          names[i],
                          style: TextStyle(
                            fontSize: 10,
                            color: tab == i
                                ? cyan
                                : Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SparkPainter extends CustomPainter {
  final List<double> values;

  SparkPainter(this.values);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    final a = values.length > 80
        ? values.sublist(values.length - 80)
        : values;

    final lo = a.reduce(min);
    final hi = a.reduce(max);
    final range = max(hi - lo, .00001);

    final path = Path();

    for (var i = 0; i < a.length; i++) {
      final x = i * size.width / (a.length - 1);
      final y = size.height -
          (a[i] - lo) / range * size.height;

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = cyan
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant SparkPainter old) => true;
}
