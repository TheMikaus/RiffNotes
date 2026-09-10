import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riffnotes/sections.dart';

/// Sections are stored as one complete layout per user; readers show the most
/// recently saved layout and every edit starts from it.
void main() {
  late Directory folder;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('riffnotes-sections-');
  });

  tearDown(() async {
    if (await folder.exists()) await folder.delete(recursive: true);
  });

  File at(String name) => File('${folder.path}${Platform.pathSeparator}$name');

  const id = 'take-1';
  SongSection section(String label, int start, int end) => SongSection(
      recordingId: id, startMs: start, endMs: end, label: label);

  SongSectionRepository repo(String user, DateTime now) =>
      SongSectionRepository(currentUser: () => user, clock: () => now);

  final t1 = DateTime.utc(2026, 1, 1, 10);
  final t2 = DateTime.utc(2026, 1, 1, 11);

  Future<void> writeLegacy(List<SongSection> sections) =>
      at('.riffnotes.$id.sections.json').writeAsString(jsonEncode({
        'version': 1,
        'sections': sections.map((item) => item.toJson()).toList(),
      }));

  test('a legacy sections file is readable and never written to', () async {
    await writeLegacy([section('Verse', 0, 10000)]);
    final mike = repo('Mike', t1);

    expect((await mike.load(folder.path, id)).single.label, 'Verse');

    await mike.add(folder.path, section('Chorus', 10000, 20000));

    // The write went to Mike's fragment; the legacy file is byte-for-byte
    // what an older build wrote, so that build still sees its own layout.
    final legacy = jsonDecode(await at('.riffnotes.$id.sections.json')
        .readAsString()) as Map<String, dynamic>;
    expect((legacy['sections'] as List).length, 1);
    expect(await at('.riffnotes.$id.sections.Mike.json').exists(), isTrue);
    expect(
        (await mike.load(folder.path, id)).map((item) => item.label).toList(),
        ['Verse', 'Chorus']);
  });

  test('the most recently saved layout wins across users', () async {
    await repo('Mike', t1).saveAll(folder.path, id, [section('A', 0, 1000)]);
    await repo('Rob', t2).saveAll(folder.path, id, [section('B', 0, 1000)]);

    final seen = await SongSectionRepository().load(folder.path, id);

    expect(seen.single.label, 'B');
  });

  test('an edit starts from the winning layout, carrying it forward',
      () async {
    await repo('Rob', t1)
        .saveAll(folder.path, id, [section('A', 0, 1000), section('B', 1000, 2000)]);

    // Mike edits later: his fragment must contain Rob's sections plus his own,
    // not just his own.
    await repo('Mike', t2).add(folder.path, section('C', 2000, 3000));

    final seen = await SongSectionRepository().load(folder.path, id);
    expect(seen.map((item) => item.label).toList(), ['A', 'B', 'C']);
    final mikeFile = jsonDecode(
        await at('.riffnotes.$id.sections.Mike.json').readAsString())
        as Map<String, dynamic>;
    expect((mikeFile['sections'] as List).length, 3);
  });

  test('ties on timestamp prefer a fragment over legacy, then user order',
      () async {
    await writeLegacy([section('Legacy', 0, 1000)]);
    await repo('Rob', t1).saveAll(folder.path, id, [section('Rob', 0, 1000)]);
    await repo('Mike', t1)
        .saveAll(folder.path, id, [section('Mike', 0, 1000)]);

    final seen = await SongSectionRepository().load(folder.path, id);

    expect(seen.single.label, 'Mike');
  });

  test('a corrupt fragment is quarantined and the other layout still loads',
      () async {
    await repo('Rob', t1).saveAll(folder.path, id, [section('Rob', 0, 1000)]);
    await at('.riffnotes.$id.sections.Mike.json').writeAsString('{"sections":');

    final seen = await SongSectionRepository().load(folder.path, id);

    expect(seen.single.label, 'Rob');
    final quarantined = folder
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('.corrupt-'))
        .toList();
    expect(quarantined, hasLength(1));
    expect(await quarantined.single.readAsString(), '{"sections":');
  });

  test('fragments for one recording never leak into another', () async {
    await repo('Mike', t1).saveAll(folder.path, id, [section('Mine', 0, 1000)]);
    await repo('Mike', t1).saveAll(folder.path, 'take-10', [
      const SongSection(
          recordingId: 'take-10', startMs: 0, endMs: 1000, label: 'Other'),
    ]);

    expect((await SongSectionRepository().load(folder.path, id)).single.label,
        'Mine');
    expect(
        (await SongSectionRepository().load(folder.path, 'take-10'))
            .single
            .label,
        'Other');
  });

  test('writes leave no temp file and require a display name', () async {
    await repo('Mike Whiteley', t1)
        .saveAll(folder.path, id, [section('A', 0, 1000)]);

    expect(await at('.riffnotes.$id.sections.Mike_Whiteley.json').exists(),
        isTrue);
    expect(await at('.riffnotes.$id.sections.Mike_Whiteley.json.tmp').exists(),
        isFalse);
    await expectLater(
      SongSectionRepository().add(folder.path, section('B', 0, 1000)),
      throwsA(isA<StateError>()),
    );
  });
}
