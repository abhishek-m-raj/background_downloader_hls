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

  void dispose() {
    for (final controller in _overallUpdateControllers.values) {
      if (!controller.isClosed) {
        unawaited(controller.close());
      }
    }
    _overallUpdateControllers.clear();
    _latestOverallUpdates.clear();
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

    String? segmentDirectoryPath;
    List<String> segmentTaskIds = const [];
    try {
      await _fileDownloader.trackTasks();
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

      var completedSegments = 0;
      var failedSegments = 0;

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

      if (batch.numFailed > 0) {
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

        finalTaskId = await _storeFinalOutputTaskRecord(
          downloadId: downloadId,
          filePath: outputFilePath,
          manifestUrl: manifestUrl,
          resolvedPlaylistUrl: manifest.mediaPlaylistUri.toString(),
          displayName: fileName,
          segmentCount: manifest.segments.length,
        );

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
      final lastKnown = _latestOverallUpdates[downloadId];
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
      if (!options.keepTempFilesOnFailure && segmentDirectoryPath != null) {
        await _safeDeleteDirectory(segmentDirectoryPath);
      }
      rethrow;
    } catch (error, stackTrace) {
      if (segmentTaskIds.isNotEmpty) {
        await _removeTemporarySegmentTaskRecords(segmentTaskIds);
      }
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
      await _closeOverallController(downloadId);
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
    final controller = _overallUpdateControllers[update.downloadId];
    if (controller != null && !controller.isClosed) {
      controller.add(update);
    }
  }

  Future<void> _closeOverallController(String downloadId) async {
    final controller = _overallUpdateControllers.remove(downloadId);
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
    _latestOverallUpdates.remove(downloadId);
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
