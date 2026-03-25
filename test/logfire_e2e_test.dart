@TestOn('vm')
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:struct_log/struct_log.dart';
import 'package:test/test.dart';

final _runId =
    'e2e-${Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
const _service = 'struct-log-e2e';

String get _writeToken => Platform.environment['LOGFIRE_TOKEN']!;
String get _readToken => Platform.environment['LOGFIRE_READ_TOKEN']!;

Future<List<Map<String, dynamic>>> _query(String sql) async {
  final client = http.Client();
  try {
    final response = await client.get(
      Uri.parse('https://logfire-us.pydantic.dev/v1/query').replace(
        queryParameters: {
          'sql': sql,
          'json_rows': 'true',
        },
      ),
      headers: {
        'Authorization': _readToken,
        'Accept': 'application/json',
      },
    );
    if (response.statusCode != 200) {
      fail('Query failed: ${response.statusCode} ${response.body}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(data['rows'] as List);
  } finally {
    client.close();
  }
}

void main() {
  late LogManager manager;
  late MemorySink memory;
  late LogfireSink logfire;

  setUpAll(() async {
    manager = LogManager.scoped()..minimumLevel = LogLevel.trace;
    memory = MemorySink();
    logfire = LogfireSink(
      writeToken: _writeToken,
      serviceName: _service,
    );
    manager
      ..addSink(memory)
      ..addSink(logfire);

    final log = manager.getLogger('E2E');

    // ── 1. All six levels ──
    for (final level in LogLevel.values) {
      log._logAtLevel(
        level,
        '${level.name}-event',
        attributes: {'run_id': _runId, 'test': 'levels'},
      );
    }

    // ── 2. Structured attributes ──
    log.info('structured-data', attributes: {
      'run_id': _runId,
      'test': 'attributes',
      'user': 'alice',
      'latency_ms': 99.9,
      'count': 7,
      'active': true,
    });

    // ── 3. Error + stack trace ──
    try {
      throw FormatException('bad payload');
    } catch (e, st) {
      log.error('parse-error', error: e, stackTrace: st, attributes: {
        'run_id': _runId,
        'test': 'error',
      });
    }

    // ── 4. Trace/span correlation with parent-child ──
    const traceId = 'e2e00000000000000000000000000001';
    const parentSpan = 'e2e0000000000001';
    const childSpan = 'e2e0000000000002';

    log.info('request-start',
        traceId: traceId,
        spanId: parentSpan,
        attributes: {
          'run_id': _runId,
          'test': 'correlation',
          'http.method': 'GET',
        });
    log.info('db-fetch',
        traceId: traceId,
        spanId: childSpan,
        attributes: {
          'run_id': _runId,
          'test': 'correlation',
          'parent_span': parentSpan,
          'db.table': 'agents',
        });
    log.info('request-done',
        traceId: traceId,
        spanId: parentSpan,
        attributes: {
          'run_id': _runId,
          'test': 'correlation',
          'http.status_code': 200,
        });

    // ── 5. Named loggers ──
    manager.getLogger('Auth').info('token-ok', attributes: {
      'run_id': _runId,
      'test': 'named',
    });
    manager.getLogger('Cache').warning('miss', attributes: {
      'run_id': _runId,
      'test': 'named',
    });

    // ── Flush + wait for ingestion ──
    await manager.flush();
    // Give logfire time to ingest
    await Future<void>.delayed(const Duration(seconds: 10));
  });

  tearDownAll(() async {
    await manager.close();
  });

  // ── Single query, all validations ──
  late List<Map<String, dynamic>> rows;

  setUpAll(() async {
    rows = await _query(
      "SELECT message, attributes, service_name, trace_id, span_id, "
      "parent_span_id "
      "FROM records "
      "WHERE attributes->>'run_id' = '$_runId' "
      "ORDER BY start_timestamp",
    );
  });

  Map<String, dynamic>? _findByMessage(String msg) {
    final matches = rows.where((r) => r['message'] == msg).toList();
    return matches.isEmpty ? null : matches.first;
  }

  List<Map<String, dynamic>> _findByTest(String testName) {
    return rows
        .where(
            (r) => (r['attributes'] as Map?)?.containsKey('test') == true &&
                r['attributes']['test'] == testName)
        .toList();
  }

  test('all events arrived', () {
    // 6 levels + 1 structured + 1 error + 3 correlation + 2 named = 13
    // plus trace spans for correlated records
    expect(rows.length, greaterThanOrEqualTo(13),
        reason: 'got ${rows.length} rows');
  });

  test('all six log levels present', () {
    final levelRows = _findByTest('levels');
    final messages = levelRows.map((r) => r['message']).toSet();
    for (final level in LogLevel.values) {
      expect(messages, contains('${level.name}-event'),
          reason: 'Missing ${level.name}');
    }
  });

  test('structured attributes round-trip', () {
    final attrRows = _findByTest('attributes');
    expect(attrRows, isNotEmpty);
    final attrs = attrRows.first['attributes'] as Map;
    expect(attrs['user'], 'alice');
    expect(double.tryParse(attrs['latency_ms'].toString()), closeTo(99.9, 0.1));
    expect(int.tryParse(attrs['count'].toString()), 7);
    expect(attrs['active'].toString(), 'true');
  });

  test('error event has exception info', () {
    final errorRows = _findByTest('error');
    expect(errorRows, isNotEmpty);
    final attrs = errorRows.first['attributes'] as Map;
    expect(attrs['exception.type'], contains('FormatException'));
    expect(attrs['exception.message'], contains('bad payload'));
  });

  test('trace/span correlation — parent and child spans exist', () {
    final corrRows = _findByTest('correlation');
    expect(corrRows.length, greaterThanOrEqualTo(3));

    // Check db-fetch has parentSpanId set
    final dbRow = _findByMessage('db-fetch');
    expect(dbRow, isNotNull, reason: 'db-fetch row should exist');
    // The span created for db-fetch should have parent_span_id
    final dbSpanRows = rows.where((r) =>
        r['message'] == 'db-fetch' && r['parent_span_id'] != null);
    expect(dbSpanRows, isNotEmpty,
        reason: 'db-fetch span should have a parent');
  });

  test('trace IDs match across correlated events', () {
    final corrRows = _findByTest('correlation');
    final traceIds = corrRows.map((r) => r['trace_id']).toSet();
    // All correlation events should share the same trace
    expect(traceIds.length, 1,
        reason: 'All correlated events should share one traceId, got $traceIds');
  });

  test('named loggers distinguished', () {
    final namedRows = _findByTest('named');
    final loggerNames = namedRows
        .map((r) => (r['attributes'] as Map)['logger.name'])
        .toSet();
    expect(loggerNames, containsAll(['Auth', 'Cache']));
  });

  test('service name set correctly', () {
    final services = rows.map((r) => r['service_name']).toSet();
    expect(services, contains(_service));
  });

  test('logfire.span_type present on records', () {
    // Check at least one record has logfire.span_type in attributes
    final hasSpanType = rows.any((r) {
      final attrs = r['attributes'] as Map?;
      return attrs?.containsKey('logfire.span_type') ?? false;
    });
    expect(hasSpanType, isTrue);
  });

  test('logfire.level_num present on records', () {
    final hasLevelNum = rows.any((r) {
      final attrs = r['attributes'] as Map?;
      return attrs?.containsKey('logfire.level_num') ?? false;
    });
    expect(hasLevelNum, isTrue);
  });

  test('logfire.msg_template present on records', () {
    final hasMsgTemplate = rows.any((r) {
      final attrs = r['attributes'] as Map?;
      return attrs?.containsKey('logfire.msg_template') ?? false;
    });
    expect(hasMsgTemplate, isTrue);
  });

  test('local MemorySink captured same count', () {
    // MemorySink should have the same number of log records we wrote
    // (not including trace spans, which only go to logfire)
    expect(memory.records.length, 13);
  });
}

/// Helper to call the right level method on Logger.
extension on Logger {
  void _logAtLevel(
    LogLevel level,
    String message, {
    Map<String, Object?>? attributes,
  }) {
    switch (level) {
      case LogLevel.trace:
        trace(message, attributes: attributes);
      case LogLevel.debug:
        debug(message, attributes: attributes);
      case LogLevel.info:
        info(message, attributes: attributes);
      case LogLevel.warning:
        warning(message, attributes: attributes);
      case LogLevel.error:
        error(message, attributes: attributes);
      case LogLevel.fatal:
        fatal(message, attributes: attributes);
    }
  }
}
