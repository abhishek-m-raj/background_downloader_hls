## 0.1.0

* Production hardening release.
* Added typed API models:
	* `HlsDownloadOptions`
	* `HlsDownloadResult`
	* `HlsDownloadException`
* Added manifest resolution for both master and media playlists.
* Added variant selection strategies (highest/lowest/first).
* Added fallback parser for non-standard playlist formatting.
* Added optional AES-128 segment decryption flow.
* Replaced `print`-style logging with callback-based minimal logging.
* Added stronger validation for URL, filename, headers, and options.
* Improved cross-platform path handling.
* Added cleanup controls for temporary segment files.
* Added detailed README with usage and API guidance.

## 0.0.1

* TODO: Describe initial release.
