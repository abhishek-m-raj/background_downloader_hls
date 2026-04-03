import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart';
import 'package:flutter_hls_parser/flutter_hls_parser.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'types.dart';

class DownloaderHelper {
  DownloaderHelper({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;

  void dispose() {
    _httpClient.close();
  }

  String generateId() =>
      DateTime.now().toUtc().microsecondsSinceEpoch.toString();

  String sanitizeFileName(String fileName) {
    final sanitized = fileName
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '')
        .replaceAll(RegExp(r'\s+'), ' ');
    return sanitized;
  }

  String buildOutputFileName(String fileName, String defaultExtension) {
    final sanitized = sanitizeFileName(fileName);
    if (sanitized.isEmpty) {
      throw const HlsDownloadException(
        code: HlsErrorCode.invalidFileName,
        message: 'fileName cannot be empty after sanitization',
      );
    }

    final existingExtension = p.extension(sanitized);
    if (existingExtension.isNotEmpty) {
      return sanitized;
    }

    final normalizedExtension = defaultExtension.trim().replaceFirst('.', '');
    if (normalizedExtension.isEmpty) {
      throw const HlsDownloadException(
        code: HlsErrorCode.invalidOptions,
        message: 'outputFileExtension cannot be empty',
      );
    }
    return '$sanitized.$normalizedExtension';
  }

  String segmentFileName(int index) =>
      '${index.toString().padLeft(6, '0')}.part';

  void validateDownloadRequest({
    required String manifestUrl,
    required String fileName,
    required HlsDownloadOptions options,
  }) {
    final parsed = Uri.tryParse(manifestUrl);
    if (parsed == null ||
        !(parsed.isScheme('http') || parsed.isScheme('https'))) {
      throw const HlsDownloadException(
        code: HlsErrorCode.invalidUrl,
        message: 'manifestUrl must be a valid http(s) URL',
      );
    }

    if (sanitizeFileName(fileName).isEmpty) {
      throw const HlsDownloadException(
        code: HlsErrorCode.invalidFileName,
        message: 'fileName cannot be empty',
      );
    }

    if (options.retryAttempts < 0) {
      throw const HlsDownloadException(
        code: HlsErrorCode.invalidOptions,
        message: 'retryAttempts cannot be negative',
      );
    }

    if (options.outputFileExtension.trim().isEmpty) {
      throw const HlsDownloadException(
        code: HlsErrorCode.invalidOptions,
        message: 'outputFileExtension cannot be empty',
      );
    }

    if (options.outputDirectoryPath != null &&
        options.outputDirectoryPath!.trim().isEmpty) {
      throw const HlsDownloadException(
        code: HlsErrorCode.invalidOptions,
        message: 'outputDirectoryPath cannot be blank',
      );
    }

    final hasBlankHeaderKey = options.customHeaders.keys.any(
      (key) => key.trim().isEmpty,
    );
    if (hasBlankHeaderKey) {
      throw const HlsDownloadException(
        code: HlsErrorCode.invalidOptions,
        message: 'customHeaders cannot contain blank keys',
      );
    }
  }

  Future<HlsResolvedManifest> resolveManifest({
    required String manifestUrl,
    required Map<String, String> customHeaders,
    required HlsVariantSelection variantSelection,
  }) async {
    final rootUri = Uri.parse(manifestUrl);
    return _resolveMediaPlaylist(
      originalUri: rootUri,
      currentUri: rootUri,
      customHeaders: customHeaders,
      variantSelection: variantSelection,
      depth: 0,
    );
  }

  Future<HlsResolvedManifest> _resolveMediaPlaylist({
    required Uri originalUri,
    required Uri currentUri,
    required Map<String, String> customHeaders,
    required HlsVariantSelection variantSelection,
    required int depth,
  }) async {
    if (depth > 5) {
      throw const HlsDownloadException(
        code: HlsErrorCode.playlistParseFailed,
        message: 'Exceeded maximum playlist nesting while resolving variants',
      );
    }

    final response = await _httpClient.get(currentUri, headers: customHeaders);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HlsDownloadException(
        code: HlsErrorCode.playlistParseFailed,
        message:
            'Failed to fetch playlist: HTTP ${response.statusCode} for $currentUri',
      );
    }

    final content = response.body;
    HlsPlaylist? parsed;
    try {
      parsed = await HlsPlaylistParser.create().parseString(
        currentUri,
        content,
      );
    } catch (_) {
      parsed = null;
    }

    if (parsed is HlsMasterPlaylist) {
      if (parsed.variants.isEmpty) {
        throw const HlsDownloadException(
          code: HlsErrorCode.emptyPlaylist,
          message: 'Master playlist does not contain any variants',
        );
      }
      final selectedVariant = _selectVariant(parsed.variants, variantSelection);
      final selectedUri = currentUri.resolveUri(selectedVariant.url);
      return _resolveMediaPlaylist(
        originalUri: originalUri,
        currentUri: selectedUri,
        customHeaders: customHeaders,
        variantSelection: variantSelection,
        depth: depth + 1,
      );
    }

    if (parsed is HlsMediaPlaylist) {
      final segments = _extractSegmentsFromMediaPlaylist(parsed, currentUri);
      if (segments.isNotEmpty) {
        return HlsResolvedManifest(
          originalManifestUri: originalUri,
          mediaPlaylistUri: currentUri,
          segments: segments,
        );
      }
    }

    final fallbackSegments = _extractSegmentsFallback(content, currentUri);
    if (fallbackSegments.isEmpty) {
      throw const HlsDownloadException(
        code: HlsErrorCode.emptyPlaylist,
        message: 'No downloadable segments were found in playlist',
      );
    }

    return HlsResolvedManifest(
      originalManifestUri: originalUri,
      mediaPlaylistUri: currentUri,
      segments: fallbackSegments,
    );
  }

  Variant _selectVariant(
    List<Variant> variants,
    HlsVariantSelection selection,
  ) {
    int score(Variant variant) => variant.format.bitrate ?? -1;

    switch (selection) {
      case HlsVariantSelection.first:
        return variants.first;
      case HlsVariantSelection.lowestBandwidth:
        return variants.reduce(
          (left, right) => score(left) <= score(right) ? left : right,
        );
      case HlsVariantSelection.highestBandwidth:
        return variants.reduce(
          (left, right) => score(left) >= score(right) ? left : right,
        );
    }
  }

  List<HlsSegmentEntry> _extractSegmentsFromMediaPlaylist(
    HlsMediaPlaylist playlist,
    Uri playlistUri,
  ) {
    final entries = <HlsSegmentEntry>[];
    final emittedInitializationUris = <String>{};
    var sequenceNumber = playlist.mediaSequence ?? 0;

    for (final segment in playlist.segments) {
      final initSegmentUrl = segment.initializationSegment?.url;
      if (initSegmentUrl != null && initSegmentUrl.trim().isNotEmpty) {
        final initUri = playlistUri.resolve(initSegmentUrl.trim());
        final initUriString = initUri.toString();
        if (emittedInitializationUris.add(initUriString)) {
          entries.add(
            HlsSegmentEntry(
              uri: initUri,
              sequenceNumber: sequenceNumber,
              isInitializationSegment: true,
            ),
          );
        }
      }

      final segmentUrl = segment.url;
      if (segmentUrl == null || segmentUrl.trim().isEmpty) {
        sequenceNumber++;
        continue;
      }

      final encryptionKeyUri = segment.fullSegmentEncryptionKeyUri;
      entries.add(
        HlsSegmentEntry(
          uri: playlistUri.resolve(segmentUrl.trim()),
          sequenceNumber: sequenceNumber,
          encryptionKeyUri: encryptionKeyUri == null
              ? null
              : playlistUri.resolve(encryptionKeyUri),
          encryptionIvHex: segment.encryptionIV,
        ),
      );
      sequenceNumber++;
    }
    return entries;
  }

  List<HlsSegmentEntry> _extractSegmentsFallback(
    String content,
    Uri playlistUri,
  ) {
    final entries = <HlsSegmentEntry>[];
    String? currentKeyUri;
    String? currentIvHex;
    var sequenceNumber = 0;

    for (final rawLine in const LineSplitter().convert(content)) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }

      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        final value = line.substring('#EXT-X-MEDIA-SEQUENCE:'.length).trim();
        final parsed = int.tryParse(value);
        if (parsed != null) {
          sequenceNumber = parsed;
        }
        continue;
      }

      if (line.startsWith('#EXT-X-KEY:')) {
        final attributes = _parseAttributes(
          line.substring('#EXT-X-KEY:'.length),
        );
        final method = attributes['METHOD']?.toUpperCase();
        if (method == 'NONE') {
          currentKeyUri = null;
          currentIvHex = null;
        } else {
          final keyUri = attributes['URI'];
          currentKeyUri = keyUri == null
              ? null
              : playlistUri.resolve(keyUri).toString();
          currentIvHex = attributes['IV'];
        }
        continue;
      }

      if (line.startsWith('#')) {
        continue;
      }

      entries.add(
        HlsSegmentEntry(
          uri: playlistUri.resolve(line),
          sequenceNumber: sequenceNumber,
          encryptionKeyUri: currentKeyUri == null
              ? null
              : Uri.parse(currentKeyUri),
          encryptionIvHex: currentIvHex,
        ),
      );
      sequenceNumber++;
    }

    return entries;
  }

  Map<String, String> _parseAttributes(String input) {
    final attributes = <String, String>{};
    final regex = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');

    for (final match in regex.allMatches(input)) {
      final key = match.group(1);
      var value = match.group(2) ?? '';
      if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
        value = value.substring(1, value.length - 1);
      }
      if (key != null) {
        attributes[key] = value;
      }
    }
    return attributes;
  }

  Future<void> combineSegmentsToFile({
    required List<HlsSegmentEntry> segments,
    required String segmentDirectoryPath,
    required String outputFilePath,
    required Map<String, String> customHeaders,
  }) async {
    if (segments.isEmpty) {
      throw const HlsDownloadException(
        code: HlsErrorCode.emptyPlaylist,
        message: 'No segments to combine',
      );
    }

    final encryptionKeys = await _fetchEncryptionKeys(
      segments: segments,
      customHeaders: customHeaders,
    );

    final outputFile = File(outputFilePath);
    if (!await outputFile.parent.exists()) {
      await outputFile.parent.create(recursive: true);
    }

    final sink = outputFile.openWrite(mode: FileMode.write);
    try {
      for (var i = 0; i < segments.length; i++) {
        final segment = segments[i];
        final segmentPath = p.join(
          segmentDirectoryPath,
          segmentFileName(i + 1),
        );
        final segmentFile = File(segmentPath);
        if (!await segmentFile.exists()) {
          throw HlsDownloadException(
            code: HlsErrorCode.segmentMissing,
            message: 'Missing downloaded segment: $segmentPath',
          );
        }

        var bytes = await segmentFile.readAsBytes();
        final keyUriString = segment.encryptionKeyUri?.toString();
        if (keyUriString != null) {
          final keyBytes = encryptionKeys[keyUriString];
          if (keyBytes == null) {
            throw HlsDownloadException(
              code: HlsErrorCode.encryptionKeyFetchFailed,
              message: 'Missing encryption key bytes for $keyUriString',
            );
          }
          bytes = _decryptSegment(
            encryptedBytes: bytes,
            keyBytes: keyBytes,
            sequenceNumber: segment.sequenceNumber,
            ivHex: segment.encryptionIvHex,
          );
        }
        sink.add(bytes);
      }
    } on HlsDownloadException {
      rethrow;
    } catch (error, stackTrace) {
      throw HlsDownloadException(
        code: HlsErrorCode.combineFailed,
        message: 'Failed while combining segments',
        cause: error,
        stackTrace: stackTrace,
      );
    } finally {
      await sink.close();
    }
  }

  Future<Map<String, Uint8List>> _fetchEncryptionKeys({
    required List<HlsSegmentEntry> segments,
    required Map<String, String> customHeaders,
  }) async {
    final keys = <String, Uint8List>{};
    final keyUris = segments
        .map((entry) => entry.encryptionKeyUri?.toString())
        .whereType<String>()
        .toSet();

    for (final keyUri in keyUris) {
      final response = await _httpClient.get(
        Uri.parse(keyUri),
        headers: customHeaders,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HlsDownloadException(
          code: HlsErrorCode.encryptionKeyFetchFailed,
          message:
              'Failed to fetch encryption key: HTTP ${response.statusCode} for $keyUri',
        );
      }
      keys[keyUri] = response.bodyBytes;
    }
    return keys;
  }

  Uint8List _decryptSegment({
    required Uint8List encryptedBytes,
    required Uint8List keyBytes,
    required int sequenceNumber,
    required String? ivHex,
  }) {
    if (keyBytes.length != 16 &&
        keyBytes.length != 24 &&
        keyBytes.length != 32) {
      throw HlsDownloadException(
        code: HlsErrorCode.combineFailed,
        message: 'Unsupported AES key length: ${keyBytes.length} bytes',
      );
    }

    final ivBytes = _resolveIvBytes(
      ivHex: ivHex,
      sequenceNumber: sequenceNumber,
    );

    try {
      final encrypter = Encrypter(
        AES(Key(keyBytes), mode: AESMode.cbc, padding: null),
      );
      return Uint8List.fromList(
        encrypter.decryptBytes(Encrypted(encryptedBytes), iv: IV(ivBytes)),
      );
    } catch (_) {
      final encrypter = Encrypter(AES(Key(keyBytes), mode: AESMode.cbc));
      return Uint8List.fromList(
        encrypter.decryptBytes(Encrypted(encryptedBytes), iv: IV(ivBytes)),
      );
    }
  }

  Uint8List _resolveIvBytes({
    required String? ivHex,
    required int sequenceNumber,
  }) {
    if (ivHex == null || ivHex.isEmpty) {
      final iv = Uint8List(16);
      final data = ByteData.sublistView(iv);
      data.setUint64(8, sequenceNumber);
      return iv;
    }

    var normalized = ivHex.trim();
    if (normalized.startsWith('0x') || normalized.startsWith('0X')) {
      normalized = normalized.substring(2);
    }

    final rawBytes = _decodeHex(normalized);
    if (rawBytes.length == 16) {
      return rawBytes;
    }
    if (rawBytes.length > 16) {
      return Uint8List.fromList(rawBytes.sublist(rawBytes.length - 16));
    }

    final padded = Uint8List(16);
    padded.setRange(16 - rawBytes.length, 16, rawBytes);
    return padded;
  }

  Uint8List _decodeHex(String hex) {
    var normalized = hex;
    if (normalized.length.isOdd) {
      normalized = '0$normalized';
    }
    final bytes = Uint8List(normalized.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      final start = i * 2;
      final value = normalized.substring(start, start + 2);
      bytes[i] = int.parse(value, radix: 16);
    }
    return bytes;
  }
}
