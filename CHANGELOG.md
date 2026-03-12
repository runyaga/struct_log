# Changelog

## 0.2.0

- **`LogManager.scoped()`** — named constructor that creates an independent
  `LogManager` instance with its own sink list and minimum level. Enables
  test isolation without mutating the global singleton.
  Fixes [dart_monty#194](https://github.com/runyaga/dart_monty/issues/194).

## 0.1.0

- Initial release of `struct_log`.
- `LogLevel` — six-level severity enum (trace, debug, info, warning, error,
  fatal) with OTel-standard names and numeric values.
- `LogRecord` — immutable structured log record with `spanId`, `traceId`,
  and `Map<String, Object> attributes` for telemetry correlation.
- `LogSink` — abstract interface with `write`/`flush`/`close` lifecycle.
- `LogManager` — singleton sink manager with fan-out, level filtering, and
  fault isolation (failing sinks do not crash the app).
- `Logger` + `LoggerFactory` — named logger facade with level methods.
- `MemorySink` — O(1) circular buffer with live `onRecord` stream and
  `onClear` notification. Ideal for debugging UIs and test assertions.
- `ConsoleSink` — platform-adaptive sink using `dart:developer` (native)
  and browser `console` API (web).
- `StdoutSink` — platform-adaptive sink using `dart:io` stdout with
  optional ANSI color codes. No-op on web.
