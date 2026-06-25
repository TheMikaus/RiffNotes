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
      if (entity is File &&
          supportedAudioExtensions
              .contains(path.extension(entity.path).toLowerCase())) {
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
    try {
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final recordings = decoded['recordings'];
      if (recordings is Map<String, dynamic>) {
        return recordings;
      }
      return decoded;
    } on FormatException {
      return <String, dynamic>{};
    }
  }

  Future<void> _writeCatalogue(
      Directory folder, Map<String, dynamic> recordings) async {
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
}
