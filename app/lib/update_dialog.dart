part of 'main.dart';

// In-app updates. CI (.github/workflows/build-apk.yml) publishes every build
// to the rolling "latest" release, together with a small version.json:
// {"build": 42, "version": "1.0.42", "notes": "..."}. The app compares that
// build number with its own and offers the update — see _checkForUpdate().
const _latestReleaseUrl =
    'https://github.com/soozyyy/VspoM/releases/download/latest';

Future<Map<String, dynamic>?> _fetchLatestVersion() async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 6);
  try {
    final request = await client
        .getUrl(Uri.parse('$_latestReleaseUrl/version.json'))
        .timeout(const Duration(seconds: 6));
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final body = await response.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  } catch (_) {
    // Offline, or mid-publish (CI briefly removes the old assets) — just
    // don't offer an update this launch.
    return null;
  } finally {
    client.close(force: true);
  }
}

/// "Update available" dialog: current vs. new version, what's new, and an
/// Update button that downloads the APK (with progress) and hands it to
/// Android's installer. The user then taps Install on the system screen —
/// Android never allows a sideloaded app to skip that tap.
class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({
    required this.channel,
    required this.currentVersion,
    required this.newVersion,
    required this.notes,
  });

  final MethodChannel channel;
  final String currentVersion;
  final String newVersion;
  final String notes;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _downloading = false;
  double? _progress; // null = size unknown (indeterminate bar)
  String? _error;

  Future<void> _update() async {
    setState(() {
      _downloading = true;
      _progress = null;
      _error = null;
    });
    final client = HttpClient();
    try {
      final path = await widget.channel.invokeMethod<String>('updateApkPath');
      final request =
          await client.getUrl(Uri.parse('$_latestReleaseUrl/app-release.apk'));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final total = response.contentLength;
      final sink = File(path!).openWrite();
      var received = 0;
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && mounted) setState(() => _progress = received / total);
      }
      await sink.close();
      await widget.channel.invokeMethod('installApk', {'path': path});
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = 'Download failed. Check your connection and try again.';
        });
      }
    } finally {
      client.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return AlertDialog(
      title: const Text('Update available'),
      content: SingleChildScrollView(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Current version: ${widget.currentVersion}', style: muted),
          const SizedBox(height: 2),
          Text(
            'New version: ${widget.newVersion}',
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (widget.notes.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text("What's new", style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(widget.notes),
          ],
          if (_downloading) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 6),
            Text(
              _progress == null
                  ? 'Downloading...'
                  : 'Downloading... ${(_progress! * 100).round()}%',
              style: muted,
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _downloading ? null : () => Navigator.of(context).pop(),
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: _downloading ? null : _update,
          child: Text(_error == null ? 'Update' : 'Retry'),
        ),
      ],
    );
  }
}
