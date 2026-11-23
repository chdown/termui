// ignore_for_file: public_member_api_docs

import 'dart:io';

import 'dart:typed_data';
import 'input_writer.dart';

abstract interface class PtyCore {
  Uint8List? read();

  int? exitCodeNonBlocking();

  int exitCodeBlocking();

  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);

  void resize(int width, int height, {int pixelWidth = 0, int pixelHeight = 0});

  // int get pid;

  void write(List<int> data);
  PtyWriteHandle duplicateWriteHandle();

  void onReaderClosed();

  PtyCoreWorker get worker;
}

abstract interface class PtyCoreWorker {
  Uint8List? read();
  int exitCodeBlocking();
  void free();
}
