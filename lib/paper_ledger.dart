import 'dart:math';
import 'prediction_engine.dart';

String conditionLabel(PredictionMode mode, int digit) => switch (mode) {
      PredictionMode.matches => 'Matches',
      PredictionMode.evenOdd => 'Even/Odd',
      PredictionMode.over => 'Over $digit',
      PredictionMode.under => 'Under $digit',
    };

String signalLabel(PredictionMode mode, int digit) => switch (mode) {
      PredictionMode.matches => 'MATCH $digit',
      PredictionMode.evenOdd => digit.isEven ? 'EVEN' : 'ODD',
      PredictionMode.over => 'OVER $digit',
      PredictionMode.under => 'UNDER $digit',
    };

class PaperConfig {
  final double stake, grossMultiplier;
  final int delayMs, durationTicks, expiryMs;
  final String condition, symbol;
  const PaperConfig(
      {this.stake = .35,
      this.grossMultiplier = 9.24,
      this.delayMs = 1000,
      this.durationTicks = 1,
      this.expiryMs = 5000,
      this.condition = 'Matches',
      this.symbol = 'R_25'});
  void validate() {
    if (!stake.isFinite ||
        stake <= 0 ||
        !grossMultiplier.isFinite ||
        grossMultiplier <= 1 ||
        delayMs < 0 ||
        delayMs > 30000 ||
        expiryMs < 1 ||
        expiryMs > 60000 ||
        delayMs >= expiryMs ||
        durationTicks < 1 ||
        durationTicks > 100) {
      throw ArgumentError(
          'Use positive stake, gross return > 1, delay shorter than expiry, and 1–100 ticks.');
    }
  }

  Map<String, dynamic> toJson() => {
        'stake': stake,
        'grossMultiplier': grossMultiplier,
        'delayMs': delayMs,
        'durationTicks': durationTicks,
        'expiryMs': expiryMs,
        'condition': condition,
        'symbol': symbol
      };
  factory PaperConfig.fromJson(Map<String, dynamic> j) => PaperConfig(
      stake: (j['stake'] as num).toDouble(),
      grossMultiplier: (j['grossMultiplier'] as num).toDouble(),
      delayMs: j['delayMs'],
      durationTicks: j['durationTicks'],
      expiryMs: j['expiryMs'],
      condition: j['condition'],
      symbol: j['symbol']);
}

class SignalRecord {
  final String id, symbol, model;
  final PredictionMode mode;
  final int digit, sourceEpoch, sourceSequence;
  final DateTime issued;
  final double score;
  final PaperConfig config;
  String observation = 'pending', paper = 'skipped', reason = '';
  int? actual, observationEpoch, entryEpoch, exitEpoch, exitDigit;
  DateTime? entryAt, exitAt;
  int elapsedTicks = 0;
  double? entryPrice, exitPrice, profit;
  SignalRecord(
      {required this.id,
      required this.symbol,
      required this.model,
      required this.mode,
      required this.digit,
      required this.sourceEpoch,
      required this.sourceSequence,
      required this.issued,
      required this.score,
      required this.config});
  String get condition => conditionLabel(mode, digit);
  String get label => signalLabel(mode, digit);
  double get baseline => uniformBaseline(mode, digit);
  bool get active =>
      observation == 'pending' || paper == 'waiting' || paper == 'open';
  Map<String, dynamic> toJson() => {
        'id': id,
        'symbol': symbol,
        'model': model,
        'mode': mode.index,
        'digit': digit,
        'sourceEpoch': sourceEpoch,
        'sourceSequence': sourceSequence,
        'issued': issued.toUtc().toIso8601String(),
        'score': score,
        'config': config.toJson(),
        'observation': observation,
        'paper': paper,
        'reason': reason,
        'actual': actual,
        'observationEpoch': observationEpoch,
        'entryEpoch': entryEpoch,
        'exitEpoch': exitEpoch,
        'entryAt': entryAt?.toUtc().toIso8601String(),
        'exitAt': exitAt?.toUtc().toIso8601String(),
        'elapsedTicks': elapsedTicks,
        'entryPrice': entryPrice,
        'exitPrice': exitPrice,
        'exitDigit': exitDigit,
        'profit': profit
      };
  factory SignalRecord.fromJson(Map<String, dynamic> j) {
    final r = SignalRecord(
        id: j['id'],
        symbol: j['symbol'],
        model: j['model'],
        mode: PredictionMode.values[j['mode']],
        digit: j['digit'],
        sourceEpoch: j['sourceEpoch'],
        sourceSequence: j['sourceSequence'],
        issued: DateTime.parse(j['issued']),
        score: (j['score'] as num).toDouble(),
        config: PaperConfig.fromJson(Map<String, dynamic>.from(j['config'])));
    r.observation = j['observation'];
    r.paper = j['paper'];
    r.reason = j['reason'];
    r.actual = j['actual'];
    r.observationEpoch = j['observationEpoch'];
    r.entryEpoch = j['entryEpoch'];
    r.exitEpoch = j['exitEpoch'];
    r.exitDigit = j['exitDigit'];
    r.elapsedTicks = j['elapsedTicks'];
    r.entryAt = j['entryAt'] == null ? null : DateTime.parse(j['entryAt']);
    r.exitAt = j['exitAt'] == null ? null : DateTime.parse(j['exitAt']);
    r.entryPrice = (j['entryPrice'] as num?)?.toDouble();
    r.exitPrice = (j['exitPrice'] as num?)?.toDouble();
    r.profit = (j['profit'] as num?)?.toDouble();
    return r;
  }
}

class PaperLedger {
  final void Function(Map<String, dynamic>) onEvent;
  final Map<String, SignalRecord> records = {};
  final Map<String, SignalRecord> _active = {};
  double initialBalance;
  bool enabled = false;
  PaperConfig config = const PaperConfig();
  int _sequence = 0;
  final Map<String, int> _lastSequences = {};
  PaperLedger({required this.onEvent, this.initialBalance = 100});
  Iterable<SignalRecord> get active => _active.values.toList();
  double get realized =>
      records.values.fold(0.0, (v, r) => v + (r.profit ?? 0));
  double get reserved => records.values
      .where((r) =>
          r.paper == 'waiting' || r.paper == 'open' || r.paper == 'unresolved')
      .fold(0.0, (v, r) => v + r.config.stake);
  double get available => initialBalance + realized - reserved;
  void _emit(SignalRecord r) {
    if (r.active) {
      _active[r.id] = r;
    } else {
      _active.remove(r.id);
    }
    onEvent({'type': 'signal', 'record': r.toJson()});
  }

  void restore(List<Map<String, dynamic>> events) {
    for (final event in events) {
      if (event['type'] == 'signal') {
        final r =
            SignalRecord.fromJson(Map<String, dynamic>.from(event['record']));
        records[r.id] = r;
      }
    }
    _active.clear();
    _active.addEntries(records.entries.where((e) => e.value.active));
    // Never settle contracts across a missing feed or a process restart.
    interrupt('App restarted');
  }

  SignalRecord issue(
      {required String symbol,
      required String model,
      required PredictionMode mode,
      required int digit,
      required int sourceEpoch,
      required int sourceSequence,
      required DateTime now,
      required double score}) {
    final r = SignalRecord(
        id: '${now.toUtc().microsecondsSinceEpoch}-${_sequence++}',
        symbol: symbol,
        model: model,
        mode: mode,
        digit: digit,
        sourceEpoch: sourceEpoch,
        sourceSequence: sourceSequence,
        issued: now.toUtc(),
        score: score,
        config: config);
    if (!enabled) {
      r.reason = 'Paper trading disabled';
    } else if (r.symbol != config.symbol) {
      r.reason = 'Not the selected paper market';
    } else if (r.condition != config.condition) {
      r.reason = 'No payout assumption configured for ${r.condition}';
    } else if (reserved > 0) {
      r.reason = 'Another paper trade is active or unresolved';
    } else if (available < config.stake) {
      r.reason = 'Insufficient paper balance';
    } else {
      config.validate();
      r.paper = 'waiting';
    }
    records[r.id] = r;
    _emit(r);
    return r;
  }

  void tick(
      {required String symbol,
      required int epoch,
      required int sequence,
      required double price,
      required int digit,
      required DateTime now}) {
    if (sequence <= (_lastSequences[symbol] ?? -1)) return;
    _lastSequences[symbol] = sequence;
    expire(now);
    for (final r in active.where((r) => r.symbol == symbol)) {
      if (sequence <= r.sourceSequence || epoch < r.sourceEpoch) continue;
      var changed = false;
      if (r.observation == 'pending') {
        r.actual = digit;
        r.observationEpoch = epoch;
        r.observation =
            digitWins(r.mode, r.digit, digit) ? 'correct' : 'incorrect';
        changed = true;
      }
      if (r.paper == 'waiting' &&
          now.difference(r.issued).inMilliseconds >= r.config.delayMs) {
        // Entry uses the first live tick AFTER the delay; duration starts here.
        // Even for 1 tick, settlement requires another subsequent live tick.
        r.paper = 'open';
        r.entryEpoch = epoch;
        r.entryAt = now.toUtc();
        r.entryPrice = price;
        changed = true;
      } else if (r.paper == 'open') {
        r.elapsedTicks++;
        changed = true;
        if (r.elapsedTicks >= r.config.durationTicks) {
          r.exitEpoch = epoch;
          r.exitAt = now.toUtc();
          r.exitPrice = price;
          r.exitDigit = digit;
          final win = digitWins(r.mode, r.digit, digit);
          r.paper = win ? 'won' : 'lost';
          r.profit = win
              ? r.config.stake * (r.config.grossMultiplier - 1)
              : -r.config.stake;
        }
      }
      if (changed) _emit(r);
    }
  }

  void expire(DateTime now) {
    for (final r in active) {
      if (now.difference(r.issued).inMilliseconds < r.config.expiryMs) continue;
      var changed = false;
      if (r.observation == 'pending') {
        r.observation = 'expired';
        changed = true;
      }
      if (r.paper == 'waiting') {
        r.paper = 'expired';
        r.reason = 'Entry window elapsed';
        changed = true;
      }
      if (changed) _emit(r);
    }
  }

  void interrupt(String reason, {String? symbol}) {
    for (final r in active.where((r) => symbol == null || r.symbol == symbol)) {
      if (r.observation == 'pending') r.observation = 'missed';
      if (r.paper == 'waiting') r.paper = 'cancelled';
      // Retain the stake as reserved; an unknown outcome is never a refund.
      if (r.paper == 'open') r.paper = 'unresolved';
      r.reason = reason;
      _emit(r);
    }
  }

  void stopEntries() {
    enabled = false;
    for (final r in active.where((r) => r.paper == 'waiting')) {
      r.paper = 'cancelled';
      r.reason = 'Paper entries stopped';
      _emit(r);
    }
  }

  void cancelForecasts(String reason) {
    for (final r in active.where((r) => r.observation == 'pending')) {
      r.observation = 'cancelled';
      if (r.paper == 'waiting') r.paper = 'cancelled';
      r.reason = reason;
      _emit(r);
    }
  }

  void resolveUncertainLoss(String id, DateTime now) {
    final r = records[id];
    if (r == null || r.paper != 'unresolved') return;
    r.paper = 'assumed_lost';
    r.profit = -r.config.stake;
    r.exitAt = now.toUtc();
    r.reason =
        'User booked full paper stake as loss; settlement was not observed';
    _emit(r);
  }

  String csv() {
    String cell(Object? v) => '"${(v ?? '').toString().replaceAll('"', '""')}"';
    const columns = [
      'id',
      'symbol',
      'mode',
      'condition',
      'model',
      'issued_utc',
      'source_epoch',
      'source_sequence',
      'score_uncalibrated_pct',
      'uniform_baseline_pct',
      'observation',
      'actual_digit',
      'observation_epoch',
      'paper_status',
      'reason',
      'stake',
      'assumed_gross_multiplier',
      'configured_paper_condition',
      'configured_paper_symbol',
      'delay_ms',
      'duration_ticks',
      'expiry_ms',
      'entry_utc',
      'entry_epoch',
      'entry_price',
      'exit_utc',
      'exit_epoch',
      'exit_price',
      'exit_digit',
      'simulated_profit'
    ];
    final lines = [columns.map(cell).join(',')];
    for (final r in records.values) {
      lines.add([
        r.id,
        r.symbol,
        predictionLabels[r.mode.index],
        r.label,
        r.model,
        r.issued.toIso8601String(),
        r.sourceEpoch,
        r.sourceSequence,
        r.score,
        r.baseline * 100,
        r.observation,
        r.actual,
        r.observationEpoch,
        r.paper,
        r.reason,
        r.config.stake,
        r.config.grossMultiplier,
        r.config.condition,
        r.config.symbol,
        r.config.delayMs,
        r.config.durationTicks,
        r.config.expiryMs,
        r.entryAt?.toIso8601String(),
        r.entryEpoch,
        r.entryPrice,
        r.exitAt?.toIso8601String(),
        r.exitEpoch,
        r.exitPrice,
        r.exitDigit,
        r.profit
      ].map(cell).join(','));
    }
    return '${lines.join('\r\n')}\r\n';
  }
}

class LedgerStats {
  final List<SignalRecord> records;
  LedgerStats(Iterable<SignalRecord> source) : records = source.toList();
  List<SignalRecord> get observed => records
      .where((r) => r.observation == 'correct' || r.observation == 'incorrect')
      .toList();
  List<SignalRecord> get settled =>
      records.where((r) => r.profit != null).toList()
        ..sort((a, b) => a.exitAt!.compareTo(b.exitAt!));
  double? get accuracy => observed.isEmpty
      ? null
      : observed.where((r) => r.observation == 'correct').length /
          observed.length;
  double get profit => settled.fold(0.0, (v, r) => v + r.profit!);
  double get drawdown {
    var equity = 0.0, peak = 0.0, dd = 0.0;
    for (final r in settled) {
      equity += r.profit!;
      peak = max(peak, equity);
      dd = max(dd, peak - equity);
    }
    return dd;
  }

  // Approximate Wilson interval; shared ticks and overlapping trades are dependent.
  (double, double)? get interval {
    final p = accuracy;
    if (p == null) return null;
    final n = observed.length, z = 1.96, z2 = z * z;
    final center = (p + z2 / (2 * n)) / (1 + z2 / n);
    final radius = z * sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / (1 + z2 / n);
    return (max(0, center - radius), min(1, center + radius));
  }
}
