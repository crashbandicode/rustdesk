import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;

import 'common.dart';
import 'consts.dart';
import 'models/platform_model.dart';

class DiagnosticBundleResult {
  const DiagnosticBundleResult({
    required this.path,
    required this.fileCount,
    required this.includedBytes,
    required this.omittedFileCount,
    required this.shared,
  });

  final String path;
  final int fileCount;
  final int includedBytes;
  final int omittedFileCount;
  final bool shared;
}

class DiagnosticSupport {
  DiagnosticSupport._();

  static bool get enabled =>
      bind.mainGetLocalOption(key: kOptionDiagnosticMode) == 'Y';

  static int get captureStartedMillis =>
      int.tryParse(
        bind.mainGetLocalOption(key: kOptionDiagnosticStartedAt),
      ) ??
      0;

  static Future<void> setEnabled(bool value) async {
    if (value) {
      final started = DateTime.now().millisecondsSinceEpoch;
      await bind.mainSetLocalOption(
        key: kOptionDiagnosticStartedAt,
        value: started.toString(),
      );
      await bind.mainSetLocalOption(key: kOptionDiagnosticMode, value: 'Y');
      await event('diagnostic_mode_enabled', {
        'capture_started_millis': started,
      });
    } else {
      await event('diagnostic_mode_disabled');
      await bind.mainSetLocalOption(key: kOptionDiagnosticMode, value: 'N');
    }
  }

  static Future<void> event(
    String name, [
    Map<String, Object?> fields = const {},
  ]) async {
    if (!enabled) return;
    try {
      await bind.mainWriteDiagnosticEvent(
        event: name,
        fieldsJson: jsonEncode(fields),
      );
    } catch (_) {
      // Diagnostics must never alter normal connection behavior.
    }
  }

  static Future<DiagnosticBundleResult?> exportBundle() async {
    if (isWeb) {
      throw UnsupportedError('Diagnostic export is not available on web');
    }

    final createdAt = DateTime.now().toUtc();
    final filename =
        'rustdesk-diagnostics-${_filenameTimestamp(createdAt)}.zip';
    final destination = await _chooseDestination(filename);
    if (destination == null) return null;

    await event('diagnostic_export_started');
    final metadata = jsonEncode({
      'version': await bind.mainGetVersion(),
      'build_identity': bind.mainGetBuildIdentitySync(),
      'build_date': await bind.mainGetBuildDate(),
      'platform': Platform.operatingSystem,
      'platform_version': Platform.operatingSystemVersion,
      'locale': Platform.localeName,
      'diagnostic_mode_enabled': enabled,
      'capture_started_millis': captureStartedMillis,
    });
    final rawResult = await bind.mainExportDiagnosticBundle(
      destination: destination,
      captureStartedMillis: captureStartedMillis,
      metadataJson: metadata,
    );
    final result = jsonDecode(rawResult) as Map<String, dynamic>;
    if (result['ok'] != true) {
      throw Exception(result['error'] ?? 'Diagnostic export failed');
    }

    final bundlePath = result['path'] as String? ?? destination;
    var shared = false;
    if (isAndroid) {
      shared = await platformFFI.invokeMethod(
              'share_diagnostic_bundle', bundlePath) ==
          true;
      await _pruneAndroidBundles(path.dirname(bundlePath));
    }
    await event('diagnostic_export_completed', {
      'file_count': result['file_count'] ?? 0,
      'included_uncompressed_bytes': result['included_uncompressed_bytes'] ?? 0,
      'omitted_file_count': result['omitted_file_count'] ?? 0,
    });

    return DiagnosticBundleResult(
      path: bundlePath,
      fileCount: (result['file_count'] as num?)?.toInt() ?? 0,
      includedBytes:
          (result['included_uncompressed_bytes'] as num?)?.toInt() ?? 0,
      omittedFileCount: (result['omitted_file_count'] as num?)?.toInt() ?? 0,
      shared: shared,
    );
  }

  static Future<String?> _chooseDestination(String filename) async {
    if (isAndroid) {
      final directoryPath = await platformFFI.invokeMethod(
        'get_diagnostic_directory',
      );
      if (directoryPath is! String || directoryPath.isEmpty) {
        throw Exception('Android storage directory is unavailable');
      }
      final directory = Directory(directoryPath);
      await directory.create(recursive: true);
      return path.join(directory.path, filename);
    }

    final selected = await FilePicker.platform.saveFile(
      dialogTitle: 'Save RustDesk diagnostic bundle',
      fileName: filename,
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (selected == null) return null;
    return selected.toLowerCase().endsWith('.zip') ? selected : '$selected.zip';
  }

  static Future<void> _pruneAndroidBundles(String directoryPath) async {
    try {
      final directory = Directory(directoryPath);
      final bundles = await directory
          .list()
          .where((entity) =>
              entity is File && entity.path.toLowerCase().endsWith('.zip'))
          .cast<File>()
          .toList();
      final dated = <({File file, DateTime modified})>[];
      for (final file in bundles) {
        dated.add((file: file, modified: await file.lastModified()));
      }
      dated.sort((left, right) => right.modified.compareTo(left.modified));
      for (final old in dated.skip(3)) {
        await old.file.delete();
      }
    } catch (_) {
      // Retention cleanup is best effort and must not hide a successful export.
    }
  }

  static String _filenameTimestamp(DateTime time) =>
      time.toIso8601String().replaceAll(':', '-').replaceAll('.', '-');
}
