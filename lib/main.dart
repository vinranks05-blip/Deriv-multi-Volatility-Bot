import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';
import 'paper_ledger.dart';
import 'ledger_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'deriv_v13_market_data.dart';
import 'prediction_engine.dart';
part 'dashboard_views.dart';

void main() => runApp(const V13App());
const bg = Color(0xff030d26), panel = Color(0xff10234b);
const cyan = Color(0xff00d8ff), blue = Color(0xff1385ff);
const green = Color(0xff00e5a0), red = Color(0xffff5275);

class V13App extends StatelessWidget {
  const V13App({super.key, this.data, this.storage});
  final V13MarketData? data;
  final LedgerStorage? storage;
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
    home: Dashboard(data: data, storage: storage),
  );
}

class Market {
  final String symbol, name;
  final int precision;
  Market(this.symbol, this.name, this.precision);
  List<V13Tick> ticks = [];
  SignalRecord? forecast;
  String phase = 'Collecting data';
  DateTime? lastSeen;
  String trend = 'COLLECTING', method = 'COLLECTING';
  double? rsi, macd, movement;
  double holdout = 0, baseline = 0;
  double logLoss = 0, brier = 0;
  int eligible = 0, abstained = 0;
  int testCount = 0, tickSequence = 0;
  int? lastEvaluationSequence;
  int evaluatedStrategy = -1, evaluatedBarrier = -1;
  DigitModel model = const DigitModel(0);
  bool get live =>
      lastSeen != null && DateTime.now().difference(lastSeen!).inSeconds < 15;
  int? get lastDigit => ticks.isEmpty ? null : ticks.last.lastDigit;
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key, this.data, this.storage});
  final V13MarketData? data;
  final LedgerStorage? storage;
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> with WidgetsBindingObserver {
  late final data = widget.data ?? V13MarketData();
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
  late final PaperLedger ledger;
  late final LedgerStorage storage = widget.storage ?? FileLedgerStorage();
  bool ledgerReady = false, compact = true, readyOnly = false;
  String? storageError;
  String historySymbol = 'All', historyMode = 'All', historyOutcome = 'All';
  String historyPaper = 'All';
  int historyPage = 0;
  final pinned = <String>{};
  final stakeInput = TextEditingController(text: '0.35');
  final payoutInput = TextEditingController(text: '9.24');
  final delayInput = TextEditingController(text: '1000');
  final durationInput = TextEditingController(text: '1');
  final expiryInput = TextEditingController(text: '5000');
  final logs = <String>[];
  final alerts = <String>[];
  final journal = TextEditingController();
  final subscriptions = <StreamSubscription>[];
  Timer? clock;
  int tab = 0, strategy = 0, scanRemaining = 10, tickCount = 0;
  String selected = 'R_25';
  bool autoScan = true, notifications = true;
  bool foreground = true;
  String connection = 'CONNECTING';
  static const modes = predictionLabels;
  int barrier = 5;
  double confidenceThreshold = 0;
  PredictionMode get mode => PredictionMode.values[strategy];
  String get modeLabel =>
      strategy < 2 ? modes[strategy] : '${modes[strategy]} $barrier';
  Market market(String symbol) => markets.firstWhere((m) => m.symbol == symbol);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ledger = PaperLedger(onEvent: _appendEvent);
    _load();
    subscriptions.add(data.ticks.listen(_onTick));
    subscriptions.add(data.historyUpdates.listen(_onHistory));
    subscriptions.add(
      data.errors.listen((e) {
        if (!mounted) return;
        _log(e);
        ledger.interrupt('Feed error: $e');
        for (final m in markets) {
          m.forecast = null;
          m.lastSeen = null;
        }
        setState(
          () => connection = data.connected ? 'PUBLIC LIVE' : 'RECONNECTING',
        );
      }),
    );
    subscriptions.add(
      data.symbols.listen((s) {
        _log('Available volatility symbols: ${s.length}');
      }),
    );
    for (final m in markets) {
      data.watch(m.symbol);
    }
    data.connect();
    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        connection = data.connected
            ? (tickCount > 0 ? 'PUBLIC LIVE' : 'SUBSCRIBING')
            : 'RECONNECTING';
        scanRemaining = scanRemaining <= 1 ? 10 : scanRemaining - 1;
      });
      if (ledgerReady) {
        ledger.expire(DateTime.now());
        for (final m in markets) {
          if (!m.live) {
            ledger.interrupt('Feed stale', symbol: m.symbol);
            m.forecast = null;
          } else if (m.forecast?.observation != 'pending') {
            m.forecast = null;
          }
        }
      }
      if (foreground && autoScan && scanRemaining == 10) _scan();
    });
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      confidenceThreshold = p.getDouble('v14_threshold') ?? 0;
      autoScan = p.getBool('v13_autoScan') ?? true;
      notifications = p.getBool('v13_alerts') ?? true;
      journal.text = p.getString('v13_journal') ?? '';
      compact = p.getBool('compactCards') ?? true;
      readyOnly = p.getBool('readyOnly') ?? false;
      pinned.addAll(p.getStringList('pinnedMarkets') ?? []);
      final config = p.getString('paperConfig');
      if (config != null) {
        try {
          ledger.config = PaperConfig.fromJson(
            Map<String, dynamic>.from(jsonDecode(config)),
          );
          ledger.config.validate();
          if (!markets.any((m) => m.symbol == ledger.config.symbol))
            throw const FormatException('Unknown paper market');
          selected = ledger.config.symbol;
          stakeInput.text = ledger.config.stake.toString();
          payoutInput.text = ledger.config.grossMultiplier.toString();
          delayInput.text = ledger.config.delayMs.toString();
          durationInput.text = ledger.config.durationTicks.toString();
          expiryInput.text = ledger.config.expiryMs.toString();
        } catch (error) {
          ledger.config = const PaperConfig();
          _log('Invalid saved paper assumptions; defaults restored');
        }
      }
    });
    try {
      final events = await storage.read();
      if (!mounted) return;
      ledger.restore(events);
      setState(() => ledgerReady = true);
    } catch (error) {
      _storageFailed(error);
    }
  }

  void _appendEvent(Map<String, dynamic> event) {
    storage.append(event).catchError((Object error) {
      _storageFailed(error);
    });
  }

  void _storageFailed(Object error) {
    ledger.enabled = false;
    if (!mounted) return;
    setState(() {
      storageError = 'Ledger unavailable: $error';
      ledgerReady = false;
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('v14_threshold', confidenceThreshold);
    await p.setBool('v13_autoScan', autoScan);
    await p.setBool('v13_alerts', notifications);
    await p.setString('v13_journal', journal.text);
    await p.setBool('compactCards', compact);
    await p.setBool('readyOnly', readyOnly);
    await p.setStringList('pinnedMarkets', pinned.toList());
    await p.setString('paperConfig', jsonEncode(ledger.config.toJson()));
  }

  void _log(String msg) {
    logs.insert(
      0,
      '${DateTime.now().toIso8601String().substring(11, 19)}  $msg',
    );
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
    // A missing feed cannot provide an honest next-tick observation.
    if (m.lastSeen != null &&
        DateTime.now().difference(m.lastSeen!).inSeconds >= 15) {
      ledger.interrupt('Feed gap', symbol: m.symbol);
      m.forecast = null;
    }
    m.lastSeen = DateTime.now();
    m.tickSequence++;
    tickCount++;
    if (tickCount % 5 == 0) _indicators(m);
    if (ledgerReady) {
      ledger.tick(
        symbol: tick.symbol,
        epoch: tick.epoch,
        sequence: m.tickSequence,
        price: tick.price,
        digit: tick.lastDigit,
        now: DateTime.now(),
      );
      final f = m.forecast;
      if (f != null && f.observation != 'pending') {
        if (notifications) {
          alerts.insert(
            0,
            '${m.name}: ${f.label} • ${f.observation.toUpperCase()}',
          );
          if (alerts.length > 80) alerts.removeLast();
        }
        m.forecast = null;
      }
    }
    setState(() => connection = 'PUBLIC LIVE');
  }

  void _indicators(Market m) {
    if (m.ticks.length < 50) return;
    final xs = m.ticks
        .skip(max(0, m.ticks.length - 300))
        .map((t) => t.price)
        .toList();
    double ema(int period) {
      var v = xs.first;
      final k = 2 / (period + 1);
      for (final x in xs.skip(1)) {
        v += k * (x - v);
      }
      return v;
    }

    final a = ema(20), b = ema(50);
    m.trend = a > b
        ? 'UP'
        : a < b
        ? 'DOWN'
        : 'SIDEWAYS';
    var gain = 0.0, loss = 0.0, move = 0.0;
    for (var i = xs.length - 14; i < xs.length; i++) {
      final d = xs[i] - xs[i - 1];
      if (d > 0)
        gain += d;
      else
        loss -= d;
      move += d.abs();
    }
    m.rsi = loss == 0
        ? (gain == 0 ? 50.0 : 100.0)
        : 100 - 100 / (1 + gain / loss);
    m.macd = ema(12) - ema(26);
    m.movement = move / 14;
  }

  void _evaluate(Market m) {
    final evaluation = evaluateDigits(
      m.ticks.map((t) => t.lastDigit).toList(),
      mode,
      barrier,
    );
    m.logLoss = evaluation.logLoss;
    m.brier = evaluation.brierScore;
    m.model = evaluation.model;
    m.method = evaluation.model.name;
    m.testCount = evaluation.testCount;
    m.holdout = evaluation.testAccuracy * 100;
    m.baseline = evaluation.baselineAccuracy * 100;
    m.lastEvaluationSequence = m.tickSequence;
    m.evaluatedStrategy = strategy;
    m.evaluatedBarrier = barrier;
  }

  void _predict(Market m) {
    if (!ledgerReady ||
        !foreground ||
        !m.live ||
        m.forecast != null ||
        m.ticks.length < 250)
      return;
    if ((mode == PredictionMode.over && barrier == 9) ||
        (mode == PredictionMode.under && barrier == 0))
      return;
    if (needsEvaluation(m.tickSequence, m.lastEvaluationSequence) ||
        m.evaluatedStrategy != strategy ||
        m.evaluatedBarrier != barrier) {
      m.phase = 'Evaluating';
      _evaluate(m);
    }
    final probabilities = m.model.probabilities(
      m.ticks.map((t) => t.lastDigit).toList(),
    );
    final choice = chooseDigit(probabilities, mode, barrier);
    m.eligible++;
    if (choice.score < confidenceThreshold) {
      m.abstained++;
      m.phase = 'No signal: below score threshold';
      return;
    }
    m.forecast = ledger.issue(
      symbol: m.symbol,
      model: m.method,
      mode: mode,
      digit: choice.digit,
      sourceEpoch: m.ticks.last.epoch,
      sourceSequence: m.tickSequence,
      now: DateTime.now(),
      score: choice.score * 100,
    );
    m.phase = 'Forecast issued';
  }

  void _scan() {
    for (final m in markets) {
      _predict(m);
    }
    if (mounted) setState(() {});
  }

  List<SignalRecord> _filtered({String? symbol, String? mode}) => ledger
      .records
      .values
      .where(
        (r) =>
            (symbol == null || r.symbol == symbol) &&
            (mode == null || r.condition == mode) &&
            (r.observation == 'correct' || r.observation == 'incorrect'),
      )
      .toList()
      .reversed
      .toList();
  String _rate(List<SignalRecord> xs) => xs.isEmpty
      ? '—'
      : '${(100 * xs.where((r) => r.observation == 'correct').length / xs.length).toStringAsFixed(1)}%';
  void _cancelForecasts() {
    payoutInput.text = ledger.config.condition == modeLabel
        ? ledger.config.grossMultiplier.toString()
        : '';
    ledger.cancelForecasts('Condition changed');
    for (final m in markets) {
      m.forecast = null;
    }
  }

  void _refresh(VoidCallback change) => setState(change);
  Widget _card(Widget child) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: panel,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: blue.withValues(alpha: .45)),
    ),
    child: Material(type: MaterialType.transparency, child: child),
  );
  Widget _pill(String value, {Color color = cyan}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .15),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Text(
      value,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold),
    ),
  );
  Widget _metric(String value, String label) => Expanded(
    child: _card(
      Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.bold,
              color: cyan,
            ),
          ),
          Text(label, style: const TextStyle(fontSize: 10)),
        ],
      ),
    ),
  );
  Widget _marketCard(Market m) {
    final f = m.forecast;
    final condition = f == null
        ? 'WAITING'
        : switch (f.mode.index) {
            0 => 'MATCH ${f.digit}',
            1 => f.digit.isEven ? 'EVEN' : 'ODD',
            2 => 'OVER ${f.digit}',
            _ => 'UNDER ${f.digit}',
          };
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
                    fontSize: 17,
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
          Row(
            children: [
              Expanded(
                child: Text(
                  m.symbol,
                  style: const TextStyle(color: Colors.white60),
                ),
              ),
              IconButton(
                tooltip: 'Pin ${m.name}',
                onPressed: () {
                  setState(() {
                    if (!pinned.add(m.symbol)) pinned.remove(m.symbol);
                  });
                  _save();
                },
                icon: Icon(
                  pinned.contains(m.symbol)
                      ? Icons.push_pin
                      : Icons.push_pin_outlined,
                  color: pinned.contains(m.symbol) ? cyan : Colors.white60,
                ),
              ),
            ],
          ),
          Text(
            !m.live
                ? 'Feed unavailable'
                : m.ticks.length < 250
                ? 'Collecting data: ${m.ticks.length}/250 ticks'
                : f != null
                ? 'Forecast issued • expires in ${(f.config.expiryMs / 1000).toStringAsFixed(1)}s or next tick'
                : 'Ready • next scan in ${scanRemaining}s',
            style: const TextStyle(fontSize: 12, color: Colors.amber),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                width: 70,
                height: 70,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [blue, cyan]),
                ),
                child: Text(
                  f?.digit.toString() ?? '⌛',
                  style: const TextStyle(
                    fontSize: 33,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'NEXT TICK • $condition',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      f == null
                          ? 'Awaiting scan'
                          : 'Model score ${f.score.toStringAsFixed(1)}% (uncalibrated)',
                      style: const TextStyle(fontSize: 12, color: Colors.amber),
                    ),
                    if (!compact)
                      Text(
                        'Trend ${m.trend} • ${m.ticks.length} ticks',
                        style: const TextStyle(fontSize: 12),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (f != null)
            Text(
              'Issued ${f.issued.toLocal().toIso8601String().substring(11, 23)} • source tick ${f.sourceEpoch}',
              style: const TextStyle(fontSize: 11),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            children: m.ticks
                .skip(max(0, m.ticks.length - 12))
                .map(
                  (t) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: t.lastDigit == f?.digit ? blue : panel,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${t.lastDigit}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                )
                .toList(),
          ),
          if (!compact)
            Text(
              'Final test: ${m.testCount == 0 || m.evaluatedStrategy != strategy || m.evaluatedBarrier != barrier ? 'collecting' : '${m.holdout.toStringAsFixed(1)}% (${m.testCount} tests)'} • ${m.method}',
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
        ],
      ),
    );
  }

  Widget _radar() {
    final sample = _filtered(mode: modeLabel);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _pill(connection, color: data.connected ? green : Colors.orange),
            const Spacer(),
            Text('${markets.where((m) => m.live).length}/10 feeds'),
          ],
        ),
        if (!ledgerReady)
          _card(
            Text(
              storageError ?? 'Loading signal ledger…',
              style: const TextStyle(color: Colors.amber),
            ),
          ),
        const SizedBox(height: 15),
        const Text(
          'Volatility Predictions',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const Text(
          'Experimental NEXT-TICK digit forecasts',
          style: TextStyle(fontSize: 12, color: Colors.white70),
        ),
        Wrap(
          spacing: 6,
          children: List.generate(
            modes.length,
            (i) => ChoiceChip(
              label: Text(modes[i]),
              selected: strategy == i,
              onSelected: (_) => setState(() {
                strategy = i;
                _cancelForecasts();
              }),
            ),
          ),
        ),
        if (strategy >= 2)
          _card(
            DropdownButton<int>(
              value: barrier,
              isExpanded: true,
              items: List.generate(
                10,
                (d) => DropdownMenuItem(value: d, child: Text('Barrier $d')),
              ),
              onChanged: (v) {
                if (v != null)
                  setState(() {
                    barrier = v;
                    _cancelForecasts();
                  });
              },
            ),
          ),
        if ((strategy == 2 && barrier == 9) || (strategy == 3 && barrier == 0))
          const Text(
            'This barrier cannot win. Choose another barrier.',
            style: TextStyle(color: Colors.amber),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            _metric(_rate(sample), 'OBSERVED ACCURACY'),
            const SizedBox(width: 8),
            _metric('${sample.length}', 'OBSERVATIONS'),
          ],
        ),
        Row(
          children: [
            _metric('${markets.where((m) => m.live).length}', 'LIVE FEEDS'),
            const SizedBox(width: 8),
            _metric(
              '${markets.where((m) => m.forecast != null).length}',
              'PENDING',
            ),
          ],
        ),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$modeLabel Success Monitor',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 7),
              for (final n in [10, 50, 100, 300])
                Text(
                  'Last $n: ${_rate(sample.take(n).toList())} (${min(n, sample.length)} observations)',
                ),
              const SizedBox(height: 8),
              Text(
                'Uncalibrated scores. Uniform-digit baseline for this condition: ${(uniformBaseline(mode, barrier) * 100).toStringAsFixed(0)}%. Accuracy does not measure profit.',
                style: TextStyle(fontSize: 11, color: Colors.white60),
              ),
            ],
          ),
        ),
        Row(
          children: [
            const Text(
              'All markets',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            const Text('AUTO'),
            Switch(
              value: autoScan,
              onChanged: (v) {
                setState(() => autoScan = v);
                _save();
              },
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          children: [
            FilterChip(
              label: const Text('Compact'),
              selected: compact,
              onSelected: (v) {
                setState(() => compact = v);
                _save();
              },
            ),
            FilterChip(
              label: const Text('Ready markets only'),
              selected: readyOnly,
              onSelected: (v) {
                setState(() => readyOnly = v);
                _save();
              },
            ),
          ],
        ),
        ..._visibleMarkets().map(_marketCard),
      ],
    );
  }

  Widget _analyzer() {
    final m = market(selected);
    final evaluated =
        m.evaluatedStrategy == strategy && m.evaluatedBarrier == barrier;
    final counts = List<int>.generate(
      10,
      (d) => m.ticks.where((t) => t.lastDigit == d).length,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Expert Analyzer',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        _card(
          DropdownButton<String>(
            isExpanded: true,
            value: selected,
            items: markets
                .map(
                  (m) => DropdownMenuItem(value: m.symbol, child: Text(m.name)),
                )
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => selected = v);
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
                        fontSize: 19,
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
              Text(
                'Trend: ${m.trend}',
                style: const TextStyle(fontSize: 21, color: cyan),
              ),
              Text(
                'Last digit: ${m.lastDigit ?? '—'} • ${m.ticks.length} ticks',
              ),
              Text(
                'Tick RSI: ${m.rsi?.toStringAsFixed(1) ?? '—'} • MACD: ${m.macd?.toStringAsFixed(5) ?? '—'}',
              ),
              Text(
                'Mean tick movement: ${m.movement?.toStringAsFixed(5) ?? '—'}',
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 100,
                child: CustomPaint(
                  painter: SparkPainter(m.ticks.map((t) => t.price).toList()),
                  child: const SizedBox.expand(),
                ),
              ),
              const Text(
                'Tick chart; indicators are not closed-candle signals.',
                style: TextStyle(fontSize: 11, color: Colors.white60),
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
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              for (var d = 0; d < 10; d++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(width: 24, child: Text('$d')),
                      Expanded(
                        child: LinearProgressIndicator(
                          value: m.ticks.isEmpty
                              ? 0
                              : counts[d] / m.ticks.length,
                          minHeight: 8,
                          color: cyan,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        m.ticks.isEmpty
                            ? '—'
                            : '${(counts[d] * 100 / m.ticks.length).toStringAsFixed(1)}%',
                      ),
                    ],
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
                'Prediction / Validation',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              Text(
                'Forecast condition: ${m.forecast == null ? '—' : modes[m.forecast!.mode.index]} ${m.forecast?.digit ?? ''}',
              ),
              Text('Model: ${evaluated ? m.method : 'awaiting evaluation'}'),
              Text(
                'Estimate (uncalibrated): ${m.forecast == null ? '—' : '${m.forecast!.score.toStringAsFixed(1)}%'}',
              ),
              Text(
                'Final test accuracy: ${!evaluated || m.testCount == 0 ? '—' : '${m.holdout.toStringAsFixed(1)}%'}',
              ),
              Text(
                'Fixed training baseline: ${!evaluated || m.testCount == 0 ? '—' : '${m.baseline.toStringAsFixed(1)}%'}',
              ),
              Text(
                'Final historical test: ${evaluated ? m.testCount : 0} ticks',
              ),
              Text(
                'Digit log loss: ${m.logLoss.toStringAsFixed(3)} • Brier: ${m.brier.toStringAsFixed(3)}',
              ),
              const Text(
                'No demonstrated predictive edge',
                style: TextStyle(color: Colors.amber),
              ),
              Text(
                'Scan coverage (this run): ${m.eligible == 0 ? '—' : '${(100 * (m.eligible - m.abstained) / m.eligible).toStringAsFixed(1)}%'} • ${m.abstained} abstentions',
              ),
              Text(
                'Forward Matches: ${_rate(_filtered(symbol: m.symbol, mode: 'Matches'))}',
              ),
              const Text(
                'Models are selected on validation data before final testing. Rolling tests overlap; forward results are separate observations, not broker settlements.',
                style: TextStyle(fontSize: 11, color: Colors.white60),
              ),
            ],
          ),
        ),
        FilledButton(
          onPressed: () {
            _predict(m);
            setState(() {});
          },
          child: const Text('PREDICT NEXT TICK'),
        ),
      ],
    );
  }

  Widget _trades() => _paperDashboard();
  Widget _history() => _ledgerPage();
  Widget _journal() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Trading Journal',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
      ),
      Row(
        children: [
          _metric(
            '${_filtered(mode: modeLabel).length}',
            '$modeLabel OBSERVATIONS',
          ),
          const SizedBox(width: 8),
          _metric(_rate(_filtered(mode: modeLabel)), '$modeLabel ACCURACY'),
        ],
      ),
      _card(
        TextField(
          controller: journal,
          maxLines: 5,
          decoration: const InputDecoration(labelText: 'Your notes'),
        ),
      ),
      FilledButton(
        onPressed: () async {
          await _save();
          if (mounted)
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Saved locally')));
        },
        child: const Text('SAVE NOTE'),
      ),
    ],
  );
  Widget _alerts() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Alerts',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
      ),
      _card(
        SwitchListTile(
          title: const Text('In-app observation alerts'),
          value: notifications,
          onChanged: (v) {
            setState(() => notifications = v);
            _save();
          },
        ),
      ),
      ...alerts.map((a) => _card(Text(a))),
    ],
  );
  Widget _settings() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Settings',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
      ),
      _card(
        Column(
          children: [
            Text(
              'Minimum uncalibrated score: ${(confidenceThreshold * 100).toStringAsFixed(0)}%',
            ),
            Slider(
              value: confidenceThreshold,
              divisions: 100,
              onChanged: (v) {
                setState(() => confidenceThreshold = v);
                _save();
              },
            ),
            SwitchListTile(
              title: const Text('Automatic scanning'),
              value: autoScan,
              onChanged: (v) {
                setState(() => autoScan = v);
                _save();
              },
            ),
            SwitchListTile(
              title: const Text('In-app alerts'),
              value: notifications,
              onChanged: (v) {
                setState(() => notifications = v);
                _save();
              },
            ),
            const ListTile(
              title: Text('Connection'),
              subtitle: Text(
                'Deriv public Options WebSocket • automatic reconnect',
              ),
            ),
            const ListTile(
              title: Text('Trading mode'),
              subtitle: Text('Paper simulation • no broker orders'),
            ),
          ],
        ),
      ),
      FilledButton(
        onPressed: () {
          data.connect();
          setState(() => connection = 'CONNECTING');
        },
        child: const Text('RECONNECT MARKET FEED'),
      ),
    ],
  );
  Widget _diagnostics() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Connection Diagnostics',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
      ),
      _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Socket: $connection'),
            const Text('Account: PUBLIC DATA ONLY'),
            Text('Ticks received: $tickCount'),
            Text('Feeds live: ${markets.where((m) => m.live).length}/10'),
            Text('Scan countdown: ${scanRemaining}s'),
            const Text(
              'No PAT or account token is sent to the public endpoint.',
            ),
          ],
        ),
      ),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => data.connect(),
              child: const Text('RECONNECT'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              onPressed: () => setState(() => logs.clear()),
              child: const Text('CLEAR LOG'),
            ),
          ),
        ],
      ),
      ...logs
          .take(100)
          .map(
            (line) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: SelectableText(
                line,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final pages = [
      _radar,
      _analyzer,
      _trades,
      _history,
      _journal,
      _alerts,
      _settings,
      _diagnostics,
    ];
    const names = [
      'Radar',
      'Analyzer',
      'Paper',
      'Ledger',
      'Journal',
      'Alerts',
      'Settings',
      'Logs',
    ];
    const icons = [
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
              'Volatility Scanner',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),
            Text(
              'Deriv • Experimental market scanner',
              style: TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Center(child: _pill('PUBLIC DATA', color: green)),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          key: ValueKey(tab),
          padding: const EdgeInsets.all(14),
          children: [pages[tab]()],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Material(
          color: panel,
          child: SizedBox(
            height: 69,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: names.length,
              itemBuilder: (context, i) => InkWell(
                onTap: () => setState(() => tab = i),
                child: Container(
                  width: max(66.0, MediaQuery.sizeOf(context).width / 6.2),
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(
                    color: tab == i
                        ? blue.withValues(alpha: .2)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        icons[i],
                        size: 22,
                        color: tab == i ? cyan : Colors.white70,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        names[i],
                        style: TextStyle(
                          fontSize: 10,
                          color: tab == i ? cyan : Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) ledger.interrupt('App left foreground');
    for (final m in markets) {
      m.forecast = null;
      m.lastSeen = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ledger.interrupt('App closed');
    WidgetsBinding.instance.removeObserver(this);
    clock?.cancel();
    for (final s in subscriptions) {
      s.cancel();
    }
    data.dispose();
    journal.dispose();
    for (final c in [
      stakeInput,
      payoutInput,
      delayInput,
      durationInput,
      expiryInput,
    ]) {
      c.dispose();
    }
    super.dispose();
  }
}

class SparkPainter extends CustomPainter {
  final List<double> values;
  SparkPainter(this.values);
  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final a = values.length > 80 ? values.sublist(values.length - 80) : values;
    final lo = a.reduce(min), hi = a.reduce(max), range = max(hi - lo, .00001);
    final path = Path();
    for (var i = 0; i < a.length; i++) {
      final x = i * size.width / (a.length - 1),
          y = size.height - (a[i] - lo) / range * size.height;
      if (i == 0)
        path.moveTo(x, y);
      else
        path.lineTo(x, y);
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
