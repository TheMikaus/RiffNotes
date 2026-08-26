import 'dart:io';

import 'package:googleapis/drive/v3.dart' as drive;

import 'drive_file_store.dart';

/// [DriveFileStore] backed by the real Google Drive API.
class DriveApiFileStore implements DriveFileStore {
  DriveApiFileStore(this._api);

  final drive.DriveApi _api;

  @override
  Future<List<DriveEntry>> listChildren(String parentId) async {
    final entries = <DriveEntry>[];
    String? pageToken;
    do {
      final response = await _api.files.list(
        q: "'${_escape(parentId)}' in parents and trashed = false",
        orderBy: 'folder,name_natural',
        pageSize: 1000,
        spaces: 'drive',
        pageToken: pageToken,
        $fields: 'nextPageToken,files(id,name,mimeType,size,modifiedTime)',
      );
      for (final file in response.files ?? const <drive.File>[]) {
        final id = file.id;
        final name = file.name;
        if (id == null || name == null) continue;
        entries.add(DriveEntry(
          id: id,
          name: name,
          isFolder: file.mimeType == _folderMimeType,
          sizeBytes: int.tryParse(file.size ?? ''),
          modifiedTime: file.modifiedTime,
        ));
      }
      pageToken = response.nextPageToken;
    } while (pageToken != null && pageToken.isNotEmpty);
    return entries;
  }

  @override
  Future<String?> findFolder({
    required String parentId,
    required String name,
  }) async {
    final response = await _api.files.list(
      q: "'${_escape(parentId)}' in parents and "
          "mimeType = '$_folderMimeType' and "
          "name = '${_escape(name)}' and trashed = false",
      pageSize: 1,
      spaces: 'drive',
      $fields: 'files(id)',
    );
    return response.files?.firstOrNull?.id;
  }

  @override
  Future<String> createFolder({
    required String parentId,
    required String name,
  }) async {
    final created = await _api.files.create(
      drive.File()
        ..name = name
        ..mimeType = _folderMimeType
        ..parents = [parentId],
      $fields: 'id',
    );
    final id = created.id;
    if (id == null || id.isEmpty) {
      throw StateError('Google Drive did not return a folder id.');
    }
    return id;
  }

  @override
  Future<void> createFile({
    required String parentId,
    required String name,
    required File local,
    required DateTime modifiedTime,
  }) async {
    await _api.files.create(
      drive.File()
        ..name = name
        ..parents = [parentId]
        ..modifiedTime = modifiedTime.toUtc(),
      uploadMedia: drive.Media(local.openRead(), await local.length()),
      $fields: 'id',
    );
  }

  @override
  Future<void> updateFile({
    required String fileId,
    required File local,
    required DateTime modifiedTime,
  }) async {
    await _api.files.update(
      drive.File()..modifiedTime = modifiedTime.toUtc(),
      fileId,
      uploadMedia: drive.Media(local.openRead(), await local.length()),
      $fields: 'id',
    );
  }

  @override
  Future<Stream<List<int>>> openRead(String fileId) async {
    final media = await _api.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;
    return media.stream;
  }

  @override
  Future<void> deleteFile(String fileId) => _api.files.delete(fileId);

  static const _folderMimeType = 'application/vnd.google-apps.folder';

  /// Drive query strings are single-quoted, so backslashes must be escaped
  /// before quotes or a name containing `\` would break the query.
  static String _escape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
}
