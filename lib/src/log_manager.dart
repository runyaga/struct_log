import 'dart:developer' as developer;

import 'package:struct_log/src/log_level.dart';
import 'package:struct_log/src/log_record.dart';
import 'package:struct_log/src/log_sink.dart';

/// Manager for log sinks and configuration.
///
/// Use [instance] for the global singleton (production use).
/// Use [LogManager.scoped] for independent instances (test isolation).
final class LogManager {
  LogManager._();

  /// Creates an independent [LogManager] not connected to the singleton.
  ///
  /// Scoped managers have their own sink list and minimum level, so tests
  /// can run concurrently without cross-talk. Loggers obtained via
  /// `getLogger` on a scoped manager emit only to that manager's sinks.
  ///
  /// ```dart
  /// final manager = LogManager.scoped();
  /// final sink = MemorySink();
  /// manager
  ///   ..addSink(sink)
  ///   ..minimumLevel = LogLevel.trace;
  /// final logger = manager.getLogger('Test');
  /// logger.info('only goes to this manager');
  /// ```
  LogManager.scoped() : this._();

  /// The global singleton instance.
  static final LogManager instance = LogManager._();

  final List<LogSink> _sinks = [];

  /// Minimum log level. Logs below this level are filtered out.
  LogLevel minimumLevel = LogLevel.info;

  /// Adds a sink to receive log records.
  void addSink(LogSink sink) {
    if (!_sinks.contains(sink)) {
      _sinks.add(sink);
    }
  }

  /// Removes a sink.
  void removeSink(LogSink sink) {
    _sinks.remove(sink);
  }

  /// Returns all registered sinks.
  List<LogSink> get sinks => List.unmodifiable(_sinks);

  /// Emits a log record to all sinks.
  ///
  /// Sink failures are caught and printed to stderr to prevent a faulty sink
  /// from crashing the application or blocking other sinks.
  void emit(LogRecord record) {
    for (final sink in _sinks) {
      try {
        sink.write(record);
      } on Object catch (e) {
        developer.log('Sink failed to write: $e', name: 'LogManager');
      }
    }
  }

  /// Flushes all sinks.
  Future<void> flush() async {
    await Future.wait(_sinks.map((s) => s.flush()));
  }

  /// Closes all sinks.
  ///
  /// Clears the sink list before awaiting close to prevent new writes
  /// from reaching sinks that are in the process of shutting down.
  Future<void> close() async {
    final sinksToClose = List<LogSink>.of(_sinks);
    _sinks.clear();
    await Future.wait(sinksToClose.map((s) => s.close()));
  }

  /// Resets the manager for testing.
  void reset() {
    _sinks.clear();
    minimumLevel = LogLevel.info;
  }
}
