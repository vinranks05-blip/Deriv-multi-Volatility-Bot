import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Public market-data service for V13. No account token or trade execution.
/// Uses the documented Deriv public Options WebSocket API.
class V13Tick {
  final String symbol;
  final double price;
  final int epoch;
  final int pipSize;
  const V13Tick(this.symbol, this.price, this.epoch, this.pipSize);
  int get lastDigit {
    final formatted = price.toStringAsFixed(pipSize);
    return int.parse(formatted[formatted.length - 1]);
  }
}

class V13MarketData {
  V13MarketData(
      {this.url = 'wss://api.derivws.com/trading/v1/options/ws/public'});
  final String url;
  final _ticks = StreamController<V13Tick>.broadcast();
  final _historyUpdates = StreamController<String>.broadcast();
  final _symbols = StreamController<Map<String, String>>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final Map<String, List<V13Tick>> history = {};
  final Map<String, int> pipSizes = {};
  final Set<String> selectedSymbols = {};
  WebSocketChannel? _socket;
  StreamSubscription? _socketSubscription;
  Timer? _heartbeat;
  Timer? _retry;
  bool _disposed = false;
  int _attempt = 0;
  int _generation = 0;
  bool _connecting = false;
  bool connected = false;

  Stream<V13Tick> get ticks => _ticks.stream;
  Stream<String> get historyUpdates => _historyUpdates.stream;
  Stream<Map<String, String>> get symbols => _symbols.stream;
  Stream<String> get errors => _errors.stream;

  Future<void> connect() async {
    if (_disposed || _connecting) return;
    _connecting = true;
    _retry?.cancel();
    final generation = ++_generation;
    await _socketSubscription?.cancel();
    _heartbeat?.cancel();
    try {
      await _socket?.sink.close();
    } catch (_) {}
    connected = false;
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      _socket = channel;
      await channel.ready.timeout(const Duration(seconds: 15));
      if (_disposed || generation != _generation) {
        await channel.sink.close();
        _connecting = false;
        return;
      }
      connected = true;
      _connecting = false;
      _attempt = 0;
      _socketSubscription = channel.stream.listen(_handle,
          onError: (Object error) => _disconnected(generation, '$error'),
          onDone: () => _disconnected(generation, 'WebSocket closed'),
          cancelOnError: true);
      _send({'active_symbols': 'brief'});
      for (final symbol in selectedSymbols) {
        _subscribe(symbol);
      }
      _heartbeat = Timer.periodic(
          const Duration(seconds: 25), (_) => _send({'ping': 1}));
    } catch (e) {
      _connecting = false;
      _disconnected(generation, '$e');
    }
  }

  void watch(String symbol) {
    if (!RegExp(r'^\w{2,30}$').hasMatch(symbol)) {
      throw ArgumentError.value(symbol, 'symbol', 'Invalid Deriv symbol');
    }
    if (selectedSymbols.add(symbol) && connected) _subscribe(symbol);
  }

  void _subscribe(String symbol) {
    _send({
      'ticks_history': symbol,
      'count': 1000,
      'end': 'latest',
      'style': 'ticks',
      'req_id': 7000 + selectedSymbols.toList().indexOf(symbol)
    });
    _send({'ticks': symbol, 'subscribe': 1});
  }

  void _send(Map<String, Object> message) {
    if (!connected) return;
    try {
      _socket?.sink.add(jsonEncode(message));
    } catch (e) {
      _errors.add('Send failed: $e');
    }
  }

  void _handle(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      if (data['error'] != null) {
        _errors.add('Deriv: ${data['error']['message']}');
        return;
      }
      switch (data['msg_type']) {
        case 'active_symbols':
          final found = <String, String>{};
          for (final entry in (data['active_symbols'] as List? ?? [])) {
            if (entry is! Map) continue;
            final code = (entry['symbol'] ?? entry['underlying_symbol'] ?? '')
                .toString();
            final name = (entry['display_name'] ?? code).toString();
            if (code.isNotEmpty &&
                (name.toLowerCase().contains('volatility') ||
                    RegExp(r'^(R_\d+|1HZ\d+V)$').hasMatch(code))) {
              found[code] = name;
            }
            final pip = entry['pip_size'];
            if (pip is num && code.isNotEmpty) pipSizes[code] = pip.toInt();
          }
          _symbols.add(found);
          break;
        case 'history':
          final symbol = (data['echo_req']?['ticks_history'] ?? '').toString();
          if (symbol.isEmpty) return;
          final prices = data['history']?['prices'] as List? ?? [];
          final times = data['history']?['times'] as List? ?? [];
          final pip =
              (data['pip_size'] as num?)?.toInt() ?? pipSizes[symbol] ?? 2;
          pipSizes[symbol] = pip;
          final buffer = <V13Tick>[];
          for (var i = 0; i < min(prices.length, times.length); i++) {
            final p = num.tryParse('${prices[i]}');
            final t = num.tryParse('${times[i]}');
            if (p != null && t != null)
              buffer.add(V13Tick(symbol, p.toDouble(), t.toInt(), pip));
          }
          final existing = history[symbol] ?? <V13Tick>[];
          // Preserve live ticks received while the history request was in flight.
          final merged = <V13Tick>[...buffer, ...existing];
          merged.sort((a, b) => a.epoch.compareTo(b.epoch));
          final unique = <V13Tick>[];
          for (final tick in merged) {
            if (unique.isEmpty ||
                unique.last.epoch != tick.epoch ||
                unique.last.price != tick.price) {
              unique.add(tick);
            }
          }
          history[symbol] = unique.length > 5000
              ? unique.sublist(unique.length - 5000)
              : unique;
          _historyUpdates.add(symbol);
          break;
        case 'tick':
          final tick = data['tick'];
          if (tick is! Map) return;
          final symbol = (tick['symbol'] ?? '').toString();
          final p = num.tryParse('${tick['quote']}');
          final t = num.tryParse('${tick['epoch']}');
          if (symbol.isEmpty || p == null || t == null) return;
          final pip =
              (tick['pip_size'] as num?)?.toInt() ?? pipSizes[symbol] ?? 2;
          pipSizes[symbol] = pip;
          final item = V13Tick(symbol, p.toDouble(), t.toInt(), pip);
          final buffer = history.putIfAbsent(symbol, () => []);
          if (buffer.isEmpty ||
              (item.epoch >= buffer.last.epoch &&
                  (buffer.last.epoch != item.epoch ||
                      buffer.last.price != item.price))) {
            buffer.add(item);
            if (buffer.length > 5000)
              buffer.removeRange(0, buffer.length - 5000);
            _ticks.add(item);
          }
          break;
      }
    } catch (e) {
      _errors.add('Parse error: $e');
    }
  }

  /// Observed digit frequencies, not a forecast or a win probability.
  Map<int, double> digitFrequencies(String symbol, {int sample = 1000}) {
    final all = history[symbol] ?? [];
    final ticks = all.skip(max(0, all.length - sample)).toList();
    final counts = List<int>.filled(10, 0);
    for (final tick in ticks) {
      counts[tick.lastDigit]++;
    }
    return {
      for (var d = 0; d < 10; d++)
        d: ticks.isEmpty ? 0.0 : counts[d] / ticks.length
    };
  }

  void _disconnected(int generation, String reason) {
    if (_disposed || generation != _generation) return;
    connected = false;
    _connecting = false;
    _heartbeat?.cancel();
    _errors.add(reason);
    _retry?.cancel();
    final delay = min(60, 1 << min(_attempt++, 6));
    _retry = Timer(Duration(seconds: delay), connect);
  }

  Future<void> dispose() async {
    _disposed = true;
    ++_generation;
    _retry?.cancel();
    _heartbeat?.cancel();
    await _socketSubscription?.cancel();
    try {
      await _socket?.sink.close();
    } catch (_) {}
    await _ticks.close();
    await _historyUpdates.close();
    await _symbols.close();
    await _errors.close();
  }
}
