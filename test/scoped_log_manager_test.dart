import 'package:struct_log/struct_log.dart';
import 'package:test/test.dart';

/// A test sink that tracks calls.
class TestSink implements LogSink {
  final List<LogRecord> records = [];
  int flushCount = 0;
  bool closed = false;

  @override
  void write(LogRecord record) {
    records.add(record);
  }

  @override
  Future<void> flush() async {
    flushCount++;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  group('LogManager.scoped', () {
    test('returns a new instance each time', () {
      final a = LogManager.scoped();
      final b = LogManager.scoped();

      expect(a, isNot(same(b)));
    });

    test('is not the singleton', () {
      final scoped = LogManager.scoped();

      expect(scoped, isNot(same(LogManager.instance)));
    });

    test('has independent sink list', () {
      final scoped = LogManager.scoped()..addSink(TestSink());

      expect(scoped.sinks, hasLength(1));
      expect(LogManager.instance.sinks, isEmpty);
    });

    test('has independent minimum level', () {
      final scoped = LogManager.scoped()..minimumLevel = LogLevel.trace;

      expect(scoped.minimumLevel, LogLevel.trace);
      expect(LogManager.instance.minimumLevel, LogLevel.info);
    });

    test('emit only reaches own sinks', () {
      final scopedSink = TestSink();
      final scoped = LogManager.scoped()..addSink(scopedSink);

      // Also register a sink on the singleton.
      final globalSink = TestSink();
      LogManager.instance
        ..reset()
        ..addSink(globalSink);

      final record = LogRecord(
        level: LogLevel.info,
        message: 'scoped only',
        timestamp: DateTime.now(),
        loggerName: 'Test',
      );
      scoped.emit(record);

      expect(scopedSink.records, hasLength(1));
      expect(globalSink.records, isEmpty);

      // Clean up.
      LogManager.instance.reset();
    });

    test('getLogger returns logger wired to scoped manager', () {
      final sink = TestSink();
      final scoped = LogManager.scoped()..addSink(sink);

      final logger = scoped.getLogger('ScopedLogger')..info('hello');

      expect(sink.records, hasLength(1));
      expect(sink.records.first.loggerName, 'ScopedLogger');
      expect(sink.records.first.message, 'hello');
      expect(logger.name, 'ScopedLogger');
    });

    test('scoped logger respects scoped minimum level', () {
      final sink = TestSink();
      final scoped = LogManager.scoped()
        ..addSink(sink)
        ..minimumLevel = LogLevel.warning;

      scoped.getLogger('Test')
        ..trace('skip')
        ..debug('skip')
        ..info('skip')
        ..warning('keep')
        ..error('keep');

      expect(sink.records, hasLength(2));
      expect(sink.records[0].level, LogLevel.warning);
      expect(sink.records[1].level, LogLevel.error);
    });

    test('reset clears scoped state without affecting singleton', () {
      final scoped = LogManager.scoped()
        ..addSink(TestSink())
        ..minimumLevel = LogLevel.trace
        ..reset();

      expect(scoped.sinks, isEmpty);
      expect(scoped.minimumLevel, LogLevel.info);
    });

    test('two scoped managers are fully independent', () {
      final sinkA = TestSink();
      final sinkB = TestSink();
      final a = LogManager.scoped()..addSink(sinkA);
      final b = LogManager.scoped()..addSink(sinkB);

      a.getLogger('A').info('from A');
      b.getLogger('B').info('from B');

      expect(sinkA.records, hasLength(1));
      expect(sinkA.records.first.message, 'from A');
      expect(sinkB.records, hasLength(1));
      expect(sinkB.records.first.message, 'from B');
    });

    test('concurrent test simulation — no cross-talk', () {
      // Simulate two "test groups" running with independent managers.
      final sink1 = MemorySink();
      final sink2 = MemorySink();

      final manager1 = LogManager.scoped()
        ..addSink(sink1)
        ..minimumLevel = LogLevel.trace;
      final manager2 = LogManager.scoped()
        ..addSink(sink2)
        ..minimumLevel = LogLevel.error;

      final logger1 = manager1.getLogger('Test1');
      final logger2 = manager2.getLogger('Test2');

      // Both log at trace — only logger1's sink should capture it.
      logger1.trace('trace from 1');
      logger2.trace('trace from 2');

      // Both log at error — both should capture.
      logger1.error('error from 1');
      logger2.error('error from 2');

      expect(sink1.records, hasLength(2)); // trace + error
      expect(sink2.records, hasLength(1)); // error only
      expect(sink1.records[0].message, 'trace from 1');
      expect(sink1.records[1].message, 'error from 1');
      expect(sink2.records[0].message, 'error from 2');
    });

    test('flush and close work on scoped manager', () async {
      final sink = TestSink();
      final scoped = LogManager.scoped()..addSink(sink);

      await scoped.flush();
      expect(sink.flushCount, 1);

      await scoped.close();
      expect(sink.closed, isTrue);
      expect(scoped.sinks, isEmpty);
    });
  });
}
