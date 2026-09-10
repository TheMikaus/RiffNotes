import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riffnotes/domain.dart';
import 'package:riffnotes/user_catalogue.dart';
import 'package:riffnotes/user_names.dart';

/// Titles and Best Take flags live in per-user fragments so two machines can
/// edit the same practice folder and sync through Drive without one copy of a
/// shared file clobbering the other.
void main() {
  late Directory folder;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('riffnotes-usercat-');
  });

  tearDown(() async {
    if (await folder.exists()) await folder.delete(recursive: true);
  });

  File at(String name) => File('${folder.path}${Platform.pathSeparator}$name');

  Future<void> writeTake([String name = 'take.wav']) =>
      at(name).writeAsBytes([1, 2, 3]);

  final t1 = DateTime.utc(2026, 1, 1, 10);
  final t2 = DateTime.utc(2026, 1, 1, 11);

  UserCatalogue fragment(String user, Map<String, UserCatalogueEntry> entries) =>
      UserCatalogue(user: user, entries: entries);

  group('safeUserName', () {
    test('keeps safe characters and replaces the rest', () {
      expect(safeUserName('Mike Whiteley'), 'Mike_Whiteley');
      expect(safeUserName('rob-b_2'), 'rob-b_2');
      expect(safeUserName('  ok  '), 'ok');
    });

    test('never produces an empty name', () {
      // An empty name would write .riffnotes..catalogue.json, which the
      // discovery pattern cannot read back.
      expect(safeUserName(''), 'user');
      expect(safeUserName('   '), 'user');
      expect(safeUserName('***'), '___');
    });
  });

  group('mergeRecordingMetadata', () {
    test('the most recently stamped title wins across users', () {
      final merged = mergeRecordingMetadata([
        fragment('Mike', {
          'id-1': UserCatalogueEntry(title: 'Old', titleUpdatedAt: t1),
        }),
        fragment('Rob', {
          'id-1': UserCatalogueEntry(title: 'New', titleUpdatedAt: t2),
        }),
      ], 'id-1');

      expect(merged.title, 'New');
    });

    test('ties on timestamp break on user name so both machines agree', () {
      final merged = mergeRecordingMetadata([
        fragment('Rob', {
          'id-1': UserCatalogueEntry(title: 'From Rob', titleUpdatedAt: t1),
        }),
        fragment('Mike', {
          'id-1': UserCatalogueEntry(title: 'From Mike', titleUpdatedAt: t1),
        }),
      ], 'id-1');

      expect(merged.title, 'From Mike');
    });

    test('legacy title is used only while no fragment claims the title', () {
      expect(
        mergeRecordingMetadata(const [], 'id-1', legacyTitle: 'Legacy').title,
        'Legacy',
      );
      // A fragment that only stars the take does not claim the title.
      expect(
        mergeRecordingMetadata([
          fragment('Mike', {
            'id-1':
                UserCatalogueEntry(isBestTake: true, bestTakeUpdatedAt: t1),
          }),
        ], 'id-1', legacyTitle: 'Legacy')
            .title,
        'Legacy',
      );
      // A deliberate clear (null title with a stamp) outranks legacy.
      expect(
        mergeRecordingMetadata([
          fragment('Mike', {
            'id-1': UserCatalogueEntry(title: null, titleUpdatedAt: t1),
          }),
        ], 'id-1', legacyTitle: 'Legacy')
            .title,
        isNull,
      );
    });

    test('Best Take is the union of every user who starred it', () {
      final merged = mergeRecordingMetadata([
        fragment('Mike', {
          'id-1': UserCatalogueEntry(isBestTake: true, bestTakeUpdatedAt: t1),
        }),
        fragment('Rob', {
          'id-1': UserCatalogueEntry(isBestTake: false, bestTakeUpdatedAt: t2),
        }),
        fragment('Sam', {
          'id-1': UserCatalogueEntry(isBestTake: true, bestTakeUpdatedAt: t1),
        }),
      ], 'id-1');

      expect(merged.isBestTake, isTrue);
      expect(merged.bestTakeUsers, ['Mike', 'Sam']);
    });

    test('a legacy star stops counting once any fragment claims the field',
        () {
      expect(
        mergeRecordingMetadata(const [], 'id-1', legacyBestTake: true)
            .isBestTake,
        isTrue,
      );
      // Otherwise a legacy star could never be removed: no fragment can
      // outvote a value that is not a vote.
      expect(
        mergeRecordingMetadata([
          fragment('Mike', {
            'id-1':
                UserCatalogueEntry(isBestTake: false, bestTakeUpdatedAt: t1),
          }),
        ], 'id-1', legacyBestTake: true)
            .isBestTake,
        isFalse,
      );
    });
  });

  group('UserCatalogueRepository', () {
    final repository = UserCatalogueRepository();

    test('stamps only the fields being set', () async {
      await repository.update(folder, 'Mike', 'id-1',
          setTitle: true, title: 'Song', now: t1);
      await repository.update(folder, 'Mike', 'id-1',
          setBestTake: true, isBestTake: true, now: t2);

      final entry = (await repository.loadForUser(folder, 'Mike')).entries['id-1']!;
      expect(entry.title, 'Song');
      expect(entry.titleUpdatedAt, t1,
          reason: 'starring must not re-stamp the title');
      expect(entry.isBestTake, isTrue);
      expect(entry.bestTakeUpdatedAt, t2);
    });

    test('round-trips a cleared title as a claim, not an absence', () async {
      await repository.update(folder, 'Mike', 'id-1',
          setTitle: true, title: null, now: t1);

      final entry = (await repository.loadForUser(folder, 'Mike')).entries['id-1']!;
      expect(entry.claimsTitle, isTrue);
      expect(entry.title, isNull);
    });

    test('writes a discoverable, per-user file with no temp file left',
        () async {
      await repository.update(folder, 'Mike Whiteley', 'id-1',
          setTitle: true, title: 'Song');

      expect(await at('.riffnotes.Mike_Whiteley.catalogue.json').exists(),
          isTrue);
      expect(await at('.riffnotes.Mike_Whiteley.catalogue.json.tmp').exists(),
          isFalse);
      final all = await repository.loadAll(folder);
      expect(all.single.user, 'Mike Whiteley',
          reason: 'the stored name, not the sanitized filename, is canonical');
    });

    test('quarantines a corrupt fragment and still loads the others',
        () async {
      await at('.riffnotes.Rob.catalogue.json').writeAsString('{"entries": [');
      await repository.update(folder, 'Mike', 'id-1',
          setTitle: true, title: 'Song');

      final all = await repository.loadAll(folder);

      expect(all.map((item) => item.user), ['Mike']);
      final quarantined = folder
          .listSync()
          .whereType<File>()
          .where((file) => file.path.contains('.corrupt-'))
          .toList();
      expect(quarantined, hasLength(1));
      expect(await quarantined.single.readAsString(), '{"entries": [');
    });

    test('does not touch the shared catalogue file', () async {
      await repository.update(folder, 'Mike', 'id-1',
          setTitle: true, title: 'Song');

      expect(await at('library.riffnotes.json').exists(), isFalse);
    });
  });

  group('PracticeRepository with fragments', () {
    test('a title set through updateRecording lands in the user fragment and '
        'not in the shared catalogue', () async {
      await writeTake();
      final repository = PracticeRepository(currentUser: () => 'Mike');
      var practice = await repository.openPractice(folder);

      practice = await repository.updateRecording(
        practice,
        practice.recordings.single,
        title: 'Dead Reckoning',
        isBestTake: false,
      );

      expect(practice.recordings.single.title, 'Dead Reckoning');
      final shared = jsonDecode(await at('library.riffnotes.json').readAsString())
          as Map<String, dynamic>;
      final entry = (shared['recordings'] as Map<String, dynamic>)['take.wav']
          as Map<String, dynamic>;
      expect(entry['title'], isNull,
          reason: 'the shared file only maps filenames to ids now');
      expect(await at('.riffnotes.Mike.catalogue.json').exists(), isTrue);

      final reopened = await repository.openPractice(folder);
      expect(reopened.recordings.single.title, 'Dead Reckoning');
    });

    test('a legacy shared catalogue keeps its titles until someone edits',
        () async {
      await writeTake();
      await at('library.riffnotes.json').writeAsString(jsonEncode({
        'version': 1,
        'recordings': {
          'take.wav': {
            'id': 'legacy-id',
            'title': 'Written By v0.6.10',
            'isBestTake': true,
          },
        },
      }));
      final repository = PracticeRepository(currentUser: () => 'Mike');

      final practice = await repository.openPractice(folder);
      final take = practice.recordings.single;
      expect(take.id, 'legacy-id');
      expect(take.title, 'Written By v0.6.10');
      expect(take.isBestTake, isTrue);
      expect(take.bestTakeUsers, isEmpty, reason: 'nobody in particular');

      // The legacy values are preserved in the shared file, not stripped, so
      // an older build on the other machine still sees them.
      final shared = jsonDecode(await at('library.riffnotes.json').readAsString())
          as Map<String, dynamic>;
      final entry = (shared['recordings'] as Map<String, dynamic>)['take.wav']
          as Map<String, dynamic>;
      expect(entry['title'], 'Written By v0.6.10');
    });

    test('unstarring clears a legacy star', () async {
      await writeTake();
      await at('library.riffnotes.json').writeAsString(jsonEncode({
        'version': 1,
        'recordings': {
          'take.wav': {'id': 'legacy-id', 'isBestTake': true},
        },
      }));
      final repository = PracticeRepository(currentUser: () => 'Mike');
      var practice = await repository.openPractice(folder);
      expect(practice.recordings.single.isBestTake, isTrue);

      practice = await repository.updateRecording(
        practice,
        practice.recordings.single,
        title: null,
        isBestTake: false,
      );

      expect(practice.recordings.single.isBestTake, isFalse);
      expect((await repository.openPractice(folder)).recordings.single.isBestTake,
          isFalse);
    });

    test('two users editing the same folder both survive a merge', () async {
      await writeTake();
      final mike = PracticeRepository(currentUser: () => 'Mike');
      final rob = PracticeRepository(currentUser: () => 'Rob');

      // Mike titles it; Rob, on the "other machine", stars it. Rob's star
      // must not steal the title, and Mike's title must not erase Rob's star.
      var practice = await mike.openPractice(folder);
      practice = await mike.updateRecording(practice, practice.recordings.single,
          title: 'Dead Reckoning', isBestTake: false);
      practice = await rob.openPractice(folder);
      practice = await rob.updateRecording(practice, practice.recordings.single,
          title: practice.recordings.single.title, isBestTake: true);

      final merged = (await mike.openPractice(folder)).recordings.single;
      expect(merged.title, 'Dead Reckoning');
      expect(merged.isBestTake, isTrue);
      expect(merged.bestTakeUsers, ['Rob']);

      final robFragment =
          await UserCatalogueRepository().loadForUser(folder, 'Rob');
      expect(robFragment.entries.values.single.claimsTitle, isFalse,
          reason: 'saving an unchanged title must not claim it');
    });

    test('one user cannot remove another user\'s star', () async {
      await writeTake();
      final mike = PracticeRepository(currentUser: () => 'Mike');
      final rob = PracticeRepository(currentUser: () => 'Rob');
      var practice = await rob.openPractice(folder);
      await rob.updateRecording(practice, practice.recordings.single,
          title: null, isBestTake: true);

      practice = await mike.openPractice(folder);
      practice = await mike.updateRecording(practice, practice.recordings.single,
          title: null, isBestTake: false);

      expect(practice.recordings.single.isBestTake, isTrue);
      expect(practice.recordings.single.bestTakeUsers, ['Rob']);
    });

    test('the title survives a rename because fragments key by id', () async {
      await writeTake('rough.wav');
      final repository = PracticeRepository(currentUser: () => 'Mike');
      var practice = await repository.openPractice(folder);
      practice = await repository.updateRecording(
          practice, practice.recordings.single,
          title: 'Keeper', isBestTake: true);
      final id = practice.recordings.single.id;

      await at('rough.wav').rename(at('clean.wav').path);
      final reopened = await repository.openPractice(folder);

      expect(reopened.recordings.single.id, id);
      expect(reopened.recordings.single.title, 'Keeper');
      expect(reopened.recordings.single.isBestTake, isTrue);
    });

    test('deleting a take removes only this user\'s fragment entry', () async {
      await writeTake();
      final mike = PracticeRepository(currentUser: () => 'Mike');
      final rob = PracticeRepository(currentUser: () => 'Rob');
      var practice = await mike.openPractice(folder);
      final id = practice.recordings.single.id;
      await mike.updateRecording(practice, practice.recordings.single,
          title: 'Gone', isBestTake: false);
      practice = await rob.openPractice(folder);
      await rob.updateRecording(practice, practice.recordings.single,
          title: 'Gone', isBestTake: true);

      practice = await mike.openPractice(folder);
      await mike.deleteRecording(practice, practice.recordings.single);

      final catalogues = UserCatalogueRepository();
      expect((await catalogues.loadForUser(folder, 'Mike')).entries, isEmpty);
      expect((await catalogues.loadForUser(folder, 'Rob')).entries.keys, [id]);
    });

    test('writes require a display name', () async {
      await writeTake();
      final anonymous = PracticeRepository();
      final practice = await anonymous.openPractice(folder);

      await expectLater(
        anonymous.updateRecording(practice, practice.recordings.single,
            title: 'x', isBestTake: false),
        throwsA(isA<StateError>()),
      );
    });
  });
}
