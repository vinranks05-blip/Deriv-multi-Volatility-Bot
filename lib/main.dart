
class DerivClient {
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _heartbeat;

  int _req = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  bool get connected => _channel != null;

  Future<void> connect(String appId) async {
    await close();

    final channel = WebSocketChannel.connect(
      Uri.parse(
        'wss://api.derivws.com/trading/v1/options/ws/public',
      ),
    );

    try {
      await channel.ready.timeout(const Duration(seconds: 15));
    } catch (_) {
      await channel.sink.close();
      rethrow;
    }

    _channel = channel;

    _sub = channel.stream.listen(
      (event) {
        try {
          final msg = jsonDecode(event as String)
              as Map<String, dynamic>;

          final id = msg['req_id'];
          final c = _pending.remove(id);

          if (c != null && !c.isCompleted) {
            if (msg['error'] != null) {
              c.completeError(
                StateError(msg['error'].toString()),
              );
            } else {
              c.complete(msg);
            }
          }
        } catch (e) {
          _failAll(e);
        }
      },
      onError: (Object e) {
        _channel = null;
        _heartbeat?.cancel();
        _failAll(e);
      },
      onDone: () {
        _channel = null;
        _heartbeat?.cancel();
        _failAll(StateError('WebSocket disconnected'));
      },
      cancelOnError: true,
    );

    _heartbeat = Timer.periodic(
      const Duration(seconds: 20),
      (_) {
        if (_channel != null) {
          _channel!.sink.add(jsonEncode({'ping': 1}));
        }
      },
    );
  }

  void _failAll(Object e) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(e);
    }
    _pending.clear();
  }

  Future<Map<String, dynamic>> call(
    Map<String, dynamic> payload,
  ) async {
    if (_channel == null) {
      throw StateError('Not connected');
    }

    final id = ++_req;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;

    try {
      _channel!.sink.add(
        jsonEncode({...payload, 'req_id': id}),
      );

      return await c.future.timeout(
        const Duration(seconds: 20),
      );
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> close() async {
    _heartbeat?.cancel();
    _heartbeat = null;

    await _sub?.cancel();
    _sub = null;

    final channel = _channel;
    _channel = null;

    await channel?.sink.close();

    _failAll(StateError('Connection closed'));
  }
}
