import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

const supportedAudioExtensions = {'.wav', '.wave', '.mp3'};

class PracticeFolder {
  const PracticeFolder({required this.directory, required this.recordings});

  final Directory directory;
  final List<Recording> recordings;

  String get name => path.basename(directory.path);
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
      if (entity is Directory) {
        practices.add(await openPractice(entity));
      }
    }
    practices.sort((a, b) => b.name.compareTo(a.name));
    return practices;
  }

  Future<PracticeFolder> openPractice(Directory folder) async {
    final catalogue = await _loadCatalogue(folder);
    final recordings = <Recording>[];
    await for (final entity in folder.list()) {
      if (entity is File && supportedAudioExtensions.contains(path.extension(entity.path).toLowerCase())) {
        final entry = catalogue[entity.path] as Map<String, dynamic>?;
        recordings.add(Recording(
          id: entry?['id'] as String? ?? _stableId(entity),
          file: entity,
          title: entry?['title'] as String?,
          isBestTake: entry?['isBestTake'] as bool? ?? false,
        ));
      }
    }
    recordings.sort((a, b) => a.filename.compareTo(b.filename));
    return PracticeFolder(directory: folder, recordings: recordings);
  }

  Future<Map<String, dynamic>> _loadCatalogue(Directory folder) async {
    final file = File(path.join(folder.path, _catalogueName));
    if (!await file.exists()) return <String, dynamic>{};
    try {
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return <String, dynamic>{};
    }
  }

  // A fallback identity must not contain the filename: rename operations are
  // allowed to change it without detaching portable notes. The full metadata
  // writer introduced with safe rename persists this value as a UUID.
  String _stableId(File file) => '${file.statSync().modified.millisecondsSinceEpoch}-${file.lengthSync()}';
}
