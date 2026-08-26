import 'dart:convert';
import 'dart:io';

import 'package:riffnotes/drive_file_store.dart';

/// In-memory [DriveFileStore] for testing folder sync without a Drive account.
///
/// It deliberately models the two behaviours that broke the real
/// implementation:
///
/// * `modifiedTime` is stored exactly as supplied, so a test can detect an
///   implementation that fails to send one (the field would stay null).
/// * ids are opaque and unrelated to paths, so path handling cannot cheat.
class FakeDriveFileStore implements DriveFileStore {
  FakeDriveFileStore({this.rootId = 'root'}) {
    _nodes[rootId] = _Node(
      id: rootId,
      name: '',
      parentId: null,
      isFolder: true,
    );
  }

  final String rootId;
  final Map<String, _Node> _nodes = {};
  var _nextId = 0;

  /// Number of content writes, so tests can assert an idempotent second sync.
  var uploadCount = 0;
  var downloadCount = 0;

  String _newId() => 'id-${_nextId++}';

  Iterable<_Node> _childrenOf(String parentId) =>
      _nodes.values.where((node) => node.parentId == parentId);

  @override
  Future<List<DriveEntry>> listChildren(String parentId) async =>
      _childrenOf(parentId)
          .map((node) => DriveEntry(
                id: node.id,
                name: node.name,
                isFolder: node.isFolder,
                sizeBytes: node.isFolder ? null : node.bytes!.length,
                modifiedTime: node.modifiedTime,
              ))
          .toList(growable: false);

  @override
  Future<String?> findFolder({
    required String parentId,
    required String name,
  }) async {
    for (final node in _childrenOf(parentId)) {
      if (node.isFolder && node.name == name) return node.id;
    }
    return null;
  }

  @override
  Future<String> createFolder({
    required String parentId,
    required String name,
  }) async {
    final id = _newId();
    _nodes[id] =
        _Node(id: id, name: name, parentId: parentId, isFolder: true);
    return id;
  }

  @override
  Future<void> createFile({
    required String parentId,
    required String name,
    required File local,
    required DateTime modifiedTime,
  }) async {
    final id = _newId();
    _nodes[id] = _Node(
      id: id,
      name: name,
      parentId: parentId,
      isFolder: false,
      bytes: await local.readAsBytes(),
      modifiedTime: modifiedTime.toUtc(),
    );
    uploadCount += 1;
  }

  @override
  Future<void> updateFile({
    required String fileId,
    required File local,
    required DateTime modifiedTime,
  }) async {
    final node = _nodes[fileId];
    if (node == null) throw StateError('No such file: $fileId');
    node.bytes = await local.readAsBytes();
    node.modifiedTime = modifiedTime.toUtc();
    uploadCount += 1;
  }

  @override
  Future<Stream<List<int>>> openRead(String fileId) async {
    final node = _nodes[fileId];
    if (node == null) throw StateError('No such file: $fileId');
    downloadCount += 1;
    return Stream<List<int>>.value(node.bytes!);
  }

  @override
  Future<void> deleteFile(String fileId) async {
    _nodes.remove(fileId);
  }

  // --- test helpers -------------------------------------------------------

  /// Seeds a remote file at [relativePath] beneath [parentId], creating any
  /// intermediate folders.
  Future<String> seedFile({
    required String parentId,
    required String relativePath,
    required String contents,
    required DateTime modifiedTime,
  }) async {
    final segments = relativePath.split('/');
    var currentId = parentId;
    for (final segment in segments.take(segments.length - 1)) {
      currentId = await findFolder(parentId: currentId, name: segment) ??
          await createFolder(parentId: currentId, name: segment);
    }
    final id = _newId();
    _nodes[id] = _Node(
      id: id,
      name: segments.last,
      parentId: currentId,
      isFolder: false,
      bytes: utf8.encode(contents),
      modifiedTime: modifiedTime.toUtc(),
    );
    return id;
  }

  /// All remote file paths beneath [parentId], for assertions.
  Map<String, RemoteSnapshot> snapshot(String parentId, [String prefix = '']) {
    final result = <String, RemoteSnapshot>{};
    for (final node in _childrenOf(parentId)) {
      final relative = prefix.isEmpty ? node.name : '$prefix/${node.name}';
      if (node.isFolder) {
        result.addAll(snapshot(node.id, relative));
      } else {
        result[relative] = RemoteSnapshot(
          contents: utf8.decode(node.bytes!),
          modifiedTime: node.modifiedTime,
        );
      }
    }
    return result;
  }
}

class _Node {
  _Node({
    required this.id,
    required this.name,
    required this.parentId,
    required this.isFolder,
    this.bytes,
    this.modifiedTime,
  });

  final String id;
  final String name;
  final String? parentId;
  final bool isFolder;
  List<int>? bytes;
  DateTime? modifiedTime;
}

class RemoteSnapshot {
  const RemoteSnapshot({required this.contents, required this.modifiedTime});

  final String contents;
  final DateTime? modifiedTime;
}
