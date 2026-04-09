# background_downloader_hls

A Flutter package to download HLS playlists (`.m3u8`) and combine their segments into a single file. Built efficiently on top of [`background_downloader`](https://pub.dev/packages/background_downloader).

## Features
* **Smart Playlists:** Auto-resolves master playlists (choose highest, lowest, or first variant bandwidth).
* **Secure & Resilient:** Supports AES-128 decryption, fallback parsing, and strict input validation.
* **Tidy:** Deterministic segment combining with automatic temp-file cleanup.
* **Quiet:** Callback-based logging—zero noisy `print` statements.

## Installation

Add it to your `pubspec.yaml`:

```yaml
dependencies:
  background_downloader_hls: ^0.1.0
```

## Quick Start

The recommended approach for all new integrations is `downloadToFile`:

```dart
import 'package:background_downloader_hls/background_downloader_hls.dart';

final downloader = HlsDownloader();

final result = await downloader.downloadToFile(
  '[https://example.com/playlist.m3u8](https://example.com/playlist.m3u8)',
  'my_video',
  options: const HlsDownloadOptions(
    variantSelection: HlsVariantSelection.highestBandwidth,
    outputFileExtension: 'mp4',
  ),
);

if (result.isSuccess) {
  // Access your combined file here
  print('Saved to: ${result.outputFilePath}');
}
```
*(Note: A legacy `download()` method remains available for backwards compatibility).*

## Logging

Logging is completely off by default. To capture logs, pass a callback when initializing the downloader:

```dart
final downloader = HlsDownloader(
  logCallback: (level, message, error, stackTrace) {
    // Pipe to your own logger or monitoring system
  },
);
```

## Error Handling

Failures are predictable. The package throws an `HlsDownloadException` for expected errors, returning specific codes so you can handle them gracefully:

* `invalid_url` / `invalid_file_name` / `invalid_options`
* `playlist_parse_failed` / `empty_playlist`
* `segment_download_failed` / `segment_missing`
* `encryption_key_fetch_failed`
* `combine_failed` / `unexpected`

## Notes & Limitations

* **Path Handling:** Uses platform-safe paths. Temporary segments are stored in the app documents directory by default.
* **Simple Merging:** Segment combining is byte-append based. If you need strict remuxing or transcoding, post-process the combined file with a toolchain like FFmpeg.
* **DRM:** Advanced DRM or complex server-side authorization workflows are outside the scope of this package.