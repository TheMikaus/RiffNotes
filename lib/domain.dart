import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;

import 'atomic_file.dart';

/// Thrown when a practice folder's catalogue exists but cannot be parsed.
///
/// This is deliberately fatal for the affected practice folder. The previous
/// behaviour -- treating a damaged catalogue as an empty one -- silently minted
/// a fresh UUID for every recording and then overwrote the damaged file,
/// orphaning every note and section beyond recovery. Refusing to open the
/// folder keeps the bytes on disk so the user (or a restored Drive copy) can
/// still recover them.
class CatalogueUnreadableException implements Exception {
  const CatalogueUnreadableException({
    required this.catalogueFile,
    required this.reason,
  });

  final File catalogueFile;
  final String reason;

  @override
  String toString() =>
      'Could not read ${path.basename(catalogueFile.path)}: $reason';
}

const supportedAudioExtensions = {'.wav', '.wave', '.mp3', '.flac'};
const ignoredPracticeFolderNames = {
  '.backup',
  '.cache',
  '.riffnotes-cache',
  'cache',
  'mixed_down',
  'masters',
};

bool isPracticeDirectory(Directory directory) {
  final name = path.basename(directory.path).toLowerCase();
  return !name.startsWith('.') && !ignoredPracticeFolderNames.contains(name);
}

class PracticeFolder {
  const PracticeFolder({
    required this.directory,
    required this.recordings,
    this.loadError,
  });

  final Directory directory;
  final List<Recording> recordings;

  /// Non-null when the folder could not be read safely. The folder is still
  /// listed so the problem is visible, but it holds no recordings and must not
  /// be opened, synced, or written to.
  final String? loadError;

  bool get isReadable => loadError == null;

  String get name => path.basename(directory.path);

  PracticeFolder copyWith({List<Recording>? recordings}) => PracticeFolder(
        directory: directory,
        recordings: recordings ?? this.recordings,
        loadError: loadError,
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

  Recording copyWith({String? title, bool? isBestTake, File? file}) =>
      Recording(
        id: id,
        file: file ?? this.file,
        title: title ?? this.title,
        isBestTake: isBestTake ?? this.isBestTake,
      );
}

class RenameProposal {
  const RenameProposal({
    required this.recording,
    required this.targetFilename,
    this.issue,
  });

  final Recording recording;
  final String targetFilename;
  final String? issue;

  bool get willRename => issue == null && recording.filename != targetFilename;
}

class PracticeRepository {
  static const _catalogueName = 'library.riffnotes.json';

  Future<List<PracticeFolder>> discoverBandFolder(Directory bandFolder) async {
    final practices = <PracticeFolder>[];
    await for (final entity in bandFolder.list()) {
      if (entity is Directory && isPracticeDirectory(entity)) {
        // One damaged practice folder must not take down the whole band
        // folder, so the failure is captured per practice rather than thrown.
        try {
          practices.add(await openPractice(entity));
        } on CatalogueUnreadableException catch (error) {
          practices.add(PracticeFolder(
            directory: entity,
            recordings: const [],
            loadError: error.reason,
          ));
        }
      }
    }
    practices.sort((a, b) => b.name.compareTo(a.name));
    return practices;
  }

  Future<PracticeFolder> openPractice(Directory folder) async {
    final catalogue = await _loadCatalogue(folder);
    final seenFilenames = <String>{};
    final recordings = <Recording>[];
    var catalogueChanged = false;
    await for (final entity in folder.list()) {
      if (entity is File &&
          supportedAudioExtensions
              .contains(path.extension(entity.path).toLowerCase())) {
        final filename = path.basename(entity.path);
        seenFilenames.add(filename);
        final stat = await entity.stat();
        var entry = catalogue[filename] as Map<String, dynamic>?;
        if (entry == null) {
          final renamedFrom = _findRenamedCatalogueEntry(
            catalogue,
            seenFilenames,
            stat,
          );
          if (renamedFrom != null) {
            entry = catalogue.remove(renamedFrom) as Map<String, dynamic>?;
            catalogue[filename] = entry!;
            catalogueChanged = true;
          }
        }
        final id = entry?['id'] as String? ?? _newId();
        final updatedEntry = <String, dynamic>{
          'id': id,
          'title': entry?['title'],
          'isBestTake': entry?['isBestTake'] ?? false,
          'size': stat.size,
          'modifiedMs': stat.modified.millisecondsSinceEpoch,
        };
        if (!_catalogueEntryMatches(entry, updatedEntry)) {
          catalogue[filename] = <String, dynamic>{
            ...updatedEntry,
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
    // Entries whose files are absent are deliberately retained. On a partially
    // synced machine the audio for a take may simply not be here yet, and
    // pruning would push a catalogue with missing titles and Best Take flags
    // over the complete copy on the next upload. Deliberate removal happens
    // only through deleteRecording, where the user has confirmed it.
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
      ...await _fileMetadata(recording.file),
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

  Future<PracticeFolder> deleteRecording(
      PracticeFolder practice, Recording recording) async {
    if (await recording.file.exists()) {
      await recording.file.delete();
    }
    final catalogue = await _loadCatalogue(practice.directory);
    catalogue.remove(recording.filename);
    await _writeCatalogue(practice.directory, catalogue);
    return openPractice(practice.directory);
  }

  Future<PracticeFolder> replaceRecordingFile(
    PracticeFolder practice,
    Recording recording,
    File replacement,
  ) async {
    final catalogue = await _loadCatalogue(practice.directory);
    final existing =
        catalogue.remove(recording.filename) as Map<String, dynamic>?;
    catalogue[path.basename(replacement.path)] = existing ??
        <String, dynamic>{
          'id': recording.id,
          'title': recording.title,
          'isBestTake': recording.isBestTake,
          ...await _fileMetadata(replacement),
        };
    await _writeCatalogue(practice.directory, catalogue);
    return openPractice(practice.directory);
  }

  List<RenameProposal> planRename(PracticeFolder practice) {
    final proposals = <RenameProposal>[];
    final takesPerTitle = <String, int>{};
    var sequence = 0;

    for (final recording in practice.recordings) {
      final title = recording.title?.trim();
      if (title == null || title.isEmpty) {
        continue;
      }
      sequence += 1;
      final normalizedTitle = _filenameSafeTitle(title);
      final take = (takesPerTitle[normalizedTitle] ?? 0) + 1;
      takesPerTitle[normalizedTitle] = take;
      proposals.add(RenameProposal(
        recording: recording,
        targetFilename:
            '${sequence.toString().padLeft(2, '0')}_${normalizedTitle}_Take$take${recording.extension}',
      ));
    }

    final sources =
        proposals.map((item) => item.recording.filename.toLowerCase()).toSet();
    final targets = <String, int>{};
    for (var index = 0; index < proposals.length; index += 1) {
      final target = proposals[index].targetFilename.toLowerCase();
      targets[target] = (targets[target] ?? 0) + 1;
    }

    return proposals.map((proposal) {
      final target = proposal.targetFilename.toLowerCase();
      final targetFile =
          File(path.join(practice.directory.path, proposal.targetFilename));
      if ((targets[target] ?? 0) > 1) {
        return RenameProposal(
            recording: proposal.recording,
            targetFilename: proposal.targetFilename,
            issue: 'Duplicate target name');
      }
      if (targetFile.existsSync() && !sources.contains(target)) {
        return RenameProposal(
            recording: proposal.recording,
            targetFilename: proposal.targetFilename,
            issue: 'A different file already uses this name');
      }
      return proposal;
    }).toList(growable: false);
  }

  Future<PracticeFolder> applyRename(
      PracticeFolder practice, List<RenameProposal> proposals) async {
    final active = proposals
        .where((proposal) => proposal.willRename)
        .toList(growable: false);
    if (active.isEmpty) {
      return practice;
    }
    final blocked = proposals
        .where((proposal) => proposal.issue != null)
        .toList(growable: false);
    if (blocked.isNotEmpty) {
      throw StateError('Resolve rename conflicts before applying the rename.');
    }

    final catalogueFile =
        File(path.join(practice.directory.path, _catalogueName));
    final originalCatalogue = await catalogueFile.exists()
        ? await catalogueFile.readAsString()
        : null;
    final catalogue = await _loadCatalogue(practice.directory);
    final temporaryFiles = <RenameProposal, File>{};
    final completed = <RenameProposal>[];

    try {
      for (final proposal in active) {
        final temporary = File(path.join(
          practice.directory.path,
          '.riffnotes-rename-${proposal.recording.id}-${DateTime.now().microsecondsSinceEpoch}${proposal.recording.extension}',
        ));
        temporaryFiles[proposal] = temporary;
        await proposal.recording.file.rename(temporary.path);
      }
      for (final proposal in active) {
        final target =
            File(path.join(practice.directory.path, proposal.targetFilename));
        await temporaryFiles[proposal]!.rename(target.path);
        completed.add(proposal);
        final existing = catalogue.remove(proposal.recording.filename)
            as Map<String, dynamic>?;
        catalogue[proposal.targetFilename] = existing ??
            <String, dynamic>{
              'id': proposal.recording.id,
              'title': proposal.recording.title,
              'isBestTake': proposal.recording.isBestTake,
            };
        catalogue[proposal.targetFilename] = <String, dynamic>{
          ...(catalogue[proposal.targetFilename] as Map<String, dynamic>),
          ...await _fileMetadata(target),
        };
      }
      await _writeCatalogue(practice.directory, catalogue);
    } catch (_) {
      for (final proposal in completed.reversed) {
        final target =
            File(path.join(practice.directory.path, proposal.targetFilename));
        if (await target.exists()) {
          await target.rename(temporaryFiles[proposal]!.path);
        }
      }
      for (final proposal in active.reversed) {
        final temporary = temporaryFiles[proposal]!;
        if (await temporary.exists()) {
          await temporary.rename(proposal.recording.file.path);
        }
      }
      if (originalCatalogue == null) {
        if (await catalogueFile.exists()) {
          await catalogueFile.delete();
        }
      } else {
        await catalogueFile.writeAsString(originalCatalogue, flush: true);
      }
      rethrow;
    }
    return openPractice(practice.directory);
  }

  Future<Map<String, dynamic>> _loadCatalogue(Directory folder) async {
    final file = File(path.join(folder.path, _catalogueName));
    if (!await file.exists()) return <String, dynamic>{};
    // A catalogue that exists but will not parse is a hard error. Falling back
    // to an empty catalogue here would re-key every recording and orphan every
    // note and section in this folder -- see CatalogueUnreadableException.
    final String raw;
    try {
      raw = await file.readAsString();
    } on FileSystemException catch (error) {
      throw CatalogueUnreadableException(
        catalogueFile: file,
        reason: error.message,
      );
    }
    if (raw.trim().isEmpty) {
      throw CatalogueUnreadableException(
        catalogueFile: file,
        reason: 'the file is empty, which usually means a write was '
            'interrupted',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (error) {
      throw CatalogueUnreadableException(
        catalogueFile: file,
        reason: 'the file is not valid JSON (${error.message})',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw CatalogueUnreadableException(
        catalogueFile: file,
        reason: 'expected a JSON object at the top level',
      );
    }
    final recordings = decoded['recordings'];
    if (recordings is Map<String, dynamic>) {
      return recordings;
    }
    if (decoded.containsKey('recordings')) {
      throw CatalogueUnreadableException(
        catalogueFile: file,
        reason: 'the "recordings" entry is not a JSON object',
      );
    }
    return decoded;
  }

  Future<void> _writeCatalogue(
      Directory folder, Map<String, dynamic> recordings) async {
    final file = File(path.join(folder.path, _catalogueName));
    const encoder = JsonEncoder.withIndent('  ');
    await writeFileAtomic(
      file,
      encoder.convert(<String, dynamic>{
        'version': 1,
        'recordings': recordings,
      }),
    );
  }

  String _newId() {
    final random = Random.secure();
    final parts = List<int>.generate(16, (_) => random.nextInt(256));
    return '${_hex(parts.sublist(0, 4))}-${_hex(parts.sublist(4, 6))}-${_hex(parts.sublist(6, 8))}-${_hex(parts.sublist(8, 10))}-${_hex(parts.sublist(10))}';
  }

  String _hex(List<int> bytes) =>
      bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

  String _filenameSafeTitle(String title) {
    final sanitized = title
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    return sanitized.isEmpty ? 'Untitled' : sanitized;
  }

  String? _findRenamedCatalogueEntry(
    Map<String, dynamic> catalogue,
    Set<String> seenFilenames,
    FileStat stat,
  ) {
    final matches = catalogue.entries.where((entry) {
      if (seenFilenames.contains(entry.key)) return false;
      final value = entry.value;
      if (value is! Map<String, dynamic>) return false;
      return value['size'] == stat.size &&
          value['modifiedMs'] == stat.modified.millisecondsSinceEpoch;
    }).toList(growable: false);
    return matches.length == 1 ? matches.single.key : null;
  }

  bool _catalogueEntryMatches(
    Map<String, dynamic>? current,
    Map<String, dynamic> updated,
  ) {
    if (current == null) return false;
    for (final entry in updated.entries) {
      if (current[entry.key] != entry.value) return false;
    }
    return true;
  }

  Future<Map<String, dynamic>> _fileMetadata(File file) async {
    try {
      final stat = await file.stat();
      return <String, dynamic>{
        'size': stat.size,
        'modifiedMs': stat.modified.millisecondsSinceEpoch,
      };
    } on FileSystemException {
      return <String, dynamic>{};
    }
  }
}
