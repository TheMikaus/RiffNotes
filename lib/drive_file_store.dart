import 'dart:io';

/// One file or folder in the remote store.
class DriveEntry {
  const DriveEntry({
    required this.id,
    required this.name,
    required this.isFolder,
    this.sizeBytes,
    this.modifiedTime,
  });

  final String id;
  final String name;
  final bool isFolder;
  final int? sizeBytes;
  final DateTime? modifiedTime;
}

/// A file or folder resolved to its path relative to the sync root.
class RemoteFile {
  const RemoteFile({
    required this.id,
    required this.relativePath,
    required this.sizeBytes,
    required this.modifiedTime,
  });

  final String id;
  final String relativePath;
  final int? sizeBytes;
  final DateTime? modifiedTime;
}

/// The remote operations folder sync actually needs.
///
/// This interface exists so the sync algorithms can be tested. Previously they
/// called `drive.DriveApi` directly from inside the same methods that held the
/// change-detection logic, which meant neither upload nor download could be
/// exercised without a live Google account — and both shipped with defects that
/// a single unit test would have caught.
///
/// Implementations must preserve [modifiedTime] exactly as supplied on write
/// and report it faithfully on read. Change detection depends on it: if the
/// store stamps its own time instead, every file re-uploads on every sync.
abstract class DriveFileStore {
  Future<List<DriveEntry>> listChildren(String parentId);

  Future<String?> findFolder({required String parentId, required String name});

  Future<String> createFolder({
    required String parentId,
    required String name,
  });

  Future<void> createFile({
    required String parentId,
    required String name,
    required File local,
    required DateTime modifiedTime,
  });

  Future<void> updateFile({
    required String fileId,
    required File local,
    required DateTime modifiedTime,
  });

  Future<Stream<List<int>>> openRead(String fileId);

  Future<void> deleteFile(String fileId);
}
