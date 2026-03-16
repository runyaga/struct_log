import 'dart:convert';
import 'dart:io';

import 'package:struct_log/src/log_record.dart';
import 'package:struct_log/src/log_sink.dart';

/// NDJSON file sink for structured telemetry output.
///
/// Writes one JSON object per line (newline-delimited JSON) to a file.
/// Append-only, buffered via Dart's [IOSink]. Each [LogRecord] is
/// serialized to a compact JSON line immediately on [write], with
/// actual I/O deferred to the OS-level buffer.
///
/// Record format:
/// ```json
/// {"ts":"2026-03-13T06:05:57.315Z","level":"INFO","logger":"bridge","msg":"tool_call_start","spanId":"worker-3","traceId":"E106-run-1","attr":{"tool":"runner_exec"}}
/// ```
class JsonFileSink implements LogSink {
  /// Creates a sink that writes NDJSON to [filePath].
  ///
  /// Opens the file in append mode. If the file does not exist, it is
  /// created. If it already exists, new records are appended.
  JsonFileSink(this.filePath)
      : _ioSink = File(filePath).openWrite(mode: FileMode.append);

  /// Creates a sink with an injected [IOSink] for testing.
  JsonFileSink.fromIOSink(this.filePath, this._ioSink);

  /// Path to the output file.
  final String filePath;

  final IOSink _ioSink;

  bool _closed = false;

  /// Number of records written.
  int recordCount = 0;

  @override
  void write(LogRecord record) {
    if (_closed) return;
    try {
      final map = _recordToMap(record);
      _ioSink.writeln(jsonEncode(map));
      recordCount++;
    } on Object catch (_) {
      // Non-fatal: telemetry must never crash the host.
    }
  }

  @override
  Future<void> flush() async {
    if (_closed) return;
    await _ioSink.flush();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _ioSink.flush();
    await _ioSink.close();
  }

  static Map<String, Object?> _recordToMap(LogRecord record) {
    final map = <String, Object?>{
      'ts': record.timestamp.toUtc().toIso8601String(),
      'level': record.level.label,
      'logger': record.loggerName,
      'msg': record.message,
    };

    if (record.spanId != null) map['spanId'] = record.spanId;
    if (record.traceId != null) map['traceId'] = record.traceId;
    if (record.attributes.isNotEmpty) map['attr'] = record.attributes;
    if (record.error != null) map['error'] = record.error.toString();
    if (record.stackTrace != null) {
      map['stackTrace'] = record.stackTrace.toString();
    }

    return map;
  }
}
