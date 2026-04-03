import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'helper.dart';
import 'types.dart';

export 'package:background_downloader/background_downloader.dart';
export 'types.dart';

enum _SessionControl { none, pause, cancel, delete }

class _HlsDownloadSession {
  _HlsDownloadSession({
    required this.downloadId,
    required this.manifestUrl,
    required this.fileName,
    required this.options,
  });

  final String downloadId;
  final String manifestUrl;
  final String fileName;
  final HlsDownloadOptions options;

  HlsDownloadPhase phase = HlsDownloadPhase.preparing;
  _SessionControl control = _SessionControl.none;

  List<String> segmentTaskIds = const [];
  String? segmentDirectoryPath;
  String? outputFilePath;
  String? finalTaskId;

  bool get isActive =>
      phase == HlsDownloadPhase.preparing ||
      phase == HlsDownloadPhase.downloading ||
      phase == HlsDownloadPhase.combining;
}

@pragma('vm:entry-point')
class HlsDownloader {
  HlsDownloader({
    FileDownloader? fileDownloader,
    DownloaderHelper? helper,
    this.logCallback,
  }) : _fileDownloader = fileDownloader ?? FileDownloader(),
       _helper = helper ?? DownloaderHelper();

  final FileDownloader _fileDownloader;
  final DownloaderHelper _helper;
  final HlsLogCallback? logCallback;
  final Map<String, StreamController<HlsOverallTaskUpdate>>
  _overallUpdateControllers = {};
  final Map<String, HlsOverallTaskUpdate> _latestOverallUpdates = {};
  final Map<String, _HlsDownloadSession> _sessions = {};

  void dispose() {
    for (final controller in _overallUpdateControllers.values) {
      if (!controller.isClosed) {
        unawaited(controller.close());
      }
    }
    _overallUpdateControllers.clear();
    _latestOverallUpdates.clear();
    _sessions.clear();
    _helper.dispose();
  }

  Stream<HlsOverallTaskUpdate> listen(String downloadId) {
    final trimmedDownloadId = downloadId.trim();
    if (trimmedDownloadId.isEmpty) {
      throw const HlsDownloadException(
        code: HlsErrorCode.invalidOptions,
        message: 'downloadId cannot be blank for listenOverall',
      );
    }
    final controller = _overallControllerFor(trimmedDownloadId);
    return controller.stream;
  }

  HlsDownloadPhase? phaseFor(String downloadId) {
    return _sessions[downloadId.trim()]?.phase;
  }

  bool isPaused(String downloadId) {
    return phaseFor(downloadId) == HlsDownloadPhase.paused;
  }

  Future<void> pauseDownload(String downloadId) async {
    final normalizedId = downloadId.trim();
    if (normalizedId.isEmpty) {
      throw const HlsDownloadException(
        code: HlsErrorCode.invalidOptions,
        message: 'downloadId cannot be blank',
      );
    }

    final session = _sessions[normalizedId];
    if (session == null) {
      throw const HlsDownloadException(
        code: HlsErrorCode.downloadNotFound,
        message: 'No download found for this downloadId',
      );
    }

    if (!session.isActive) {
      if (session.phase == HlsDownloadPhase.paused) {
        return;
      }
      throw HlsDownloadException(
        code: HlsErrorCode.invalidOptions,
        message: 'Cannot pause download in ${session.phase.name} state',
      );
    }

    session.control = _SessionControl.pause;
    await _cancelTasksForDownloadId(
      normalizedId,
      preferredTaskIds: session.segmentTaskIds,
    );
  }

  Future<HlsDownloadResult> resumeDownload(String downloadId) async {
    final normalizedId = downloadId.trim();
    if (normalizedId.isEmpty) {
      throw const HlsDownloadException(
        code: HlsErrorCode.invalidOptions,
        message: 'downloadId cannot be blank',
      );
    }

    final session = _sessions[normalizedId];
    if (session == null) {
      throw const HlsDownloadException(
        code: HlsErrorCode.downloadNotFound,
        message: 'No paused download found for this downloadId',
      );
    }

    if (session.isActive) {
      throw const HlsDownloadException(
        code: HlsErrorCode.downloadAlreadyRunning,
        message: 'This download is already running',
      );
    }

    if (session.phase != HlsDownloadPhase.paused &&
        session.phase != HlsDownloadPhase.failed) {
      throw HlsDownloadException(
        code: HlsErrorCode.invalidOptions,
        message: 'Cannot resume download in ${session.phase.name} state',
      );
    }

    return downloadToFile(
      session.manifestUrl,
      session.fileName,
      options: session.options.copyWith(downloadId: normalizedId),
    );
  }

  Future<void> cancelDownload(String downloadId) async {
    final normalizedId = downloadId.trim();
    if (normalizedId.isEmpty) {
      throw const HlsDownloadException(
        code: HlsErrorCode.invalidOptions,
        message: 'downloadId cannot be blank',
      );
    }

    final session = _sessions[normalizedId];
    if (session != null) {
      session.control = _SessionControl.cancel;
    }

    await _cancelTasksForDownloadId(
      normalizedId,
      preferredTaskIds: session?.segmentTaskIds ?? const [],
    );

    if (session == null || !session.isActive) {
      if (session != null) {
        session.phase = HlsDownloadPhase.canceled;
      }
      _emitOverallUpdate(
        HlsOverallTaskUpdate(
          downloadId: normalizedId,
          phase: HlsDownloadPhase.canceled,
          totalSegments: _latestOverallUpdates[normalizedId]?.totalSegments ?? 0,
          completedSegments:
              _latestOverallUpdates[normalizedId]?.completedSegments ?? 0,
          failedSegments: _latestOverallUpdates[normalizedId]?.failedSegments ??
              0,
          progress: _latestOverallUpdates[normalizedId]?.progress ?? 0.0,
          message: 'Canceled',
        ),
      );
      _sessions.remove(normalizedId);
      await _closeOverallController(normalizedId, keepLatestUpdate: false);
    }
  }

  Future<void> deleteDownload(String downloadId) async {
    final normalizedId = downloadId.trim();
    if (normalizedId.isEmpty) {
      throw const HlsDownloadException(
        code: HlsErrorCode.invalidOptions,
        message: 'downloadId cannot be blank',
      );
    }

    final session = _sessions[normalizedId];
    if (session != null) {
      session.control = _SessionControl.delete;
    }

    await _cancelTasksForDownloadId(
      normalizedId,
      preferredTaskIds: session?.segmentTaskIds ?? const [],
    );
    await _deleteStoredOutputForDownload(normalizedId, session);
    await _safeDeleteTaskGroupArtifacts(normalizedId);

    _sessions.remove(normalizedId);
    _emitOverallUpdate(
      HlsOverallTaskUpdate(
        downloadId: normalizedId,
        phase: HlsDownloadPhase.canceled,
        totalSegments: _latestOverallUpdates[normalizedId]?.totalSegments ?? 0,
        completedSegments:
            _latestOverallUpdates[normalizedId]?.completedSegments ?? 0,
        failedSegments: _latestOverallUpdates[normalizedId]?.failedSegments ?? 0,
        progress: _latestOverallUpdates[normalizedId]?.progress ?? 0.0,
        message: 'Deleted',
      ),
    );

    await _closeOverallController(normalizedId, keepLatestUpdate: false);
  }

  @Deprecated('Use downloadToFile for typed result and stronger validation.')
  Future<bool> download(
    String streamLink,
    String fileName, {
    int retryAttempts = 3,
    int parallelBatches = 5,
    Map<String, String> customHeaders = const {},
    String? subsUrl,
  }) async {
    if (parallelBatches < 1) {
      throw const HlsDownloadException(
        code: HlsErrorCode.invalidOptions,
        message: 'parallelBatches must be >= 1',
      );
    }

    if (subsUrl != null && subsUrl.trim().isNotEmpty) {
      _log(
        options: const HlsDownloadOptions(logLevel: HlsLogLevel.debug),
        level: HlsLogLevel.debug,
        message: 'Subtitle URL is currently ignored: $subsUrl',
      );
    }

    final result = await downloadToFile(
      streamLink,
      fileName,
      options: HlsDownloadOptions(
        retryAttempts: retryAttempts,
        customHeaders: customHeaders,
      ),
    );
    return result.isSuccess;
  }

  Future<HlsDownloadResult> downloadToFile(
    String manifestUrl,
    String fileName, {
    HlsDownloadOptions options = const HlsDownloadOptions(),
  }) async {
    _helper.validateDownloadRequest(
      manifestUrl: manifestUrl,
      fileName: fileName,
      options: options,
    );

    final customDownloadId = options.downloadId?.trim();
    if (customDownloadId != null && customDownloadId.isEmpty) {
      throw const HlsDownloadException(
        code: HlsErrorCode.invalidOptions,
        message: 'downloadId cannot be blank',
      );
    }

    final downloadId = customDownloadId ?? _helper.generateId();

    final activeSession = _sessions[downloadId];
    if (activeSession != null && activeSession.isActive) {
      throw const HlsDownloadException(
        code: HlsErrorCode.downloadAlreadyRunning,
        message: 'This download is already running',
      );
    }

    final session = _HlsDownloadSession(
      downloadId: downloadId,
      manifestUrl: manifestUrl,
      fileName: fileName,
      options: options,
    );
    _sessions[downloadId] = session;
    session.control = _SessionControl.none;
    session.phase = HlsDownloadPhase.preparing;
    session.segmentTaskIds = const [];
    session.segmentDirectoryPath = null;
    session.outputFilePath = null;
    session.finalTaskId = null;

    String? segmentDirectoryPath;
    List<String> segmentTaskIds = const [];
    try {
      await _fileDownloader.trackTasks();
      session.phase = HlsDownloadPhase.preparing;
      _emitOverallUpdate(
        HlsOverallTaskUpdate(
          downloadId: downloadId,
          phase: HlsDownloadPhase.preparing,
          totalSegments: 0,
          completedSegments: 0,
          failedSegments: 0,
          progress: 0,
          message: 'Resolving playlist',
        ),
      );

      final manifest = await _helper.resolveManifest(
        manifestUrl: manifestUrl,
        customHeaders: options.customHeaders,
        variantSelection: options.variantSelection,
      );

      if (manifest.segments.isEmpty) {
        throw const HlsDownloadException(
          code: HlsErrorCode.emptyPlaylist,
          message: 'No segments found in resolved playlist',
        );
      }

      final appDocDir = await getApplicationDocumentsDirectory();
      final relativeSegmentDirectory = p.join('hls_segments', downloadId);
      segmentDirectoryPath = p.join(appDocDir.path, relativeSegmentDirectory);
      session.segmentDirectoryPath = segmentDirectoryPath;
      await Directory(segmentDirectoryPath).create(recursive: true);

      final downloadTasks = <DownloadTask>[];
      for (var i = 0; i < manifest.segments.length; i++) {
        final segment = manifest.segments[i];
        downloadTasks.add(
          DownloadTask(
            url: segment.uri.toString(),
            headers: options.customHeaders,
            filename: _helper.segmentFileName(i + 1),
            directory: relativeSegmentDirectory,
            baseDirectory: BaseDirectory.applicationDocuments,
            retries: options.retryAttempts,
            group: downloadId,
            metaData: jsonEncode({
              'segmentIndex': i,
              'totalSegments': manifest.segments.length,
            }),
          ),
        );
      }

      segmentTaskIds = downloadTasks.map((task) => task.taskId).toList();
      session.segmentTaskIds = segmentTaskIds;

      var completedSegments = 0;
      var failedSegments = 0;
      session.phase = HlsDownloadPhase.downloading;

      _emitOverallUpdate(
        HlsOverallTaskUpdate(
          downloadId: downloadId,
          phase: HlsDownloadPhase.downloading,
          totalSegments: manifest.segments.length,
          completedSegments: 0,
          failedSegments: 0,
          progress: 0,
          message: 'Downloading segments',
        ),
      );

      final batch = await _fileDownloader.downloadBatch(
        downloadTasks,
        batchProgressCallback: (succeeded, failed) {
          completedSegments = succeeded;
          failedSegments = failed;
          options.batchProgressCallback?.call(succeeded, failed);
          final total = manifest.segments.length;
          final progress = total > 0 ? (succeeded + failed) / total : 0.0;
          _emitOverallUpdate(
            HlsOverallTaskUpdate(
              downloadId: downloadId,
              phase: HlsDownloadPhase.downloading,
              totalSegments: total,
              completedSegments: completedSegments,
              failedSegments: failedSegments,
              progress: progress.clamp(0.0, 1.0),
              message: 'Downloading segments',
            ),
          );
        },
        taskStatusCallback: (statusUpdate) {
          final total = manifest.segments.length;
          final progress = total > 0
              ? (completedSegments + failedSegments) / total
              : 0.0;
          _emitOverallUpdate(
            HlsOverallTaskUpdate(
              downloadId: downloadId,
              phase: HlsDownloadPhase.downloading,
              totalSegments: total,
              completedSegments: completedSegments,
              failedSegments: failedSegments,
              progress: progress.clamp(0.0, 1.0),
              latestTaskUpdate: statusUpdate,
              message: 'Downloading segments',
            ),
          );
        },
        taskProgressCallback: (progressUpdate) {
          final total = manifest.segments.length;
          final progress = total > 0
              ? (completedSegments + failedSegments) / total
              : 0.0;
          _emitOverallUpdate(
            HlsOverallTaskUpdate(
              downloadId: downloadId,
              phase: HlsDownloadPhase.downloading,
              totalSegments: total,
              completedSegments: completedSegments,
              failedSegments: failedSegments,
              progress: progress.clamp(0.0, 1.0),
              latestTaskUpdate: progressUpdate,
              message: 'Downloading segments',
            ),
          );
        },
      );

      await _removeTemporarySegmentTaskRecords(segmentTaskIds);

      if (session.control == _SessionControl.pause) {
        final lastKnown = _latestOverallUpdates[downloadId];
        session.phase = HlsDownloadPhase.paused;
        _emitOverallUpdate(
          HlsOverallTaskUpdate(
            downloadId: downloadId,
            phase: HlsDownloadPhase.paused,
            totalSegments: manifest.segments.length,
            completedSegments:
                lastKnown?.completedSegments ?? completedSegments,
            failedSegments: lastKnown?.failedSegments ?? failedSegments,
            progress:
                (lastKnown?.progress ??
                        (manifest.segments.isEmpty
                            ? 0.0
                            : (completedSegments + failedSegments) /
                                manifest.segments.length))
                    .clamp(0.0, 1.0),
            message: 'Paused',
            latestTaskUpdate: lastKnown?.latestTaskUpdate,
          ),
        );
        throw const HlsDownloadException(
          code: HlsErrorCode.downloadPaused,
          message: 'Download paused',
        );
      }

      if (session.control == _SessionControl.cancel ||
          session.control == _SessionControl.delete) {
        final lastKnown = _latestOverallUpdates[downloadId];
        session.phase = HlsDownloadPhase.canceled;
        await _deleteStoredOutputForDownload(downloadId, session);
        await _safeDeleteTaskGroupArtifacts(downloadId);
        _sessions.remove(downloadId);
        _emitOverallUpdate(
          HlsOverallTaskUpdate(
            downloadId: downloadId,
            phase: HlsDownloadPhase.canceled,
            totalSegments: manifest.segments.length,
            completedSegments:
                lastKnown?.completedSegments ?? completedSegments,
            failedSegments: lastKnown?.failedSegments ?? failedSegments,
            progress: (lastKnown?.progress ?? 0.0).clamp(0.0, 1.0),
            message: session.control == _SessionControl.delete
                ? 'Deleted'
                : 'Canceled',
            latestTaskUpdate: lastKnown?.latestTaskUpdate,
          ),
        );
        throw const HlsDownloadException(
          code: HlsErrorCode.downloadCanceled,
          message: 'Download canceled',
        );
      }

      if (batch.numFailed > 0) {
        session.phase = HlsDownloadPhase.failed;
        _emitOverallUpdate(
          HlsOverallTaskUpdate(
            downloadId: downloadId,
            phase: HlsDownloadPhase.failed,
            totalSegments: manifest.segments.length,
            completedSegments: batch.numSucceeded,
            failedSegments: batch.numFailed,
            progress: 1.0,
            message: 'One or more segment downloads failed',
          ),
        );
        throw HlsDownloadException(
          code: HlsErrorCode.segmentDownloadFailed,
          message:
              'Failed to download ${batch.numFailed} of ${manifest.segments.length} segments',
        );
      }

      String? outputFilePath;
      String? finalTaskId;
      if (options.combineSegments) {
        session.phase = HlsDownloadPhase.combining;
        final outputFileName = _helper.buildOutputFileName(
          fileName,
          options.outputFileExtension,
        );
        final outputRootPath =
            options.outputDirectoryPath?.trim().isNotEmpty == true
            ? options.outputDirectoryPath!.trim()
            : appDocDir.path;
        await Directory(outputRootPath).create(recursive: true);
        outputFilePath = p.join(outputRootPath, outputFileName);
        session.outputFilePath = outputFilePath;

        _emitOverallUpdate(
          HlsOverallTaskUpdate(
            downloadId: downloadId,
            phase: HlsDownloadPhase.combining,
            totalSegments: manifest.segments.length,
            completedSegments: manifest.segments.length,
            failedSegments: 0,
            progress: 1.0,
            message: 'Combining segments',
          ),
        );

        await _helper.combineSegmentsToFile(
          segments: manifest.segments,
          segmentDirectoryPath: segmentDirectoryPath,
          outputFilePath: outputFilePath,
          customHeaders: options.customHeaders,
        );

        if (session.control == _SessionControl.cancel ||
            session.control == _SessionControl.delete) {
          session.phase = HlsDownloadPhase.canceled;
          await _deleteStoredOutputForDownload(downloadId, session);
          await _safeDeleteTaskGroupArtifacts(downloadId);
          throw const HlsDownloadException(
            code: HlsErrorCode.downloadCanceled,
            message: 'Download canceled',
          );
        }

        finalTaskId = await _storeFinalOutputTaskRecord(
          downloadId: downloadId,
          filePath: outputFilePath,
          manifestUrl: manifestUrl,
          resolvedPlaylistUrl: manifest.mediaPlaylistUri.toString(),
          displayName: fileName,
          segmentCount: manifest.segments.length,
        );
        session.finalTaskId = finalTaskId;

        if (options.deleteSegmentsAfterCombine) {
          await _safeDeleteDirectory(segmentDirectoryPath);
        }

        _emitOverallUpdate(
          HlsOverallTaskUpdate(
            downloadId: downloadId,
            phase: HlsDownloadPhase.completed,
            totalSegments: manifest.segments.length,
            completedSegments: manifest.segments.length,
            failedSegments: 0,
            progress: 1.0,
            message: 'Completed',
          ),
        );
        session.phase = HlsDownloadPhase.completed;
      } else {
        _emitOverallUpdate(
          HlsOverallTaskUpdate(
            downloadId: downloadId,
            phase: HlsDownloadPhase.completed,
            totalSegments: manifest.segments.length,
            completedSegments: manifest.segments.length,
            failedSegments: 0,
            progress: 1.0,
            message: 'Completed',
          ),
        );
        session.phase = HlsDownloadPhase.completed;
      }

      return HlsDownloadResult(
        downloadId: downloadId,
        finalTaskId: finalTaskId,
        manifestUrl: manifestUrl,
        resolvedMediaPlaylistUrl: manifest.mediaPlaylistUri.toString(),
        segmentDirectoryPath: segmentDirectoryPath,
        outputFilePath: outputFilePath,
        segmentCount: manifest.segments.length,
        failedSegmentCount: batch.numFailed,
        batch: batch,
      );
    } on HlsDownloadException catch (error, stackTrace) {
      if (segmentTaskIds.isNotEmpty) {
        await _removeTemporarySegmentTaskRecords(segmentTaskIds);
      }

      final isPaused = error.code == HlsErrorCode.downloadPaused;
      final isCanceled = error.code == HlsErrorCode.downloadCanceled;

      if (!isPaused && !isCanceled) {
        session.phase = HlsDownloadPhase.failed;
      }

      final lastKnown = _latestOverallUpdates[downloadId];
      if (!isPaused && !isCanceled) {
        _emitOverallUpdate(
          HlsOverallTaskUpdate(
            downloadId: downloadId,
            phase: HlsDownloadPhase.failed,
            totalSegments: lastKnown?.totalSegments ?? 0,
            completedSegments: lastKnown?.completedSegments ?? 0,
            failedSegments: lastKnown?.failedSegments ?? 0,
            progress: lastKnown?.progress ?? 0.0,
            message: error.message,
            latestTaskUpdate: lastKnown?.latestTaskUpdate,
          ),
        );
        _log(
          options: options,
          level: HlsLogLevel.error,
          message: error.message,
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (!isPaused &&
          !isCanceled &&
          !options.keepTempFilesOnFailure &&
          segmentDirectoryPath != null) {
        await _safeDeleteDirectory(segmentDirectoryPath);
      }
      rethrow;
    } catch (error, stackTrace) {
      if (segmentTaskIds.isNotEmpty) {
        await _removeTemporarySegmentTaskRecords(segmentTaskIds);
      }
      session.phase = HlsDownloadPhase.failed;
      final lastKnown = _latestOverallUpdates[downloadId];
      _emitOverallUpdate(
        HlsOverallTaskUpdate(
          downloadId: downloadId,
          phase: HlsDownloadPhase.failed,
          totalSegments: lastKnown?.totalSegments ?? 0,
          completedSegments: lastKnown?.completedSegments ?? 0,
          failedSegments: lastKnown?.failedSegments ?? 0,
          progress: lastKnown?.progress ?? 0.0,
          message: 'Unexpected failure in downloadToFile',
          latestTaskUpdate: lastKnown?.latestTaskUpdate,
        ),
      );
      _log(
        options: options,
        level: HlsLogLevel.error,
        message: 'Unexpected failure in downloadToFile',
        error: error,
        stackTrace: stackTrace,
      );
      if (!options.keepTempFilesOnFailure && segmentDirectoryPath != null) {
        await _safeDeleteDirectory(segmentDirectoryPath);
      }
      throw HlsDownloadException(
        code: HlsErrorCode.unexpected,
        message: 'Unexpected failure in downloadToFile',
        cause: error,
        stackTrace: stackTrace,
      );
    } finally {
      if (session.phase != HlsDownloadPhase.paused) {
        await _closeOverallController(downloadId, keepLatestUpdate: false);
      }
    }
  }

  StreamController<HlsOverallTaskUpdate> _overallControllerFor(
    String downloadId,
  ) {
    final existing = _overallUpdateControllers[downloadId];
    if (existing != null && !existing.isClosed) {
      return existing;
    }

    late final StreamController<HlsOverallTaskUpdate> controller;
    controller = StreamController<HlsOverallTaskUpdate>.broadcast(
      onListen: () {
        final latest = _latestOverallUpdates[downloadId];
        if (latest != null && !controller.isClosed) {
          controller.add(latest);
        }
      },
    );
    _overallUpdateControllers[downloadId] = controller;
    return controller;
  }

  void _emitOverallUpdate(HlsOverallTaskUpdate update) {
    _latestOverallUpdates[update.downloadId] = update;
    final session = _sessions[update.downloadId];
    if (session != null) {
      session.phase = update.phase;
    }
    final controller = _overallUpdateControllers[update.downloadId];
    if (controller != null && !controller.isClosed) {
      controller.add(update);
    }
  }

  Future<void> _closeOverallController(
    String downloadId, {
    bool keepLatestUpdate = false,
  }) async {
    final controller = _overallUpdateControllers.remove(downloadId);
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
    if (!keepLatestUpdate) {
      _latestOverallUpdates.remove(downloadId);
    }
  }

  Future<void> _cancelTasksForDownloadId(
    String downloadId, {
    Iterable<String> preferredTaskIds = const [],
  }) async {
    final cleanedIds = preferredTaskIds
        .map((taskId) => taskId.trim())
        .where((taskId) => taskId.isNotEmpty)
        .toSet()
        .toList();

    try {
      if (cleanedIds.isNotEmpty) {
        await _fileDownloader.cancelTasksWithIds(cleanedIds);
      }

      await _fileDownloader.cancelAll(group: downloadId);

      final records = await _fileDownloader.database.allRecords(group: downloadId);
      if (records.isNotEmpty) {
        await _fileDownloader.cancelTasksWithIds(
          records.map((record) => record.taskId),
        );
      }
    } catch (_) {
      // Intentionally ignored.
    }
  }

  Future<void> _deleteStoredOutputForDownload(
    String downloadId,
    _HlsDownloadSession? session,
  ) async {
    final outputCandidates = <String>{};

    final sessionOutput = session?.outputFilePath?.trim();
    if (sessionOutput != null && sessionOutput.isNotEmpty) {
      outputCandidates.add(sessionOutput);
    }

    final records = await _fileDownloader.database.allRecords(group: downloadId);
    for (final record in records) {
      if (record.task.taskId == 'hls-final-$downloadId') {
        try {
          final path = await record.task.filePath();
          if (path.trim().isNotEmpty) {
            outputCandidates.add(path);
          }
        } catch (_) {
          // Intentionally ignored.
        }
      }
    }

    for (final path in outputCandidates) {
      await _safeDeleteFile(path);
    }
  }

  Future<void> _safeDeleteTaskGroupArtifacts(String downloadId) async {
    final appDocDir = await getApplicationDocumentsDirectory();
    await _safeDeleteDirectory(p.join(appDocDir.path, 'hls_segments', downloadId));
    await _deleteTaskRecordsByGroup(downloadId);
  }

  Future<void> _deleteTaskRecordsByGroup(String group) async {
    try {
      final records = await _fileDownloader.database.allRecords(group: group);
      if (records.isEmpty) {
        return;
      }
      await _fileDownloader.database.deleteRecordsWithIds(
        records.map((record) => record.taskId),
      );
    } catch (_) {
      // Intentionally ignored.
    }
  }

  Future<void> _removeTemporarySegmentTaskRecords(
    Iterable<String> taskIds,
  ) async {
    final ids = taskIds.where((taskId) => taskId.trim().isNotEmpty).toList();
    if (ids.isEmpty) {
      return;
    }
    await _fileDownloader.database.deleteRecordsWithIds(ids);
  }

  Future<String> _storeFinalOutputTaskRecord({
    required String downloadId,
    required String filePath,
    required String manifestUrl,
    required String resolvedPlaylistUrl,
    required String displayName,
    required int segmentCount,
  }) async {
    final finalTaskId = 'hls-final-$downloadId';
    final split = await Task.split(filePath: filePath);
    final baseDirectory = split.$1;
    final directory = split.$2;
    final filename = split.$3;
    final outputFile = File(filePath);

    final finalTask = DownloadTask(
      taskId: finalTaskId,
      url: manifestUrl,
      filename: filename,
      directory: directory,
      baseDirectory: baseDirectory,
      group: downloadId,
      displayName: displayName,
      metaData: jsonEncode({
        'type': 'hls_final_output',
        'manifestUrl': manifestUrl,
        'resolvedMediaPlaylistUrl': resolvedPlaylistUrl,
        'segmentCount': segmentCount,
      }),
    );

    await _fileDownloader.database.updateRecord(
      TaskRecord(
        finalTask,
        TaskStatus.complete,
        1.0,
        await outputFile.length(),
      ),
    );

    return finalTaskId;
  }

  Future<void> _safeDeleteDirectory(String path) async {
    try {
      final directory = Directory(path);
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {
      // Intentionally ignored.
    }
  }

  Future<void> _safeDeleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Intentionally ignored.
    }
  }

  void _log({
    required HlsDownloadOptions options,
    required HlsLogLevel level,
    required String message,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final callback = options.logCallback ?? logCallback;
    if (callback == null || options.logLevel == HlsLogLevel.none) {
      return;
    }
    if (options.logLevel.index >= level.index) {
      callback(level, message, error, stackTrace);
    }
  }
}
