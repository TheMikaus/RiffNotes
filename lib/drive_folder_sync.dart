import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'activity.dart';
import 'drive_file_store.dart';
import 'sync_policy.dart';

typedef DriveDebugLog = void Function(String message);

class GoogleDriveSyncResult {
  const GoogleDriveSyncResult({
    required this.copiedFiles,
    required this.skippedItems,
    this.deletedFiles = 0,
    this.skippedLocalNewer = 0,
  });

  final int copiedFiles;
  final int skippedItems;
  final int deletedFiles;

  /// Files left alone during a download because the local copy was newer.
  /// Surfaced to the user so a protected edit never looks like a silent no-op.
  final int skippedLocalNewer;
}

/// Folder sync against a [DriveFileStore], independent of the Drive API.
class DriveFolderSync {
  DriveFolderSync(this._store);

  final DriveFileStore _store;

  Future<GoogleDriveSyncResult> uploadLocalFolder({
    required Directory localFolder,
    required String driveRootFolderId,
    bool changedOnly = true,
    bool deleteMissingFiles = false,
    bool includeLocalRootFolder = true,
    bool Function()? shouldCancel,
    void Function(String message)? statusUpdate,
    Set<String>? allowedRelativePaths,
    DriveDebugLog? debugLog,
  }) async {
    if (!await localFolder.exists()) {
      throw StateError('Local folder was not found.');
    }

    final normalizedAllowed =
        allowedRelativePaths?.map((item) => item.replaceAll('\\', '/')).toSet();
    final practiceFolderId = includeLocalRootFolder
        ? await _ensureChildFolder(
            parentId: driveRootFolderId,
            folderName: path.basename(localFolder.path),
          )
        : driveRootFolderId;
    final folderCache = <String, String>{'': practiceFolderId};

    final remoteFiles = await listFilesRecursive(practiceFolderId);
    final remoteByRelative = {
      for (final item in remoteFiles) item.relativePath: item,
    };

    var copied = 0;
    var skipped = 0;
    var deleted = 0;
    final expected = <String>{};
    var scannedFiles = 0;
    var skippedFiltered = 0;
    var skippedUnselected = 0;
    var skippedUnchanged = 0;
    final unchangedSamples = <String>[];
    debugLog?.call(
      'sync.drive.upload start local="${localFolder.path}" '
      'driveRootId="$driveRootFolderId" practiceFolderId="$practiceFolderId" '
      'changedOnly=$changedOnly deleteMissingFiles=$deleteMissingFiles '
      'selection=${normalizedAllowed?.length ?? 'all'} '
      'remoteFiles=${remoteFiles.length}',
    );
    statusUpdate?.call('Scanning Google Drive upload source…');

    await for (final entity in localFolder.list(recursive: true)) {
      if (shouldCancel?.call() ?? false) {
        throw const ActivityCancelledException();
      }
      if (entity is! File) continue;
      scannedFiles += 1;
      final relative = path
          .relative(entity.path, from: localFolder.path)
          .replaceAll('\\', '/');
      if (shouldSkipSyncPath(relative)) {
        skipped += 1;
        skippedFiltered += 1;
        continue;
      }
      if (normalizedAllowed != null && !normalizedAllowed.contains(relative)) {
        skippedUnselected += 1;
        continue;
      }
      expected.add(relative);

      final remote = remoteByRelative[relative];
      final localStat = await entity.stat();
      statusUpdate?.call('Uploading $relative…');
      if (changedOnly && remote != null && _sameFile(remote, localStat)) {
        skipped += 1;
        skippedUnchanged += 1;
        if (unchangedSamples.length < 5) {
          unchangedSamples.add(relative);
        }
        continue;
      }

      final folderRelative = path.dirname(relative).replaceAll('\\', '/');
      final parentFolderId = await _ensureDriveFolderPath(
          folderRelative, practiceFolderId, folderCache);
      final name = path.basename(relative);
      // The local modification time is written through to the remote store so
      // the next run can recognise this file as unchanged. Letting the store
      // stamp its own time makes change detection permanently impossible: the
      // remote time would never equal the local one, and every file would
      // re-upload on every sync forever.
      if (remote == null) {
        await _store.createFile(
          parentId: parentFolderId,
          name: name,
          local: entity,
          modifiedTime: localStat.modified.toUtc(),
        );
      } else {
        await _store.updateFile(
          fileId: remote.id,
          local: entity,
          modifiedTime: localStat.modified.toUtc(),
        );
      }
      copied += 1;
    }

    if (deleteMissingFiles) {
      statusUpdate?.call('Removing remote files missing locally…');
      for (final item in remoteFiles) {
        if (shouldCancel?.call() ?? false) {
          throw const ActivityCancelledException();
        }
        if (shouldSkipSyncPath(item.relativePath)) continue;
        if (expected.contains(item.relativePath)) continue;
        await _store.deleteFile(item.id);
        deleted += 1;
      }
    }

    debugLog?.call(
      'sync.drive.upload done scanned=$scannedFiles copied=$copied '
      'skipped=$skipped deleted=$deleted skipFiltered=$skippedFiltered '
      'skipUnselected=$skippedUnselected skipUnchanged=$skippedUnchanged '
      'expected=${expected.length}',
    );
    if (unchangedSamples.isNotEmpty) {
      debugLog?.call(
        'sync.drive.upload unchanged samples: ${unchangedSamples.join(', ')}',
      );
    }

    return GoogleDriveSyncResult(
      copiedFiles: copied,
      skippedItems: skipped,
      deletedFiles: deleted,
    );
  }

  Future<GoogleDriveSyncResult> downloadFolderToLocal({
    required Directory localFolder,
    required String driveRootFolderId,
    bool changedOnly = true,
    bool deleteMissingFiles = false,
    bool includeLocalRootFolder = true,
    bool overwriteNewerLocalFiles = false,
    bool Function()? shouldCancel,
    void Function(String message)? statusUpdate,
    DriveDebugLog? debugLog,
  }) async {
    final practiceFolderId = includeLocalRootFolder
        ? await _store.findFolder(
            parentId: driveRootFolderId,
            name: path.basename(localFolder.path),
          )
        : driveRootFolderId;
    if (practiceFolderId == null) {
      throw StateError('No matching practice folder exists in Google Drive.');
    }

    await localFolder.create(recursive: true);
    final remoteFiles = await listFilesRecursive(practiceFolderId);
    final expected = <String>{};
    var copied = 0;
    var skipped = 0;
    var deleted = 0;
    var skippedFiltered = 0;
    var skippedUnchanged = 0;
    var skippedLocalNewer = 0;
    final unchangedSamples = <String>[];
    final localNewerSamples = <String>[];
    debugLog?.call(
      'sync.drive.download start driveRootId="$driveRootFolderId" '
      'practiceFolderId="$practiceFolderId" local="${localFolder.path}" '
      'changedOnly=$changedOnly deleteMissingFiles=$deleteMissingFiles '
      'overwriteNewerLocalFiles=$overwriteNewerLocalFiles '
      'remoteFiles=${remoteFiles.length}',
    );
    statusUpdate?.call('Scanning Google Drive download source…');

    for (final remote in remoteFiles) {
      if (shouldCancel?.call() ?? false) {
        throw const ActivityCancelledException();
      }
      final relative = remote.relativePath;
      if (shouldSkipSyncPath(relative)) {
        skipped += 1;
        skippedFiltered += 1;
        continue;
      }
      expected.add(relative);
      final destination = File(path.join(localFolder.path, relative));
      final localStat =
          await destination.exists() ? await destination.stat() : null;
      statusUpdate?.call('Downloading $relative…');
      if (changedOnly && localStat != null && _sameFile(remote, localStat)) {
        skipped += 1;
        skippedUnchanged += 1;
        if (unchangedSamples.length < 5) {
          unchangedSamples.add(relative);
        }
        continue;
      }
      // Protect local edits. Without this, downloading before uploading
      // silently replaces notes you just wrote with an older remote copy --
      // the most likely way to lose work when two people share a folder.
      if (!overwriteNewerLocalFiles &&
          localStat != null &&
          remote.modifiedTime != null &&
          isMeaningfullyNewer(localStat.modified, remote.modifiedTime!)) {
        skipped += 1;
        skippedLocalNewer += 1;
        if (localNewerSamples.length < 5) {
          localNewerSamples.add(relative);
        }
        continue;
      }
      await destination.parent.create(recursive: true);
      // Stream to a temp file and rename into place so an interrupted download
      // never leaves a truncated file where a valid one is expected. The .tmp
      // suffix is already excluded from sync by shouldSkipSyncPath.
      final temporary = File('${destination.path}.tmp');
      try {
        final stream = await _store.openRead(remote.id);
        final sink = temporary.openWrite();
        await sink.addStream(stream);
        await sink.close();
        await temporary.rename(destination.path);
      } catch (_) {
        if (await temporary.exists()) {
          try {
            await temporary.delete();
          } on FileSystemException {
            // Best effort; the destination is untouched either way.
          }
        }
        rethrow;
      }
      if (remote.modifiedTime != null) {
        await destination.setLastModified(remote.modifiedTime!.toUtc());
      }
      copied += 1;
    }

    if (deleteMissingFiles) {
      statusUpdate?.call('Removing local files missing from Drive…');
      await for (final entity in localFolder.list(recursive: true)) {
        if (shouldCancel?.call() ?? false) {
          throw const ActivityCancelledException();
        }
        if (entity is! File) continue;
        final relative = path
            .relative(entity.path, from: localFolder.path)
            .replaceAll('\\', '/');
        if (shouldSkipSyncPath(relative)) continue;
        if (expected.contains(relative)) continue;
        await entity.delete();
        deleted += 1;
      }
    }

    debugLog?.call(
      'sync.drive.download done copied=$copied skipped=$skipped '
      'deleted=$deleted skipFiltered=$skippedFiltered '
      'skipUnchanged=$skippedUnchanged skipLocalNewer=$skippedLocalNewer '
      'expected=${expected.length}',
    );
    if (unchangedSamples.isNotEmpty) {
      debugLog?.call(
        'sync.drive.download unchanged samples: ${unchangedSamples.join(', ')}',
      );
    }
    if (localNewerSamples.isNotEmpty) {
      debugLog?.call(
        'sync.drive.download kept newer local copies: '
        '${localNewerSamples.join(', ')}',
      );
    }

    return GoogleDriveSyncResult(
      copiedFiles: copied,
      skippedItems: skipped,
      deletedFiles: deleted,
      skippedLocalNewer: skippedLocalNewer,
    );
  }

  Future<List<RemoteFile>> listFilesRecursive(String folderId,
      {String prefix = ''}) async {
    final entries = <RemoteFile>[];
    final children = await _store.listChildren(folderId);
    for (final child in children) {
      if (child.isFolder) {
        final nextPrefix =
            prefix.isEmpty ? child.name : '$prefix/${child.name}';
        entries.addAll(await listFilesRecursive(child.id, prefix: nextPrefix));
        continue;
      }
      final relative = prefix.isEmpty ? child.name : '$prefix/${child.name}';
      entries.add(RemoteFile(
        id: child.id,
        relativePath: relative,
        sizeBytes: child.sizeBytes,
        modifiedTime: child.modifiedTime,
      ));
    }
    return entries;
  }

  Future<String> _ensureDriveFolderPath(
    String folderRelative,
    String rootFolderId,
    Map<String, String> cache,
  ) async {
    if (folderRelative == '.' || folderRelative.isEmpty) {
      return rootFolderId;
    }
    final normalized = folderRelative.replaceAll('\\', '/');
    if (cache.containsKey(normalized)) return cache[normalized]!;

    final segments = normalized.split('/').where((item) => item.isNotEmpty);
    var currentId = rootFolderId;
    var currentPath = '';
    for (final segment in segments) {
      currentPath = currentPath.isEmpty ? segment : '$currentPath/$segment';
      final existing = cache[currentPath];
      if (existing != null) {
        currentId = existing;
        continue;
      }
      final folderId =
          await _ensureChildFolder(parentId: currentId, folderName: segment);
      cache[currentPath] = folderId;
      currentId = folderId;
    }
    return currentId;
  }

  Future<String> _ensureChildFolder({
    required String parentId,
    required String folderName,
  }) async {
    final existingId =
        await _store.findFolder(parentId: parentId, name: folderName);
    if (existingId != null) return existingId;
    return _store.createFolder(parentId: parentId, name: folderName);
  }

  bool _sameFile(RemoteFile remote, FileStat local) {
    if (remote.sizeBytes != null && local.size != remote.sizeBytes) {
      return false;
    }
    if (remote.modifiedTime == null) return false;
    return syncTimestampsMatch(local.modified, remote.modifiedTime!);
  }
}

/// Paths excluded from every sync direction.
///
/// `.riffnotes-cache` is regenerable, `.backup`/`cache` are scratch, `*.tmp` is
/// an in-flight atomic write, and `mixed_Down` holds multitrack sources already
/// represented by the mixdown in the practice root — uploading them would push
/// gigabytes of redundant audio.
bool shouldSkipSyncPath(String relativePath) {
  final parts = path.split(relativePath).map((item) => item.toLowerCase());
  return parts.any((part) =>
      part == '.riffnotes-cache' ||
      part == '.backup' ||
      part == 'cache' ||
      part == 'mixed_down' ||
      part.endsWith('.tmp'));
}
