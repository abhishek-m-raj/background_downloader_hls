import 'dart:async';

import 'package:background_downloader_hls/background_downloader_hls.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HLS Downloader Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'HLS Downloader Example'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  static const _exampleDownloadId = 'example-hls-download';
  final HlsDownloader _downloader = HlsDownloader(
    logCallback: (level, message, [error, stackTrace]) {
      debugPrint('[${level.name}] $message');
    },
  );

  var _status = 'Idle';
  var _isDownloading = false;
  var _overallProgress = 0.0;
  StreamSubscription<HlsOverallTaskUpdate>? _overallSubscription;

  static const _sampleM3u8 =
      'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

  Future<void> _startDownload() async {
    setState(() {
      _isDownloading = true;
      _status = 'Resolving playlist...';
      _overallProgress = 0;
    });

    await _overallSubscription?.cancel();
    _overallSubscription = _downloader.listen(_exampleDownloadId).listen(
      (update) {
        if (!mounted) {
          return;
        }
        final done = update.completedSegments + update.failedSegments;
        setState(() {
          _overallProgress = update.progress;
          _status =
              '${update.phase.name.toUpperCase()} '
              '(${(update.progress * 100).toStringAsFixed(1)}%) '
              '$done/${update.totalSegments}'
              '${update.message == null ? '' : ' - ${update.message}'}';
        });
      },
    );

    try {
      final result = await _downloader.downloadToFile(
        _sampleM3u8,
        'sample_video',
        options: const HlsDownloadOptions(
          downloadId: _exampleDownloadId,
          variantSelection: HlsVariantSelection.highestBandwidth,
          outputFileExtension: 'mp4',
          logLevel: HlsLogLevel.info,
        ),
      );

      setState(() {
        _status = result.outputFilePath == null
            ? 'Downloaded ${result.segmentCount} segments. Task: ${result.finalTaskId ?? 'none'}'
            : 'Saved to: ${result.outputFilePath}. Task: ${result.finalTaskId ?? 'none'}';
      });
    } on HlsDownloadException catch (error) {
      setState(() {
        _status = 'Error (${error.code}): ${error.message}';
      });
    } catch (error) {
      setState(() {
        _status = 'Unexpected error: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isDownloading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _overallSubscription?.cancel();
    _downloader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              _status,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: LinearProgressIndicator(value: _overallProgress),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _isDownloading ? null : _startDownload,
              icon: const Icon(Icons.download),
              label: Text(
                _isDownloading ? 'Downloading...' : 'Download Sample',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
