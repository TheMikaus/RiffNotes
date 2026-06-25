import 'dart:io';

import 'package:path/path.dart' as path;

class PracticeSyncRepository {
  Future<SyncResult> uploadPractice({
    required Directory practiceFolder,
    required Directory syncRoot,
  }) async {
    final target =
        Directory(path.join(syncRoot.path, path.basename(practiceFolder.path)));
    return _copyPractice(source: practiceFolder, target: target);
  }

  Future<SyncResult> downloadPractice({
    required Directory localPracticeFolder,
    required Directory syncRoot,
  }) async {
    final source = Directory(
        path.join(syncRoot.path, path.basename(localPracticeFolder.path)));
    if (!await source.exists()) {
      throw StateError(
          'No matching practice folder exists in the sync folder.');
    }
    return _copyPractice(source: source, target: localPracticeFolder);
  }

  Future<SyncResult> _copyPractice({
    required Directory source,
    required Directory target,
  }) async {
    if (!await source.exists()) {
      throw StateError('Practice folder does not exist.');
    }
    await target.create(recursive: true);
    var copied = 0;
    var skipped = 0;
    await for (final entity in source.list(recursive: true)) {
      final relative = path.relative(entity.path, from: source.path);
      if (_shouldSkip(relative)) {
        skipped += 1;
        continue;
      }
      final destination = path.join(target.path, relative);
      if (entity is Directory) {
        await Directory(destination).create(recursive: true);
      } else if (entity is File) {
        await File(destination).parent.create(recursive: true);
        await entity.copy(destination);
        copied += 1;
      }
    }
    return SyncResult(copiedFiles: copied, skippedItems: skipped);
  }

  bool _shouldSkip(String relativePath) {
    final parts = path.split(relativePath).map((item) => item.toLowerCase());
    return parts.any((part) =>
        part == '.riffnotes-cache' ||
        part == '.backup' ||
        part == 'cache' ||
        part.endsWith('.tmp'));
  }
}

class SyncResult {
  const SyncResult({required this.copiedFiles, required this.skippedItems});

  final int copiedFiles;
  final int skippedItems;
}
