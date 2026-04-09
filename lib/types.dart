import 'package:background_downloader/background_downloader.dart';

enum HlsVariantSelection { highestBandwidth, lowestBandwidth, first }

enum HlsLogLevel { none, error, info, debug }

enum HlsDownloadPhase {
  preparing,
  downloading,
  combining,
  paused,
  canceled,
  completed,
  failed,
}

typedef HlsLogCallback =
    void Function(
      HlsLogLevel level,
      String message, [
      Object? error,
      StackTrace? stackTrace,
    ]);

class HlsDownloadOptions {
  const HlsDownloadOptions({
    this.downloadId,
    this.retryAttempts = 3,
    this.customHeaders = const {},
    this.variantSelection = HlsVariantSelection.highestBandwidth,
    this.combineSegments = true,
    this.deleteSegmentsAfterCombine = true,
    this.keepTempFilesOnFailure = false,
    this.outputFileExtension = 'mp4',
    this.outputDirectoryPath,
    this.batchProgressCallback,
    this.logLevel = HlsLogLevel.error,
    this.logCallback,
  });

  final String? downloadId;
  final int retryAttempts;
  final Map<String, String> customHeaders;
  final HlsVariantSelection variantSelection;
  final bool combineSegments;
  final bool deleteSegmentsAfterCombine;
  final bool keepTempFilesOnFailure;
  final String outputFileExtension;
  final String? outputDirectoryPath;
  final BatchProgressCallback? batchProgressCallback;
  final HlsLogLevel logLevel;
  final HlsLogCallback? logCallback;

  HlsDownloadOptions copyWith({
    String? downloadId,
    int? retryAttempts,
    Map<String, String>? customHeaders,
    HlsVariantSelection? variantSelection,
    bool? combineSegments,
    bool? deleteSegmentsAfterCombine,
    bool? keepTempFilesOnFailure,
    String? outputFileExtension,
    String? outputDirectoryPath,
    BatchProgressCallback? batchProgressCallback,
    HlsLogLevel? logLevel,
    HlsLogCallback? logCallback,
  }) {
    return HlsDownloadOptions(
      downloadId: downloadId ?? this.downloadId,
      retryAttempts: retryAttempts ?? this.retryAttempts,
      customHeaders: customHeaders ?? this.customHeaders,
      variantSelection: variantSelection ?? this.variantSelection,
      combineSegments: combineSegments ?? this.combineSegments,
      deleteSegmentsAfterCombine:
          deleteSegmentsAfterCombine ?? this.deleteSegmentsAfterCombine,
      keepTempFilesOnFailure:
          keepTempFilesOnFailure ?? this.keepTempFilesOnFailure,
      outputFileExtension: outputFileExtension ?? this.outputFileExtension,
      outputDirectoryPath: outputDirectoryPath ?? this.outputDirectoryPath,
      batchProgressCallback:
          batchProgressCallback ?? this.batchProgressCallback,
      logLevel: logLevel ?? this.logLevel,
      logCallback: logCallback ?? this.logCallback,
    );
  }
}

class HlsOverallTaskUpdate {
  const HlsOverallTaskUpdate({
    required this.downloadId,
    required this.phase,
    required this.totalSegments,
    required this.completedSegments,
    required this.failedSegments,
    required this.progress,
    this.totalExpectedFileSize,
    this.downloadedBytes,
    this.networkSpeed,
    this.timeRemaining,
    this.message,
    this.latestTaskUpdate,
  });

  final String downloadId;
  final HlsDownloadPhase phase;
  final int totalSegments;
  final int completedSegments;
  final int failedSegments;
  final double progress;
  final int? totalExpectedFileSize;
  final int? downloadedBytes;
  final double? networkSpeed;
  final Duration? timeRemaining;
  final String? message;
  final TaskUpdate? latestTaskUpdate;

  bool get isTerminal =>
      phase == HlsDownloadPhase.completed ||
      phase == HlsDownloadPhase.failed ||
      phase == HlsDownloadPhase.canceled;
}

class HlsResolvedManifest {
  const HlsResolvedManifest({
    required this.originalManifestUri,
    required this.mediaPlaylistUri,
    required this.segments,
  });

  final Uri originalManifestUri;
  final Uri mediaPlaylistUri;
  final List<HlsSegmentEntry> segments;
}

class HlsSegmentEntry {
  const HlsSegmentEntry({
    required this.uri,
    required this.sequenceNumber,
    this.encryptionKeyUri,
    this.encryptionIvHex,
    this.isInitializationSegment = false,
  });

  final Uri uri;
  final int sequenceNumber;
  final Uri? encryptionKeyUri;
  final String? encryptionIvHex;
  final bool isInitializationSegment;
}

class HlsDownloadResult {
  const HlsDownloadResult({
    required this.downloadId,
    required this.finalTaskId,
    required this.manifestUrl,
    required this.resolvedMediaPlaylistUrl,
    required this.segmentDirectoryPath,
    required this.outputFilePath,
    required this.segmentCount,
    required this.failedSegmentCount,
    required this.batch,
  });

  final String downloadId;
  final String? finalTaskId;
  final String manifestUrl;
  final String resolvedMediaPlaylistUrl;
  final String segmentDirectoryPath;
  final String? outputFilePath;
  final int segmentCount;
  final int failedSegmentCount;
  final Batch batch;

  bool get isSuccess => failedSegmentCount == 0;
}

class HlsErrorCode {
  HlsErrorCode._();

  static const String invalidUrl = 'invalid_url';
  static const String invalidFileName = 'invalid_file_name';
  static const String invalidOptions = 'invalid_options';
  static const String playlistParseFailed = 'playlist_parse_failed';
  static const String emptyPlaylist = 'empty_playlist';
  static const String segmentDownloadFailed = 'segment_download_failed';
  static const String segmentMissing = 'segment_missing';
  static const String encryptionKeyFetchFailed = 'encryption_key_fetch_failed';
  static const String combineFailed = 'combine_failed';
  static const String storagePermissionDenied = 'storage_permission_denied';
  static const String downloadNotFound = 'download_not_found';
  static const String downloadAlreadyRunning = 'download_already_running';
  static const String downloadPaused = 'download_paused';
  static const String downloadCanceled = 'download_canceled';
  static const String unexpected = 'unexpected';
}

class HlsDownloadException implements Exception {
  const HlsDownloadException({
    required this.code,
    required this.message,
    this.cause,
    this.stackTrace,
  });

  final String code;
  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => 'HlsDownloadException($code): $message';
}
