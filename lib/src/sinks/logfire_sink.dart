import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:struct_log/src/log_level.dart';
import 'package:struct_log/src/log_record.dart';
import 'package:struct_log/src/log_sink.dart';

/// Logfire severity numbers — matches [LogLevel.value] exactly.
/// trace=1, debug=5 is not a coincidence; struct_log was designed
/// with these OTel-adjacent values.
int _logfireLevelNum(LogLevel level) => switch (level) {
      LogLevel.trace => 1,
      LogLevel.debug => 5,
      LogLevel.info => 9,
      LogLevel.warning => 13,
      LogLevel.error => 17,
      LogLevel.fatal => 21,
    };

/// Standard OTel severity numbers (different scale from logfire.level_num).
int _otelSeverity(LogLevel level) => switch (level) {
      LogLevel.trace => 1,
      LogLevel.debug => 5,
      LogLevel.info => 9,
      LogLevel.warning => 13,
      LogLevel.error => 17,
      LogLevel.fatal => 21,
    };

const _statusUnset = 0;
const _statusError = 2;

/// A [LogSink] that ships log records to [Logfire](https://logfire.pydantic.dev)
/// via OTLP/HTTP JSON.
///
/// Sends logs to `/v1/logs` with logfire-specific attributes so the Logfire UI
/// can properly render severity, messages, and trace correlation. When records
/// carry [LogRecord.traceId] and [LogRecord.spanId], also sends corresponding
/// trace spans to `/v1/traces` so the trace tree is complete.
///
/// ```dart
/// final manager = LogManager.instance;
/// manager.addSink(LogfireSink(
///   writeToken: Platform.environment['LOGFIRE_TOKEN']!,
///   serviceName: 'my-dart-app',
/// ));
/// final log = manager.getLogger('App');
/// log.info('hello logfire', attributes: {'user': 'alice'});
/// await manager.flush();
/// ```
class LogfireSink implements LogSink {
  /// Creates a sink that ships to logfire.
  ///
  /// [writeToken] is a logfire project write token (starts with `pylf_v1_`).
  /// [endpoint] defaults to the US region.
  /// [serviceName] appears as `service.name` in logfire traces.
  LogfireSink({
    required String writeToken,
    String endpoint = 'https://logfire-us.pydantic.dev',
    this.serviceName = 'struct_log-dart',
    http.Client? client,
  })  : _writeToken = writeToken,
        _logsUrl = Uri.parse('$endpoint/v1/logs'),
        _tracesUrl = Uri.parse('$endpoint/v1/traces'),
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// Service name sent as a resource attribute.
  final String serviceName;

  final String _writeToken;
  final Uri _logsUrl;
  final Uri _tracesUrl;
  final http.Client _client;
  final bool _ownsClient;
  final List<Map<String, Object?>> _logBuffer = [];
  final List<Map<String, Object?>> _spanBuffer = [];
  final Set<String> _createdSpans = {};

  @override
  void write(LogRecord record) {
    _logBuffer.add(_toOtlpLogRecord(record));

    // Create trace spans for records with OTel context
    if (record.traceId != null && record.spanId != null) {
      final spanKey = '${record.traceId}:${record.spanId}';
      if (!_createdSpans.contains(spanKey)) {
        _createdSpans.add(spanKey);
        _spanBuffer.add(_toOtlpSpan(record));
      }
    }
  }

  @override
  Future<void> flush() async {
    // Send spans first so they exist when logs reference them.
    if (_spanBuffer.isNotEmpty) {
      await _post(_tracesUrl, _buildTracesPayload(List.of(_spanBuffer)));
      _spanBuffer.clear();
    }
    if (_logBuffer.isNotEmpty) {
      await _post(_logsUrl, _buildLogsPayload(List.of(_logBuffer)));
      _logBuffer.clear();
    }
  }

  @override
  Future<void> close() async {
    await flush();
    if (_ownsClient) _client.close();
  }

  // ---------------------------------------------------------------------------
  // HTTP
  // ---------------------------------------------------------------------------

  Future<void> _post(Uri url, Map<String, Object?> payload) async {
    final response = await _client.post(
      url,
      headers: {
        'Authorization': _writeToken,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    );
    if (response.statusCode != 200 && response.statusCode != 202) {
      throw Exception(
        'Logfire OTLP POST to $url failed: '
        '${response.statusCode} ${response.body}',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Resource attributes (shared between logs and traces)
  // ---------------------------------------------------------------------------

  List<Map<String, Object?>> get _resourceAttributes => [
        {
          'key': 'service.name',
          'value': {'stringValue': serviceName},
        },
      ];

  // ---------------------------------------------------------------------------
  // OTLP /v1/logs payload
  // ---------------------------------------------------------------------------

  Map<String, Object?> _buildLogsPayload(List<Map<String, Object?>> records) {
    return {
      'resourceLogs': [
        {
          'resource': {'attributes': _resourceAttributes},
          'scopeLogs': [
            {
              'scope': {'name': 'struct_log', 'version': '0.3.0'},
              'logRecords': records,
            },
          ],
        },
      ],
    };
  }

  Map<String, Object?> _toOtlpLogRecord(LogRecord record) {
    final attrs = <Map<String, Object?>>[
      // ── logfire-specific attributes ──
      _strAttr('logfire.span_type', 'log'),
      _strAttr('logfire.msg_template', record.message),
      _strAttr('logfire.msg', record.message),
      _intAttr('logfire.level_num', _logfireLevelNum(record.level)),
      // ── standard attributes ──
      _strAttr('logger.name', record.loggerName),
    ];

    // OTel trace/span IDs as attributes (in addition to top-level fields)
    String? traceId;
    String? spanId;
    if (record.traceId != null) {
      traceId = record.traceId!.padLeft(32, '0');
    }
    if (record.spanId != null) {
      spanId = record.spanId!.padLeft(16, '0');
    }

    // Error info
    if (record.error != null) {
      attrs
        ..add(_strAttr('exception.type', record.error.runtimeType.toString()))
        ..add(_strAttr('exception.message', record.error.toString()));
    }
    if (record.stackTrace != null) {
      attrs.add(_strAttr('exception.stacktrace', record.stackTrace.toString()));
    }

    // User attributes
    for (final entry in record.attributes.entries) {
      attrs.add(_toOtlpAttr(entry.key, entry.value));
    }

    final logRecord = <String, Object?>{
      'timeUnixNano': '${record.timestamp.microsecondsSinceEpoch * 1000}',
      'severityNumber': _otelSeverity(record.level),
      'severityText': record.level.label,
      'body': {'stringValue': record.message},
      'attributes': attrs,
    };

    if (traceId != null) logRecord['traceId'] = traceId;
    if (spanId != null) logRecord['spanId'] = spanId;

    return logRecord;
  }

  // ---------------------------------------------------------------------------
  // OTLP /v1/traces payload
  // ---------------------------------------------------------------------------

  Map<String, Object?> _buildTracesPayload(List<Map<String, Object?>> spans) {
    return {
      'resourceSpans': [
        {
          'resource': {'attributes': _resourceAttributes},
          'scopeSpans': [
            {
              'scope': {'name': 'struct_log', 'version': '0.3.0'},
              'spans': spans,
            },
          ],
        },
      ],
    };
  }

  Map<String, Object?> _toOtlpSpan(LogRecord record) {
    final traceId = record.traceId!.padLeft(32, '0');
    final spanId = record.spanId!.padLeft(16, '0');
    final nowNano = '${record.timestamp.microsecondsSinceEpoch * 1000}';

    final parentSpanId = record.attributes['parent_span'] as String?;

    final attrs = <Map<String, Object?>>[
      // ── logfire-specific ──
      _strAttr('logfire.span_type', 'span'),
      _strAttr('logfire.msg_template', record.message),
      _strAttr('logfire.msg', record.message),
      _intAttr('logfire.level_num', _logfireLevelNum(record.level)),
      // ── standard ──
      _strAttr('logger.name', record.loggerName),
    ];

    for (final entry in record.attributes.entries) {
      if (entry.key == 'parent_span') continue;
      attrs.add(_toOtlpAttr(entry.key, entry.value));
    }

    // Exception events on the span
    final events = <Map<String, Object?>>[];
    if (record.error != null) {
      events.add({
        'name': 'exception',
        'timeUnixNano': nowNano,
        'attributes': [
          _strAttr('exception.type', record.error.runtimeType.toString()),
          _strAttr('exception.message', record.error.toString()),
          if (record.stackTrace != null)
            _strAttr('exception.stacktrace', record.stackTrace.toString()),
        ],
      });
    }

    final span = <String, Object?>{
      'traceId': traceId,
      'spanId': spanId,
      'name': record.message,
      'kind': 1, // SPAN_KIND_INTERNAL
      'startTimeUnixNano': nowNano,
      'endTimeUnixNano': nowNano,
      'attributes': attrs,
      'status': {
        'code': record.level >= LogLevel.error ? _statusError : _statusUnset,
      },
    };

    if (parentSpanId != null) {
      span['parentSpanId'] = parentSpanId.padLeft(16, '0');
    }
    if (events.isNotEmpty) {
      span['events'] = events;
    }

    return span;
  }

  // ---------------------------------------------------------------------------
  // OTLP attribute helpers
  // ---------------------------------------------------------------------------

  static Map<String, Object?> _strAttr(String key, String value) => {
        'key': key,
        'value': {'stringValue': value},
      };

  static Map<String, Object?> _intAttr(String key, int value) => {
        'key': key,
        'value': {'intValue': '$value'},
      };

  static Map<String, Object?> _toOtlpAttr(String key, Object? value) {
    final Map<String, Object?> otelValue;
    switch (value) {
      case final int v:
        otelValue = {'intValue': '$v'};
      case final double v:
        otelValue = {'doubleValue': v};
      case final bool v:
        otelValue = {'boolValue': v};
      default:
        otelValue = {'stringValue': '$value'};
    }
    return {'key': key, 'value': otelValue};
  }
}
