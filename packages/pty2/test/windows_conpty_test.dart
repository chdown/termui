@TestOn('windows')
library;

import 'dart:io';

import 'package:pty2/pty2.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart' as win32;

void main() {
  test('残留 Win32 错误码不会使连续会话降级为普通管道', () async {
    final shell =
        '${Platform.environment['SystemRoot']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
    for (final error in [0, 5, 6, 183, 0]) {
      win32.SetLastError(win32.WIN32_ERROR(error));
      final pty = PseudoTerminal.start(shell, [
        '-NoLogo',
        '-NoProfile',
        '-Command',
        '[Console]::IsOutputRedirected; [Console]::IsInputRedirected',
      ]);
      try {
        final output = await pty.out.join().timeout(
          const Duration(seconds: 10),
        );
        expect(await pty.exitCode, 0);
        expect(output, isNot(contains('True')), reason: '旧错误码：$error');
        expect('False'.allMatches(output).length, 2);
      } finally {
        pty.kill();
      }
    }
  });
}
