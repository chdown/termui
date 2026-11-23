import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

/// Only a duplicated OS handle crosses isolates; no buffers/finalizers are
/// shared with the PTY reader, reaper, or UI isolate.
abstract interface class PtyWriteHandle {
  /// Writes every byte, throwing if the native write cannot complete.
  void write(Uint8List bytes);

  /// Releases this duplicated handle after its last write.
  void close();
}

/// One in-flight write and a bounded FIFO. A complete paste is one message;
/// Unicode and paste delimiters cannot be interleaved with later key events.
class PtyInputWriter {
  /// Creates a writer; the native handle is duplicated lazily on first input.
  PtyInputWriter(this._duplicate, this._onError);
  final PtyWriteHandle Function() _duplicate;
  final void Function(Object) _onError;
  final _queue = Queue<String>();
  final _done = Completer<void>();
  ReceivePort? _events;
  SendPort? _worker;
  int _queuedUnits = 0;
  int _inFlight = 0;
  bool _closed = false;

  /// Queues a complete input string, preserving ordering and Unicode.
  ///
  /// Returns false after close or when 2 Mi UTF-16 code units (including the
  /// current write) or 4096 waiting messages would be exceeded.
  bool add(String data) {
    if (_closed) return false;
    if (data.isEmpty) return true;
    if (_queuedUnits + _inFlight + data.length > 2 * 1024 * 1024 ||
        _queue.length >= 4096) {
      return false;
    }
    if (_events == null) {
      late final PtyWriteHandle handle;
      try {
        handle = _duplicate();
      } catch (error) {
        _fail(error);
        return false;
      }
      final events = _events = ReceivePort();
      events.listen((message) {
        if (message is SendPort) {
          _worker = message;
        } else if (message == true) {
          _inFlight = 0;
        } else if (message == null) {
          if (!_closed) _fail(StateError('PTY input worker exited'));
          _finish();
          return;
        } else {
          _fail(StateError('PTY write failed: $message'));
          return;
        }
        _pump();
      });
      unawaited(
        Isolate.spawn(
          _writeLoop,
          (events.sendPort, handle),
          onExit: events.sendPort,
          onError: events.sendPort,
        ).then<void>(
          (_) {},
          onError: (Object error, StackTrace _) {
            handle.close(); // ownership never transferred
            _fail(error);
            _finish();
          },
        ),
      );
    }
    _queue.addLast(data);
    _queuedUnits += data.length;
    _pump();
    return true;
  }

  void _pump() {
    final worker = _worker;
    if (worker == null) return;
    if (_closed) {
      worker.send(null);
      _worker = null;
    } else if (_inFlight == 0 && _queue.isNotEmpty) {
      final data = _queue.removeFirst();
      _inFlight = data.length;
      _queuedUnits -= data.length;
      worker.send(data);
    }
  }

  void _fail(Object error) {
    if (_closed) return;
    close();
    scheduleMicrotask(() => _onError(error));
  }

  /// Discards queued input and waits for the in-flight write to release its
  /// handle. Kill the PTY first if its child has stopped consuming input.
  Future<void> close() {
    _closed = true;
    _queue.clear();
    _queuedUnits = 0;
    _pump();
    if (_events == null) _finish();
    return _done.future;
  }

  void _finish() {
    _events?.close();
    if (!_done.isCompleted) _done.complete();
  }
}

Future<void> _writeLoop((SendPort, PtyWriteHandle) args) async {
  final (reply, handle) = args;
  final input = ReceivePort();
  try {
    reply.send(input.sendPort);
    await for (final message in input) {
      if (message == null) break;
      handle.write(utf8.encode(message as String));
      reply.send(true);
    }
  } catch (error) {
    reply.send(error.toString());
  } finally {
    handle.close();
    input.close();
  }
}
