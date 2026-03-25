import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:struct_log/struct_log.dart';
import 'package:test/test.dart';

void main() {
  group('LogfireSink', () {
    late List<http.Request> captured;
    late LogfireSink sink;

    setUp(() {
      captured = [];
      final mockClient = http_testing.MockClient((request) async {
        captured.add(request);
        return http.Response('{}', 200);
      });
      sink = LogfireSink(
        writeToken: 'test-token',
        serviceName: 'test-service',
        client: mockClient,
      );
    });

    LogRecord _record({
      LogLevel level = LogLevel.info,
      String message = 'test message',
      String loggerName = 'TestLogger',
      String? traceId,
      String? spanId,
      Object? error,
      StackTrace? stackTrace,
      Map<String, Object?> attributes = const {},
    }) {
      return LogRecord(
        level: level,
        message: message,
        timestamp: DateTime.utc(2026, 3, 25, 12, 0, 0),
        loggerName: loggerName,
        traceId: traceId,
        spanId: spanId,
        error: error,
        stackTrace: stackTrace,
        attributes: attributes,
      );
    }

    Map<String, dynamic> _logsPayload() {
      final logsReq =
          captured.where((r) => r.url.path == '/v1/logs').toList();
      expect(logsReq, isNotEmpty, reason: 'Expected a /v1/logs POST');
      return jsonDecode(logsReq.last.body) as Map<String, dynamic>;
    }

    Map<String, dynamic> _tracesPayload() {
      final tracesReq =
          captured.where((r) => r.url.path == '/v1/traces').toList();
      expect(tracesReq, isNotEmpty, reason: 'Expected a /v1/traces POST');
      return jsonDecode(tracesReq.last.body) as Map<String, dynamic>;
    }

    List<Map<String, dynamic>> _logRecords() {
      final payload = _logsPayload();
      final resourceLogs = payload['resourceLogs'] as List;
      final scopeLogs =
          (resourceLogs[0] as Map)['scopeLogs'] as List;
      return List<Map<String, dynamic>>.from(
        (scopeLogs[0] as Map)['logRecords'] as List,
      );
    }

    Map<String, dynamic> _firstLogAttrsMap() {
      final records = _logRecords();
      final attrs = records.first['attributes'] as List;
      return {
        for (final a in attrs.cast<Map<String, dynamic>>())
          a['key'] as String: (a['value'] as Map).values.first,
      };
    }

    // ── Basic write + flush ──

    test('implements LogSink', () {
      expect(sink, isA<LogSink>());
    });

    test('buffers records and sends on flush', () async {
      sink.write(_record());
      expect(captured, isEmpty, reason: 'Should buffer until flush');

      await sink.flush();
      expect(captured, hasLength(1));
      expect(captured.first.url.path, '/v1/logs');
    });

    test('flush is no-op when buffer is empty', () async {
      await sink.flush();
      expect(captured, isEmpty);
    });

    test('close flushes remaining records', () async {
      sink.write(_record());
      await sink.close();
      expect(captured, hasLength(1));
    });

    // ── Authorization header ──

    test('sends write token in Authorization header', () async {
      sink.write(_record());
      await sink.flush();
      expect(captured.first.headers['Authorization'], 'test-token');
    });

    test('sends Content-Type application/json', () async {
      sink.write(_record());
      await sink.flush();
      expect(captured.first.headers['Content-Type'], 'application/json');
    });

    // ── Service name ──

    test('includes service.name in resource attributes', () async {
      sink.write(_record());
      await sink.flush();

      final payload = _logsPayload();
      final resource = (payload['resourceLogs'] as List)[0]['resource'] as Map;
      final attrs = resource['attributes'] as List;
      final serviceAttr = attrs.cast<Map>().firstWhere(
            (a) => a['key'] == 'service.name',
          );
      expect(serviceAttr['value']['stringValue'], 'test-service');
    });

    // ── Logfire-specific attributes ──

    test('sets logfire.span_type to "log" for log records', () async {
      sink.write(_record());
      await sink.flush();
      expect(_firstLogAttrsMap()['logfire.span_type'], 'log');
    });

    test('sets logfire.msg_template and logfire.msg', () async {
      sink.write(_record(message: 'hello world'));
      await sink.flush();
      final attrs = _firstLogAttrsMap();
      expect(attrs['logfire.msg_template'], 'hello world');
      expect(attrs['logfire.msg'], 'hello world');
    });

    test('sets logfire.level_num for each level', () async {
      final levels = {
        LogLevel.trace: 1,
        LogLevel.debug: 5,
        LogLevel.info: 9,
        LogLevel.warning: 13,
        LogLevel.error: 17,
        LogLevel.fatal: 21,
      };

      for (final entry in levels.entries) {
        captured.clear();
        sink.write(_record(level: entry.key));
        await sink.flush();
        expect(
          _firstLogAttrsMap()['logfire.level_num'],
          '${entry.value}',
          reason: '${entry.key} should map to ${entry.value}',
        );
      }
    });

    // ── Logger name ──

    test('includes logger.name attribute', () async {
      sink.write(_record(loggerName: 'MyApp.Auth'));
      await sink.flush();
      expect(_firstLogAttrsMap()['logger.name'], 'MyApp.Auth');
    });

    // ── Severity ──

    test('sets OTel severityNumber and severityText', () async {
      sink.write(_record(level: LogLevel.warning));
      await sink.flush();
      final record = _logRecords().first;
      expect(record['severityNumber'], 13);
      expect(record['severityText'], 'WARNING');
    });

    // ── User attributes ──

    test('sends string attributes', () async {
      sink.write(_record(attributes: {'user': 'alice'}));
      await sink.flush();
      expect(_firstLogAttrsMap()['user'], 'alice');
    });

    test('sends int attributes', () async {
      sink.write(_record(attributes: {'count': 42}));
      await sink.flush();
      expect(_firstLogAttrsMap()['count'], '42');
    });

    test('sends double attributes', () async {
      sink.write(_record(attributes: {'latency': 1.5}));
      await sink.flush();
      expect(_firstLogAttrsMap()['latency'], 1.5);
    });

    test('sends bool attributes', () async {
      sink.write(_record(attributes: {'ok': true}));
      await sink.flush();
      expect(_firstLogAttrsMap()['ok'], true);
    });

    // ── Error + stack trace ──

    test('includes exception.type and exception.message', () async {
      sink.write(_record(
        error: const FormatException('bad input'),
      ));
      await sink.flush();
      final attrs = _firstLogAttrsMap();
      expect(attrs['exception.type'], 'FormatException');
      expect(attrs['exception.message'], contains('bad input'));
    });

    test('includes exception.stacktrace when present', () async {
      try {
        throw StateError('boom');
      } catch (e, st) {
        sink.write(_record(error: e, stackTrace: st));
      }
      await sink.flush();
      expect(
        _firstLogAttrsMap()['exception.stacktrace'],
        contains('logfire_sink_test.dart'),
      );
    });

    // ── Trace/span correlation ──

    test('sets traceId and spanId on log record', () async {
      sink.write(_record(
        traceId: 'abcd1234',
        spanId: 'ef56',
      ));
      await sink.flush();
      final record = _logRecords().first;
      expect(record['traceId'], 'abcd1234'.padLeft(32, '0'));
      expect(record['spanId'], 'ef56'.padLeft(16, '0'));
    });

    test('creates trace span for records with traceId + spanId', () async {
      sink.write(_record(
        traceId: 'aaaa',
        spanId: 'bbbb',
        message: 'request-start',
      ));
      await sink.flush();

      // Should have both /v1/traces and /v1/logs
      expect(captured, hasLength(2));
      final traceReq = captured.firstWhere((r) => r.url.path == '/v1/traces');
      expect(traceReq, isNotNull);

      final payload = _tracesPayload();
      final spans = ((payload['resourceSpans'] as List)[0]['scopeSpans']
          as List)[0]['spans'] as List;
      expect(spans, hasLength(1));
      final span = spans[0] as Map;
      expect(span['name'], 'request-start');
      expect(span['traceId'], 'aaaa'.padLeft(32, '0'));
    });

    test('span has logfire.span_type = "span"', () async {
      sink.write(_record(traceId: 'aa', spanId: 'bb'));
      await sink.flush();

      final payload = _tracesPayload();
      final spans = ((payload['resourceSpans'] as List)[0]['scopeSpans']
          as List)[0]['spans'] as List;
      final attrs = (spans[0] as Map)['attributes'] as List;
      final spanType = attrs.cast<Map>().firstWhere(
            (a) => a['key'] == 'logfire.span_type',
          );
      expect(spanType['value']['stringValue'], 'span');
    });

    test('deduplicates spans with same traceId:spanId', () async {
      sink
        ..write(_record(traceId: 'aa', spanId: 'bb', message: 'first'))
        ..write(_record(traceId: 'aa', spanId: 'bb', message: 'second'));
      await sink.flush();

      final payload = _tracesPayload();
      final spans = ((payload['resourceSpans'] as List)[0]['scopeSpans']
          as List)[0]['spans'] as List;
      expect(spans, hasLength(1), reason: 'Same span should not be duplicated');
    });

    test('sets parentSpanId from parent_span attribute', () async {
      sink.write(_record(
        traceId: 'aa',
        spanId: 'cc',
        attributes: {'parent_span': 'bb'},
      ));
      await sink.flush();

      final payload = _tracesPayload();
      final spans = ((payload['resourceSpans'] as List)[0]['scopeSpans']
          as List)[0]['spans'] as List;
      expect(spans[0]['parentSpanId'], 'bb'.padLeft(16, '0'));
    });

    test('span status is ERROR for error-level records', () async {
      sink.write(_record(level: LogLevel.error, traceId: 'aa', spanId: 'bb'));
      await sink.flush();

      final payload = _tracesPayload();
      final spans = ((payload['resourceSpans'] as List)[0]['scopeSpans']
          as List)[0]['spans'] as List;
      expect((spans[0] as Map)['status']['code'], 2); // STATUS_ERROR
    });

    test('span status is UNSET for info-level records', () async {
      sink.write(_record(level: LogLevel.info, traceId: 'aa', spanId: 'bb'));
      await sink.flush();

      final payload = _tracesPayload();
      final spans = ((payload['resourceSpans'] as List)[0]['scopeSpans']
          as List)[0]['spans'] as List;
      expect((spans[0] as Map)['status']['code'], 0); // STATUS_UNSET
    });

    // ── No trace context = logs only ──

    test('does not send traces when no traceId/spanId', () async {
      sink.write(_record());
      await sink.flush();
      expect(captured, hasLength(1));
      expect(captured.first.url.path, '/v1/logs');
    });

    // ── Error handling ──

    test('throws on non-200 response', () async {
      final failClient = http_testing.MockClient((_) async {
        return http.Response('{"error": "bad"}', 400);
      });
      final failSink = LogfireSink(
        writeToken: 'tok',
        client: failClient,
      );
      failSink.write(_record());
      expect(() => failSink.flush(), throwsException);
    });

    // ── Multiple records batched ──

    test('batches multiple records in one POST', () async {
      sink
        ..write(_record(message: 'one'))
        ..write(_record(message: 'two'))
        ..write(_record(message: 'three'));
      await sink.flush();

      expect(captured, hasLength(1));
      final records = _logRecords();
      expect(records, hasLength(3));
    });
  });
}
