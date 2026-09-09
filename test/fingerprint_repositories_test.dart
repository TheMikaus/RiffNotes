import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riffnotes/atomic_file.dart';
import 'package:riffnotes/fingerprints.dart';

/// The four fingerprint repositories hold user judgements that cannot be
/// recomputed. A file that fails to parse must be moved aside with its bytes
/// intact, never silently replaced.
void main() {
  late Directory folder;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('riffnotes-fp-repo-');
  });

  tearDown(() async {
    if (await folder.exists()) await folder.delete(recursive: true);
  });

  File fileNamed(String name) =>
      File('${folder.path}${Platform.pathSeparator}$name');

  Future<List<File>> quarantined(String name) async => folder
      .listSync()
      .whereType<File>()
      .where((file) =>
          file.path.contains(name) && file.path.contains('.corrupt-'))
      .toList();

  const match = FingerprintMatch(
    recordingId: 'take-1',
    recordingFilename: 'take.wav',
    masterRecordingId: 'master-1',
    masterFilename: 'song.wav',
    masterTitle: 'Song',
    sectionLabel: null,
    confidence: .9,
  );

  group('quarantineCorruptFile', () {
    test('moves the file aside and keeps its contents', () async {
      final file = fileNamed('data.json');
      await file.writeAsString('not json');

      final moved = await quarantineCorruptFile(file);

      expect(moved, isNotNull);
      expect(await file.exists(), isFalse);
      expect(await moved!.readAsString(), 'not json');
      expect(moved.path, contains('.corrupt-'));
    });

    test('returns null for a missing file', () async {
      expect(await quarantineCorruptFile(fileNamed('absent.json')), isNull);
    });
  });

  group('FingerprintDecisionRepository', () {
    const name = '.riffnotes.fingerprint-decisions.json';

    test('quarantines a corrupt decisions file instead of overwriting it',
        () async {
      await fileNamed(name).writeAsString('{"accepted": [{"broken"');
      final repository = FingerprintDecisionRepository();

      final loaded = await repository.load(folder.path);
      expect(loaded.accepted, isEmpty);

      // The regression this guards: the next accept used to write a fresh
      // file over the damaged one, erasing every prior decision for good.
      await repository.accept(folder.path, match);

      final kept = await quarantined(name);
      expect(kept, hasLength(1), reason: 'the damaged bytes must survive');
      expect(await kept.single.readAsString(), '{"accepted": [{"broken"');

      final rewritten = jsonDecode(await fileNamed(name).readAsString())
          as Map<String, dynamic>;
      expect((rewritten['accepted'] as List).length, 1);
    });

    test('quarantines a decisions file with the wrong shape', () async {
      await fileNamed(name).writeAsString('["a list, not an object"]');

      await FingerprintDecisionRepository().load(folder.path);

      expect(await quarantined(name), hasLength(1));
    });

    test('writes atomically with no temp file left behind', () async {
      await FingerprintDecisionRepository().accept(folder.path, match);

      expect(await fileNamed('$name.tmp').exists(), isFalse);
      expect(await fileNamed(name).exists(), isTrue);
    });
  });

  group('FingerprintSuggestionRepository', () {
    const name = '.riffnotes.fingerprint-suggestions.json';

    test('quarantines a corrupt suggestions file', () async {
      await fileNamed(name).writeAsString('{{');

      final loaded = await FingerprintSuggestionRepository().load(folder.path);

      expect(loaded, isEmpty);
      expect(await quarantined(name), hasLength(1));
    });

    test('save leaves no temp file', () async {
      await FingerprintSuggestionRepository().save(folder.path, [match]);

      expect(await fileNamed('$name.tmp').exists(), isFalse);
    });
  });

  group('FingerprintLearningRepository', () {
    const name = '.riffnotes.fingerprint-learning.json';

    test('quarantines a corrupt learning file before appending', () async {
      await fileNamed(name).writeAsString('garbage');
      final repository = FingerprintLearningRepository();

      await repository.recordAccepted(folder.path, match);

      final kept = await quarantined(name);
      expect(kept, hasLength(1));
      expect(await kept.single.readAsString(), 'garbage');
      final learning = await repository.load(folder.path);
      expect(learning.examples, hasLength(1));
    });
  });

  group('FingerprintCorrectionRepository', () {
    const name = '.riffnotes.fingerprint-corrections.json';

    test('quarantines a corrupt corrections file', () async {
      await fileNamed(name).writeAsString('}');

      final loaded = await FingerprintCorrectionRepository().load(folder.path);

      expect(loaded, isEmpty);
      final kept = await quarantined(name);
      expect(kept, hasLength(1));
      expect(await kept.single.readAsString(), '}');
    });
  });

  group('untouched valid files', () {
    test('a valid decisions file is not quarantined', () async {
      const name = '.riffnotes.fingerprint-decisions.json';
      final repository = FingerprintDecisionRepository();
      await repository.accept(folder.path, match);

      await repository.load(folder.path);

      expect(await quarantined(name), isEmpty);
    });
  });
}
