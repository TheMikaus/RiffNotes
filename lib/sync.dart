import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

class PracticeSyncRepository {
  Future<List<SyncFileCandidate>> listUploadCandidates({
    required Directory practiceFolder,
    required Directory syncRoot,
  }) async {
    final target =
        Directory(path.join(syncRoot.path, path.basename(practiceFolder.path)));
    return _listFileCandidates(source: practiceFolder, target: target);
  }

  Future<SyncResult> uploadPractice({
    required Directory practiceFolder,
    required Directory syncRoot,
    bool changedOnly = true,
    bool deleteMissingFiles = false,
  }) async {
    final target =
        Directory(path.join(syncRoot.path, path.basename(practiceFolder.path)));
    return _copyPractice(
      source: practiceFolder,
      target: target,
      changedOnly: changedOnly,
      deleteMissingFiles: deleteMissingFiles,
    );
  }

  Future<SyncResult> uploadPracticeSelection({
    required Directory practiceFolder,
    required Directory syncRoot,
    required Set<String> relativePaths,
    bool changedOnly = true,
    bool deleteMissingFiles = false,
  }) async {
    final target =
        Directory(path.join(syncRoot.path, path.basename(practiceFolder.path)));
    return _copyPractice(
      source: practiceFolder,
      target: target,
      allowedRelativePaths: relativePaths,
      changedOnly: changedOnly,
      deleteMissingFiles: deleteMissingFiles,
    );
  }

  Future<SyncResult> downloadPractice({
    required Directory localPracticeFolder,
    required Directory syncRoot,
    bool changedOnly = true,
    bool deleteMissingFiles = false,
  }) async {
    final source = Directory(
        path.join(syncRoot.path, path.basename(localPracticeFolder.path)));
    if (!await source.exists()) {
      throw StateError(
          'No matching practice folder exists in the sync folder.');
    }
    return _copyPractice(
      source: source,
      target: localPracticeFolder,
      changedOnly: changedOnly,
      deleteMissingFiles: deleteMissingFiles,
    );
  }

  Future<SyncResult> _copyPractice({
    required Directory source,
    required Directory target,
    Set<String>? allowedRelativePaths,
    bool changedOnly = true,
    bool deleteMissingFiles = false,
  }) async {
    if (!await source.exists()) {
      throw StateError('Practice folder does not exist.');
    }
    await target.create(recursive: true);
    var copied = 0;
    var skipped = 0;
    var deleted = 0;
    final normalizedAllowed = allowedRelativePaths
        ?.map(_normalizeRelativePath)
        .toSet();
    final expectedFiles = <String>{};
    await for (final entity in source.list(recursive: true)) {
      if (entity is! File) {
        continue;
      }
      final relative = path.relative(entity.path, from: source.path);
      if (_shouldSkip(relative)) {
        skipped += 1;
        continue;
      }
      final normalizedRelative = _normalizeRelativePath(relative);
      if (normalizedAllowed != null &&
          !normalizedAllowed.contains(normalizedRelative)) {
        continue;
      }
      expectedFiles.add(normalizedRelative);
      final destination = path.join(target.path, relative);
      if (changedOnly &&
          await _hasSameFileMetadata(entity, File(destination))) {
        skipped += 1;
        continue;
      }
      await File(destination).parent.create(recursive: true);
      await entity.copy(destination);
      final sourceStat = await entity.stat();
      await File(destination).setLastModified(sourceStat.modified);
      copied += 1;
    }
    if (deleteMissingFiles) {
      deleted = await _deleteUnexpectedFiles(
        target: target,
        expectedRelativePaths: expectedFiles,
      );
    }
    return SyncResult(
      copiedFiles: copied,
      skippedItems: skipped,
      deletedFiles: deleted,
    );
  }

  Future<List<SyncFileCandidate>> _listFileCandidates({
    required Directory source,
    required Directory target,
  }) async {
    if (!await source.exists()) {
      throw StateError('Practice folder does not exist.');
    }
    final candidates = <SyncFileCandidate>[];
    await for (final entity in source.list(recursive: true)) {
      if (entity is! File) continue;
      final relative = path.relative(entity.path, from: source.path);
      if (_shouldSkip(relative)) continue;
      final destination = File(path.join(target.path, relative));
      final isLikelyChanged =
          !await _hasSameFileMetadata(entity, destination);
      candidates.add(SyncFileCandidate(
        relativePath: _normalizeRelativePath(relative),
        existsInSync: await destination.exists(),
        sizeBytes: await entity.length(),
        isLikelyChanged: isLikelyChanged,
      ));
    }
    candidates.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    return candidates;
  }

  String _normalizeRelativePath(String value) => value.replaceAll('\\', '/');

  Future<bool> _hasSameFileMetadata(File source, File destination) async {
    if (!await destination.exists()) return false;
    final sourceStat = await source.stat();
    final destinationStat = await destination.stat();
    return sourceStat.size == destinationStat.size &&
        sourceStat.modified.toUtc() == destinationStat.modified.toUtc();
  }

  Future<int> _deleteUnexpectedFiles({
    required Directory target,
    required Set<String> expectedRelativePaths,
  }) async {
    var deleted = 0;
    await for (final entity in target.list(recursive: true)) {
      if (entity is! File) continue;
      final relative = _normalizeRelativePath(
        path.relative(entity.path, from: target.path),
      );
      if (_shouldSkip(relative)) continue;
      if (expectedRelativePaths.contains(relative)) continue;
      await entity.delete();
      deleted += 1;
    }
    await _cleanupEmptyDirectories(target);
    return deleted;
  }

  Future<void> _cleanupEmptyDirectories(Directory root) async {
    final directories = <Directory>[];
    await for (final entity in root.list(recursive: true)) {
      if (entity is Directory) {
        directories.add(entity);
      }
    }
    directories.sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final directory in directories) {
      if (await directory.list().isEmpty) {
        await directory.delete();
      }
    }
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
  const SyncResult({
    required this.copiedFiles,
    required this.skippedItems,
    this.deletedFiles = 0,
  });

  final int copiedFiles;
  final int skippedItems;
  final int deletedFiles;
}

class SyncFileCandidate {
  const SyncFileCandidate({
    required this.relativePath,
    required this.existsInSync,
    required this.sizeBytes,
    required this.isLikelyChanged,
  });

  final String relativePath;
  final bool existsInSync;
  final int sizeBytes;
  final bool isLikelyChanged;
}
