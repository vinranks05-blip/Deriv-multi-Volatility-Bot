import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

abstract class LedgerStorage {
  Future<List<Map<String, dynamic>>> read();
  Future<void> append(Map<String, dynamic> event);
  Future<void> flush();
}

class FileLedgerStorage implements LedgerStorage {
  FileLedgerStorage({File? location}) {
    if (location != null) _file = Future.value(location);
  }
  Future<File>? _file;
  Future<void> _queue = Future.value();
  Future<File> get file => _file ??= getApplicationSupportDirectory()
      .then((dir) => File('${dir.path}/signal-ledger-v1.jsonl'));
  @override
  Future<List<Map<String, dynamic>>> read() async {
    final f = await file;
    if (!await f.exists()) return [];
    final content = await f.readAsString();
    final lines = content.split('\n');
    final events = <Map<String, dynamic>>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim().isEmpty) continue;
      try {
        events.add(Map<String, dynamic>.from(jsonDecode(lines[i])));
      } on FormatException {
        // A power loss may leave only the final append incomplete. Preserve the
        // original before repairing; corruption inside the file fails closed.
        if (i != lines.length - 1 || content.endsWith('\n')) rethrow;
        await f.copy(
            '${f.path}.recovered-${DateTime.now().microsecondsSinceEpoch}');
        await f.writeAsString('${lines.take(i).join('\n')}\n', flush: true);
      }
    }
    if (content.isNotEmpty &&
        !content.endsWith('\n') &&
        events.length == lines.length) {
      await f.writeAsString('\n', mode: FileMode.append, flush: true);
    }
    return events;
  }

  @override
  Future<void> append(Map<String, dynamic> event) {
    final line = '${jsonEncode(event)}\n';
    _queue = _queue.then((_) async {
      final f = await file;
      await f.parent.create(recursive: true);
      await f.writeAsString(line, mode: FileMode.append, flush: true);
    });
    return _queue;
  }

  @override
  Future<void> flush() => _queue;
}

class MemoryLedgerStorage implements LedgerStorage {
  final List<Map<String, dynamic>> events = [];
  @override
  Future<List<Map<String, dynamic>>> read() async => List.of(events);
  @override
  Future<void> append(Map<String, dynamic> event) async {
    events.add(Map<String, dynamic>.from(jsonDecode(jsonEncode(event))));
  }

  @override
  Future<void> flush() async {}
}
