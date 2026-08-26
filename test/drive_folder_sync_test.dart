import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riffnotes/drive_folder_sync.dart';

import 'fake_drive_file_store.dart';

void main() {
  late Directory practice;
  late FakeDriveFileStore store;
  late DriveFolderSync sync;

  setUp(() async {
    practice = await Directory.systemTemp.createTemp('riffnotes-drive-');
    store = FakeDriveFileStore();
    sync = DriveFolderSync(store);
  });

  tearDown(() async {
    if (await practice.exists()) await practice.delete(recursive: true);
  });

  String at(String relative) =>
      '${practice.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

  Future<File> writeLocal(String relative, String contents,
      {DateTime? modified}) async {
    final file = File(at(relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
    if (modified != null) await file.setLastModified(modified);
    return file;
  }

  Future<GoogleDriveSyncResult> upload({bool changedOnly = true}) =>
      sync.uploadLocalFolder(
        localFolder: practice,
        driveRootFolderId: store.rootId,
        changedOnly: changedOnly,
      );

  Future<GoogleDriveSyncResult> download({
    bool changedOnly = true,
    bool overwriteNewerLocalFiles = false,
  }) =>
      sync.downloadFolderToLocal(
        localFolder: practice,
        driveRootFolderId: store.rootId,
        changedOnly: changedOnly,
        overwriteNewerLocalFiles: overwriteNewerLocalFiles,
      );

  group('upload change detection', () {
    test('uploads once and then recognises the files as unchanged', () async {
      // Backdated deliberately. Real recordings are hours or days old, and a
      // file written moments ago would sit inside syncTimestampTolerance --
      // which would let an implementation that stamps its own upload time pass
      // this test while still re-uploading every file in production.
      final recorded = DateTime.utc(2026, 2, 1, 20, 30);
      await writeLocal('take.wav', 'audio', modified: recorded);
      await writeLocal('library.riffnotes.json', '{}', modified: recorded);

      final first = await upload();
      expect(first.copiedFiles, 2);
      expect(store.uploadCount, 2);

      // The regression this guards: the previous implementation never sent a
      // modification time, so the remote stamp never matched the local one and
      // every file re-uploaded on every sync, forever.
      final second = await upload();
      expect(second.copiedFiles, 0,
          reason: 'a second sync with no local changes must copy nothing');
      expect(second.skippedItems, 2);
      expect(store.uploadCount, 2, reason: 'no further writes should occur');
    });

    test('preserves the local modification time on the remote copy', () async {
      final when = DateTime.utc(2026, 3, 4, 5, 6, 7);
      await writeLocal('take.wav', 'audio', modified: when);

      await upload();

      final remote = store.snapshot(
          (await store.findFolder(
              parentId: store.rootId, name: practice.path.split(RegExp(r'[\\/]')).last))!);
      expect(remote['take.wav']!.modifiedTime, isNotNull);
      expect(remote['take.wav']!.modifiedTime, when);
    });

    test('re-uploads a file after it changes locally', () async {
      await writeLocal('notes.bandnotes', 'v1');
      await upload();

      await writeLocal('notes.bandnotes', 'v2',
          modified: DateTime.now().add(const Duration(minutes: 5)));
      final result = await upload();

      expect(result.copiedFiles, 1);
    });

    test('excludes cache, temp, and mixed_Down paths', () async {
      await writeLocal('take.wav', 'audio');
      await writeLocal('.riffnotes-cache/take.waveform.json', 'cache');
      await writeLocal('library.riffnotes.json.tmp', 'partial');
      await writeLocal('mixed_Down/12/track1.wav', 'multitrack source');

      final result = await upload();

      expect(result.copiedFiles, 1);
      expect(result.skippedItems, 3);
    });
  });

  group('download conflict handling', () {
    test('writes remote files and stamps the remote modification time',
        () async {
      final when = DateTime.utc(2026, 1, 2, 3, 4, 5);
      await store.seedFile(
        parentId: await store.createFolder(
            parentId: store.rootId,
            name: practice.path.split(RegExp(r'[\\/]')).last),
        relativePath: 'take.wav',
        contents: 'remote audio',
        modifiedTime: when,
      );

      final result = await download();

      expect(result.copiedFiles, 1);
      expect(await File(at('take.wav')).readAsString(), 'remote audio');
      expect((await File(at('take.wav')).stat()).modified.toUtc(), when);
    });

    test('does not overwrite a local file that is newer than the remote copy',
        () async {
      final folderId = await store.createFolder(
          parentId: store.rootId,
          name: practice.path.split(RegExp(r'[\\/]')).last);
      await store.seedFile(
        parentId: folderId,
        relativePath: 'notes.bandnotes',
        contents: 'older remote notes',
        modifiedTime: DateTime.utc(2026, 1, 1),
      );
      await writeLocal('notes.bandnotes', 'my newer notes',
          modified: DateTime.utc(2026, 6, 1));

      final result = await download();

      // The regression this guards: downloading before uploading used to
      // silently replace local edits with an older remote copy.
      expect(await File(at('notes.bandnotes')).readAsString(),
          'my newer notes');
      expect(result.copiedFiles, 0);
      expect(result.skippedLocalNewer, 1);
    });

    test('overwrites a newer local file when explicitly asked to', () async {
      final folderId = await store.createFolder(
          parentId: store.rootId,
          name: practice.path.split(RegExp(r'[\\/]')).last);
      await store.seedFile(
        parentId: folderId,
        relativePath: 'notes.bandnotes',
        contents: 'older remote notes',
        modifiedTime: DateTime.utc(2026, 1, 1),
      );
      await writeLocal('notes.bandnotes', 'my newer notes',
          modified: DateTime.utc(2026, 6, 1));

      final result = await download(overwriteNewerLocalFiles: true);

      expect(await File(at('notes.bandnotes')).readAsString(),
          'older remote notes');
      expect(result.copiedFiles, 1);
      expect(result.skippedLocalNewer, 0);
    });

    test('skips an unchanged file on a second download', () async {
      final folderId = await store.createFolder(
          parentId: store.rootId,
          name: practice.path.split(RegExp(r'[\\/]')).last);
      await store.seedFile(
        parentId: folderId,
        relativePath: 'take.wav',
        contents: 'remote audio',
        modifiedTime: DateTime.utc(2026, 1, 2),
      );

      await download();
      final second = await download();

      expect(second.copiedFiles, 0);
      expect(second.skippedItems, 1);
    });

    test('leaves no temp file behind after a download', () async {
      final folderId = await store.createFolder(
          parentId: store.rootId,
          name: practice.path.split(RegExp(r'[\\/]')).last);
      await store.seedFile(
        parentId: folderId,
        relativePath: 'take.wav',
        contents: 'remote audio',
        modifiedTime: DateTime.utc(2026, 1, 2),
      );

      await download();

      expect(await File('${at('take.wav')}.tmp').exists(), isFalse);
    });
  });

  group('round trip', () {
    test('upload then download on a second machine converges', () async {
      await writeLocal('take.wav', 'audio');
      await writeLocal('library.riffnotes.json', '{"recordings":{}}');
      await upload();

      final other = await Directory.systemTemp.createTemp('riffnotes-other-');
      addTearDown(() async {
        if (await other.exists()) await other.delete(recursive: true);
      });
      // The remote folder is named after the first machine's folder, so point
      // the second machine at that folder id directly.
      final folderId = await store.findFolder(
          parentId: store.rootId,
          name: practice.path.split(RegExp(r'[\\/]')).last);
      final otherSync = DriveFolderSync(store);

      final pulled = await otherSync.downloadFolderToLocal(
        localFolder: other,
        driveRootFolderId: folderId!,
        includeLocalRootFolder: false,
      );
      expect(pulled.copiedFiles, 2);

      // And the second machine's own upload recognises everything as unchanged.
      final pushedBack = await otherSync.uploadLocalFolder(
        localFolder: other,
        driveRootFolderId: folderId,
        includeLocalRootFolder: false,
      );
      expect(pushedBack.copiedFiles, 0,
          reason: 'a pull followed by a push must be a no-op');
    });
  });
}
