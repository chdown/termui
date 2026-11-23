import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pty2/pty2.dart';
// Test seam for deterministic native read boundaries.
// ignore: implementation_imports
import 'package:pty2/src/pty_core.dart';
import 'package:test/test.dart';

class _Worker implements PtyCoreWorker {
  _Worker(this.port);
  final SendPort port;
  int i = 0;
  @override
  Uint8List? read() {
    port.send(++i);
    return switch (i) {
      1 => Uint8List.fromList([0xe4]),
      2 => Uint8List.fromList([0xb8, 0xad]),
      _ => null,
    };
  }

  @override
  void free() {}
  @override
  int exitCodeBlocking() => 0;
}

class _Core implements PtyCore {
  _Core(this.worker);
  @override
  final _Worker worker;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
  @override
  void resize(int w, int h, {int pixelWidth = 0, int pixelHeight = 0}) {}
  @override
  PtyWriteHandle duplicateWriteHandle() => throw UnsupportedError('not used');
  @override
  void write(List<int> b) {}
  @override
  Uint8List? read() => null;
  @override
  void onReaderClosed() {}
  @override
  int exitCodeBlocking() => 0;
  @override
  int? exitCodeNonBlocking() => 0;
}

class _SlowHandle implements PtyWriteHandle {
  _SlowHandle(this.port);
  final SendPort port;
  @override
  void write(Uint8List bytes) {
    port.send('start');
    sleep(const Duration(milliseconds: 120));
    port.send(utf8.decode(bytes));
  }

  @override
  void close() => port.send('closed');
}

class _FailingHandle implements PtyWriteHandle {
  _FailingHandle(this.port);
  final SendPort port;

  @override
  void write(Uint8List bytes) => throw StateError('broken native input');

  @override
  void close() => port.send('closed');
}

void main() {
  test(
    'worker write failure closes its handle and reports one error',
    () async {
      final port = ReceivePort();
      addTearDown(port.close);
      final closed = port.first;
      final failed = Completer<Object>();
      final errors = <Object>[];
      final writer = PtyInputWriter(() => _FailingHandle(port.sendPort), (
        error,
      ) {
        errors.add(error);
        if (!failed.isCompleted) failed.complete(error);
      });
      addTearDown(writer.close);
      expect(writer.add('input'), isTrue);
      expect(
        (await failed.future.timeout(const Duration(seconds: 3))).toString(),
        contains('broken native input'),
      );
      await writer.close().timeout(const Duration(seconds: 3));
      expect(await closed.timeout(const Duration(seconds: 3)), 'closed');
      expect(errors, hasLength(1));
      expect(writer.add('late'), isFalse);
    },
  );

  for (final action in [
    'drain before handshake',
    'drain after output',
    'kill',
  ]) {
    test('$action releases ACK pacing without a final UI ACK', () async {
      final reads = ReceivePort();
      addTearDown(reads.close);
      final pty = BlockingPseudoTerminal(_Core(_Worker(reads.sendPort)), true)
        ..init();
      final firstOutput = Completer<void>();
      final output = <String>[];
      final done = Completer<void>();
      final subscription = pty.out.listen((text) {
        output.add(text);
        if (!firstOutput.isCompleted) firstOutput.complete();
      }, onDone: done.complete);
      addTearDown(subscription.cancel);
      if (action != 'drain before handshake') {
        await firstOutput.future.timeout(const Duration(seconds: 3));
      }
      if (action == 'kill') {
        expect(pty.kill(), isTrue);
      } else {
        await pty.beginDrain().timeout(const Duration(seconds: 3));
        await pty.beginDrain();
      }
      await done.future.timeout(const Duration(seconds: 3));
      expect(output, ['中']);
      expect(await pty.exitCode, 0);
    });
  }

  test(
    'empty input and closing an unused writer never duplicate a handle',
    () async {
      final writer = PtyInputWriter(
        () => throw StateError('unused'),
        (error) => fail(error.toString()),
      );
      expect(writer.add(''), isTrue);
      await writer.close();
      await writer.close();
      expect(writer.add('after close'), isFalse);
    },
  );

  test(
    'ACK reader progresses across reads that emit zero decoded bytes',
    () async {
      final rp = ReceivePort();
      final reads = <int>[];
      rp.listen((i) => reads.add(i as int));
      addTearDown(rp.close);
      final p = BlockingPseudoTerminal(_Core(_Worker(rp.sendPort)), true)
        ..init();
      final events = <String>[];
      final sub = p.out.listen((s) {
        events.add(s);
        p.ackProcessed();
      });
      addTearDown(sub.cancel);
      await sub.asFuture<void>().timeout(const Duration(seconds: 3));
      await p.exitCode;
      expect(events, ['中']);
      expect(reads, [1, 2, 3]);
    },
  );

  test(
    'writer keeps order and Unicode and rejects a paste over the bound',
    () async {
      final rp = ReceivePort();
      addTearDown(rp.close);
      final events = <Object?>[];
      final delivered = Completer<void>();
      rp.listen((v) {
        events.add(v);
        if (v == 'last') delivered.complete();
      });
      final errors = <Object>[];
      final writer = PtyInputWriter(() => _SlowHandle(rp.sendPort), errors.add);
      addTearDown(writer.close);
      expect(writer.add('x' * (2 * 1024 * 1024 + 1)), isFalse);
      expect(writer.add('中😀'), isTrue);
      expect(writer.add('last'), isTrue);
      await delivered.future.timeout(const Duration(seconds: 4));
      await writer.close();
      expect(events.where((e) => e != 'closed'), [
        'start',
        '中😀',
        'start',
        'last',
      ]);
      expect(errors, isEmpty);
    },
  );
  test(
    'close cancels queued input while a worker write is in flight',
    () async {
      final rp = ReceivePort();
      addTearDown(rp.close);
      final started = Completer<void>();
      final events = <Object?>[];
      rp.listen((v) {
        events.add(v);
        if (v == 'start' && !started.isCompleted) started.complete();
      });
      final writer = PtyInputWriter(
        () => _SlowHandle(rp.sendPort),
        (e) => fail(e.toString()),
      );
      addTearDown(writer.close);
      writer.add('one');
      writer.add('cancelled');
      await started.future.timeout(const Duration(seconds: 4));
      await writer.close().timeout(const Duration(seconds: 4));
      expect(writer.add('late'), isFalse);
      expect(events, isNot(contains('cancelled')));
    },
  );
  test(
    'closed native handle does not throw into the terminal parser',
    () async {
      final errors = <Object>[];
      final writer = PtyInputWriter(
        () => throw StateError('closed handle'),
        errors.add,
      );
      expect(writer.add('device reply'), isFalse);
      expect(errors, isEmpty);
      await writer.close();
      await Future<void>.delayed(Duration.zero);
      expect(errors.single, isA<StateError>());
    },
  );
}
