# background_downloader_hls

`background_downloader_hls` is a Flutter package for downloading HLS playlists
(`.m3u8`) and combining segments into a single file.

It is built on top of
[`background_downloader`](https://pub.dev/packages/background_downloader),
with additional HLS-specific features:

- input validation with typed exceptions
- master playlist variant selection
- fallback parsing for irregular playlists
- optional AES-128 segment decryption (when keys are available)
- cross-platform path handling
- minimal, callback-based logging (no noisy `print` logs)

## Features

- Download media playlists directly, or resolve master playlists automatically.
- Choose variant strategy:
	- highest bandwidth
	- lowest bandwidth
	- first variant
- Combine downloaded segments in deterministic order.
- Optional cleanup of temporary segment files.
- Typed options/result objects for production integrations.

## Installation

Add dependency:

```yaml
dependencies:
	background_downloader_hls: ^0.1.0
```

Then run:

```bash
flutter pub get
```

## Quick Start

```dart
import 'package:background_downloader_hls/background_downloader_hls.dart';

final downloader = HlsDownloader();

final result = await downloader.downloadToFile(
	'https://example.com/playlist.m3u8',
	'my_video',
	options: const HlsDownloadOptions(
		variantSelection: HlsVariantSelection.highestBandwidth,
		outputFileExtension: 'mp4',
	),
);

if (result.isSuccess) {
	// result.outputFilePath -> combined file path
}
```

## Logging

Logging is callback-based and off by default unless you provide a callback.

```dart
final downloader = HlsDownloader(
	logCallback: (level, message, error, stackTrace) {
		// Send to your logger/monitoring system.
	},
);

await downloader.downloadToFile(
	'https://example.com/playlist.m3u8',
	'video',
	options: const HlsDownloadOptions(logLevel: HlsLogLevel.info),
);
```

## API Overview

### `downloadToFile`

```dart
Future<HlsDownloadResult> downloadToFile(
	String manifestUrl,
	String fileName, {
	HlsDownloadOptions options = const HlsDownloadOptions(),
})
```

### `download` (legacy compatibility)

```dart
Future<bool> download(
	String streamLink,
	String fileName, {
	int retryAttempts = 3,
	int parallelBatches = 5,
	Map<String, String> customHeaders = const {},
	String? subsUrl,
})
```

`downloadToFile` is recommended for new integrations.

## Validation and Errors

The package throws `HlsDownloadException` for expected failures.

Common codes:

- `invalid_url`
- `invalid_file_name`
- `invalid_options`
- `playlist_parse_failed`
- `empty_playlist`
- `segment_download_failed`
- `segment_missing`
- `encryption_key_fetch_failed`
- `combine_failed`
- `unexpected`

## Platform Notes

- Works with Flutter platforms supported by `background_downloader`.
- Uses platform-safe path handling (no hardcoded separators).
- Temporary segments are stored under app documents by default.

## Limitations

- Some HLS streams require advanced DRM or server-side authorization workflows
	that are outside the scope of this package.
- Segment combine is byte-append based. For strict remux/transcode workflows,
	post-process with a media toolchain like FFmpeg.
