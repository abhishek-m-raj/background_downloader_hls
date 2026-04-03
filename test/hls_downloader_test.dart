import 'package:background_downloader_hls/background_downloader_hls.dart';
import 'package:background_downloader_hls/helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloaderHelper', () {
    test('sanitizes file names', () {
      final helper = DownloaderHelper();
      expect(helper.sanitizeFileName('my<bad>:name?.mp4'), 'mybadname.mp4');
      helper.dispose();
    });

    test('builds output file name with extension when missing', () {
      final helper = DownloaderHelper();
      expect(helper.buildOutputFileName('video_name', 'mp4'), 'video_name.mp4');
      expect(
        helper.buildOutputFileName('video_name.mkv', 'mp4'),
        'video_name.mkv',
      );
      helper.dispose();
    });
  });

  group('HlsDownloadOptions', () {
    test('copyWith overrides selected values', () {
      const options = HlsDownloadOptions(retryAttempts: 3);
      final updated = options.copyWith(
        retryAttempts: 5,
        outputFileExtension: 'ts',
      );

      expect(updated.retryAttempts, 5);
      expect(updated.outputFileExtension, 'ts');
      expect(updated.combineSegments, true);
    });
  });

  group('HlsDownloader validation', () {
    test('throws invalid_url for malformed manifest', () async {
      final helper = DownloaderHelper();
      expect(
        () => helper.validateDownloadRequest(
          manifestUrl: 'not-a-url',
          fileName: 'video',
          options: const HlsDownloadOptions(),
        ),
        throwsA(
          isA<HlsDownloadException>().having(
            (error) => error.code,
            'code',
            HlsErrorCode.invalidUrl,
          ),
        ),
      );
      helper.dispose();
    });

    test('throws invalid_file_name for blank output name', () async {
      final helper = DownloaderHelper();
      expect(
        () => helper.validateDownloadRequest(
          manifestUrl: 'https://example.com/playlist.m3u8',
          fileName: '   ',
          options: const HlsDownloadOptions(),
        ),
        throwsA(
          isA<HlsDownloadException>().having(
            (error) => error.code,
            'code',
            HlsErrorCode.invalidFileName,
          ),
        ),
      );
      helper.dispose();
    });

    test('throws invalid_options for negative retryAttempts', () async {
      final helper = DownloaderHelper();
      expect(
        () => helper.validateDownloadRequest(
          manifestUrl: 'https://example.com/playlist.m3u8',
          fileName: 'video',
          options: const HlsDownloadOptions(retryAttempts: -1),
        ),
        throwsA(
          isA<HlsDownloadException>().having(
            (error) => error.code,
            'code',
            HlsErrorCode.invalidOptions,
          ),
        ),
      );
      helper.dispose();
    });
  });
}
