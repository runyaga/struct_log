# struct_log

Structured logging for Dart with pluggable sinks and OpenTelemetry-compatible context (spanId/traceId). Zero Flutter dependency.

## Install

```yaml
dependencies:
  struct_log: ^0.1.0
```

## Usage

```dart
import 'package:struct_log/struct_log.dart';

void main() {
  // Configure sinks.
  final manager = LogManager.instance;
  manager.addSink(StdoutSink(useColors: true));
  manager.addSink(MemorySink());
  manager.minimumLevel = LogLevel.debug;

  // Create a logger.
  final log = manager.getLogger('MyApp');

  // Log messages at various levels.
  log.info('Application started');
  log.debug('Loading config', attributes: {'path': '/etc/app.yaml'});
  log.error('Connection failed', error: 'timeout', spanId: 'abc123');

  // Shut down.
  manager.close();
}
```

## API Overview

| Type | Description |
|------|-------------|
| `LogLevel` | Six-level severity enum (trace, debug, info, warning, error, fatal) with OTel-standard names. |
| `LogRecord` | Immutable structured log record with `spanId`, `traceId`, and `Map<String, Object> attributes`. |
| `LogSink` | Abstract interface with `write` / `flush` / `close` lifecycle. |
| `LogManager` | Singleton sink manager with fan-out, level filtering, and fault isolation. |
| `Logger` | Named logger facade with convenience methods for each level. |
| `MemorySink` | O(1) circular buffer with live `onRecord` stream. Ideal for debugging UIs and test assertions. |
| `ConsoleSink` | Platform-adaptive sink using `dart:developer` (native) and browser `console` API (web). |
| `StdoutSink` | Platform-adaptive sink using `dart:io` stdout with optional ANSI colors. No-op on web. |

## Platform Support

Works on all Dart platforms (native + web) via conditional imports. `StdoutSink` and `ConsoleSink` each select the appropriate implementation at compile time.
