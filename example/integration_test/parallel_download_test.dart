// ignore_for_file: avoid_print, empty_catches

import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' hide equals;
import 'package:path_provider/path_provider.dart';

var statusCallbackCounter = 0;
var progressCallbackCounter = 0;

var statusCallbackCompleter = Completer<void>();
var progressCallbackCompleter = Completer<void>();
var someProgressCompleter = Completer<void>(); // completes when progress > 0
var significantProgressCompleter =
    Completer<void>(); // completes when progress > 0.1
var lastStatus = TaskStatus.enqueued;
var lastProgress = -100.0;
var lastValidExpectedFileSize = -1;
var lastValidNetworkSpeed = -1.0;
var lastValidTimeRemaining = const Duration(seconds: -1);
TaskException? lastException;

const workingUrl = 'https://google.com';
const failingUrl = 'https://avmaps-dot-bbflightserver-hrd.appspot'
    '.com/public/get_current_app_data?key=background_downloader_integration_test';
const urlWithContentLength = 'https://storage.googleapis'
    '.com/approachcharts/test/5MB-test.ZIP';
const urlWithLongContentLength = 'https://storage.googleapis'
    '.com/approachcharts/test/57MB-test.ZIP';
const urlWithContentLengthFileSize = 6207471;
const urlWithLongContentLengthFileSize = 59673498;

const defaultFilename = '5MB-test.ZIP';

var task = ParallelDownloadTask(
    url: urlWithContentLength, filename: defaultFilename, chunks: 2);
var failingTask =
    ParallelDownloadTask(url: failingUrl, filename: defaultFilename, chunks: 2);
var retryTask = ParallelDownloadTask(
    url: urlWithContentLength,
    filename: defaultFilename,
    chunks: 2,
    retries: 3);

void statusCallback(TaskStatusUpdate update) {
  final task = update.task;
  final status = update.status;
  print('statusCallback for $task with status $status');
  if (update.exception != null) {
    print('Exception: ${update.exception}');
  }
  lastStatus = status;
  lastException = update.exception;
  statusCallbackCounter++;
  if (!statusCallbackCompleter.isCompleted && status.isFinalState) {
    statusCallbackCompleter.complete();
  }
}

void progressCallback(TaskProgressUpdate update) {
  final task = update.task;
  final progress = update.progress;
  print('progressCallback for $task with $update}');
  lastProgress = progress;
  if (update.hasExpectedFileSize) {
    lastValidExpectedFileSize = update.expectedFileSize;
  }
  if (update.hasNetworkSpeed) {
    lastValidNetworkSpeed = update.networkSpeed;
  }
  if (update.hasTimeRemaining) {
    lastValidTimeRemaining = update.timeRemaining;
  }
  progressCallbackCounter++;
  if (!someProgressCompleter.isCompleted && progress > 0) {
    someProgressCompleter.complete();
  }
  if (!significantProgressCompleter.isCompleted && progress > 0.1) {
    significantProgressCompleter.complete();
  }
  if (!progressCallbackCompleter.isCompleted &&
      (progress < 0 || progress == 1)) {
    progressCallbackCompleter.complete();
  }
}

void main() {
  setUp(() async {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((LogRecord rec) {
      debugPrint(
          '${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}');
    });
    await FileDownloader().reset();
    await FileDownloader().reset(group: FileDownloader.awaitGroup);
    await FileDownloader().reset(group: 'someGroup');
    // recreate the tasks
    task = ParallelDownloadTask(
        url: urlWithContentLength, filename: defaultFilename, chunks: 2);
    retryTask = ParallelDownloadTask(
        url: urlWithContentLength,
        filename: defaultFilename,
        chunks: 2,
        retries: 3);

    // reset counters
    statusCallbackCounter = 0;
    progressCallbackCounter = 0;
    statusCallbackCompleter = Completer<void>();
    progressCallbackCompleter = Completer<void>();
    significantProgressCompleter = Completer<void>();
    someProgressCompleter = Completer<void>();
    lastStatus = TaskStatus.enqueued;
    lastProgress = 0;
    lastValidExpectedFileSize = -1;
    lastValidNetworkSpeed = -1.0;
    lastValidTimeRemaining = const Duration(seconds: -1);
    lastException = null;
    FileDownloader().destroy();
    final path =
        join((await getApplicationDocumentsDirectory()).path, task.filename);
    try {
      File(path).deleteSync();
    } on FileSystemException {}
  });

  tearDown(() async {
    await FileDownloader().reset();
    await FileDownloader().reset(group: FileDownloader.awaitGroup);
    await FileDownloader().reset(group: FileDownloader.chunkGroup);
    FileDownloader().destroy();
    if (Platform.isAndroid || Platform.isIOS) {
      await FileDownloader()
          .downloaderForTesting
          .setForceFailPostOnBackgroundChannel(false);
    }
    await Future.delayed(const Duration(milliseconds: 250));
  });

  group('Basic', () {
    test('simple enqueue, 2 chunks, 1 url', () async {
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      expect(await FileDownloader().enqueue(task.copyWith(url: urlWithContentLength)), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
      final file = File(await task.filePath());
      expect(file.existsSync(), isTrue);
      expect(await file.length(), equals(urlWithContentLengthFileSize));
    });

    test('simple enqueue, 2 chunks, 2 url', () async {
      task = ParallelDownloadTask(
          url: [urlWithContentLength, urlWithContentLength], filename: defaultFilename, chunks: 2);
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
      final file = File(await task.filePath());
      expect(file.existsSync(), isTrue);
      expect(await file.length(), equals(urlWithContentLengthFileSize));
    });

    test('simple enqueue with progress, 2 chunks, 1 url', () async {
      var lastProgress = -1.0;
      var numProgressUpdates = 0;
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: (update) {
            expect(update.progress, greaterThan(lastProgress));
            print('${DateTime.now()}: Progress #${numProgressUpdates++} = ${update.progress}, ${update.networkSpeedAsString}, ${update.timeRemainingAsString}');
            lastProgress = update.progress;
          });
      expect(await FileDownloader().enqueue(task.copyWith(url: urlWithLongContentLength, updates: Updates.statusAndProgress)), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
      final file = File(await task.filePath());
      expect(file.existsSync(), isTrue);
      expect(await file.length(), equals(urlWithLongContentLengthFileSize));
      expect(numProgressUpdates, greaterThan(1));
    });

    test('403 enqueue, no retries', () async {
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      expect(await FileDownloader().enqueue(failingTask), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.failed));
    });

    //TODO add 404 test (Not Found)

    test('retries - must modify transferBytes to fail', () async {
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      expect(await FileDownloader().enqueue(retryTask), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.failed));
    });

    test('cancellation', () async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      expect(await FileDownloader().enqueue(task.copyWith(url: urlWithLongContentLength, updates: Updates.statusAndProgress)), isTrue);
      await someProgressCompleter.future;
      expect(lastStatus, equals(TaskStatus.running));
      expect(await FileDownloader().cancelTaskWithId(task.taskId), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.canceled));
      await Future.delayed(const Duration(seconds: 3));
    });

    test('pause', () async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      task = task.copyWith(url: urlWithLongContentLength, updates: Updates.statusAndProgress, allowPause: true);
      expect(await FileDownloader().enqueue(task), isTrue);
      await someProgressCompleter.future;
      expect(lastStatus, equals(TaskStatus.running));
      expect(await FileDownloader().pause(task), isTrue);
      await Future.delayed(const Duration(seconds: 1));
      expect(lastStatus, equals(TaskStatus.paused));
      expect(lastProgress, equals(progressPaused));
      await Future.delayed(const Duration(seconds: 2));
      expect(await FileDownloader().resume(task), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
      expect(lastProgress, equals(progressComplete));
      await Future.delayed(const Duration(seconds: 3));
      final file = File(await task.filePath());
      expect(file.existsSync(), isTrue);
      expect(await file.length(), equals(urlWithLongContentLengthFileSize));
    });
  });
}
