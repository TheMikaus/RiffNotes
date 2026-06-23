import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;

const supportedAudioExtensions = {'.wav', '.wave', '.mp3'};
const ignoredPracticeFolderNames = {
  '.backup',
  '.cache',
  '.riffnotes-cache',
  'cache',
};

bool isPracticeDirectory(Directory directory) {
  final name = path.basename(directory.path).toLowerCase();
  return !name.startsWith('.') && !ignoredPracticeFolderNames.contains(name);
}

class PracticeFolder {
  const PracticeFolder({required this.directory, required this.recordings});

  final Directory directory;
  final List<Recording> recordings;

  String get name => path.basename(directory.path);

  PracticeFolder copyWith({List<Recording>? recordings}) => PracticeFolder(
        directory: directory,
        recordings: recordings ?? this.recordings,
      );
}

class Recording {
  const Recording({
    required this.id,
    required this.file,
    required this.title,
    required this.isBestTake,
  });

  final String id;
  final File file;
  final String? title;
  final bool isBestTake;

  String get filename => path.basename(file.path);
  String get extension => path.extension(file.path).toLowerCase();

  Recording copyWith({String? title, bool? isBestTake, File? file}) => Recording(
        id: id,
        file: file ?? this.file,
        title: title ?? this.title,
        isBestTake: isBestTake ?? this.isBestTake,
      );
}

class PracticeRepository {
  static const _catalogueName = 'library.riffnotes.json';

  Future<List<PracticeFolder>> discoverBandFolder(Directory bandFolder) async {
    final practices = <PracticeFolder>[];
    await for (final entity in bandFolder.list()) {
      if (entity is Directory && isPracticeDirectory(entity)) {
        practices.add(await openPractice(entity));
      }
    }
    practices.sort((a, b) => b.name.compareTo(a.name));
    return practices;
  }

  Future<PracticeFolder> openPractice(Directory folder) async {
    final catalogue = await _loadCatalogue(folder);
    final recordings = <Recording>[];
    var catalogueChanged = false;
    await for (final entity in folder.list()) {
      if (entity is File && supportedAudioExtensions.contains(path.extension(entity.path).toLowerCase())) {
        final filename = path.basename(entity.path);
        final entry = catalogue[filename] as Map<String, dynamic>?;
        final id = entry?['id'] as String? ?? _newId();
        if (entry?['id'] == null) {
          catalogue[filename] = <String, dynamic>{
            'id': id,
            'title': entry?['title'],
            'isBestTake': entry?['isBestTake'] ?? false,
          };
          catalogueChanged = true;
        }
        recordings.add(Recording(
          id: id,
          file: entity,
          title: entry?['title'] as String?,
          isBestTake: entry?['isBestTake'] as bool? ?? false,
        ));
      }
    }
    recordings.sort((a, b) => a.filename.compareTo(b.filename));
    if (catalogueChanged) {
      await _writeCatalogue(folder, catalogue);
    }
    return PracticeFolder(directory: folder, recordings: recordings);
  }

  Future<PracticeFolder> updateRecording(
    PracticeFolder practice,
    Recording recording, {
    required String? title,
    required bool isBestTake,
  }) async {
    final catalogue = await _loadCatalogue(practice.directory);
    catalogue[recording.filename] = <String, dynamic>{
      'id': recording.id,
      'title': title,
      'isBestTake': isBestTake,
    };
    await _writeCatalogue(practice.directory, catalogue);

    final updatedRecording = Recording(
      id: recording.id,
      file: recording.file,
      title: title,
      isBestTake: isBestTake,
    );
    return practice.copyWith(
      recordings: practice.recordings
          .map((item) => item.id == recording.id ? updatedRecording : item)
          .toList(growable: false),
    );
  }

  Future<Map<String, dynamic>> _loadCatalogue(Directory folder) async {
    final file = File(path.join(folder.path, _catalogueName));
    if (!await file.exists()) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final recordings = decoded['recordings'];
      if (recordings is Map<String, dynamic>) {
        return recordings;
      }
      return decoded;
    } on FormatException {
      return <String, dynamic>{};
    }
  }

  Future<void> _writeCatalogue(Directory folder, Map<String, dynamic> recordings) async {
    final file = File(path.join(folder.path, _catalogueName));
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(
      encoder.convert(<String, dynamic>{
        'version': 1,
        'recordings': recordings,
      }),
      flush: true,
    );
  }

  String _newId() {
    final random = Random.secure();
    final parts = List<int>.generate(16, (_) => random.nextInt(256));
    return '${_hex(parts.sublist(0, 4))}-${_hex(parts.sublist(4, 6))}-${_hex(parts.sublist(6, 8))}-${_hex(parts.sublist(8, 10))}-${_hex(parts.sublist(10))}';
  }

  String _hex(List<int> bytes) => bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}
