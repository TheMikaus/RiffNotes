import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'activity.dart';
import 'domain.dart';

void main() => runApp(const RiffNotesApp());

class RiffNotesApp extends StatelessWidget {
  const RiffNotesApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'RiffNotes',
        theme: ThemeData(colorSchemeSeed: Colors.deepPurple, brightness: Brightness.dark, useMaterial3: true),
        home: const LibraryScreen(),
      );
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _repository = PracticeRepository();
  final _activity = ActivityQueue();
  List<PracticeFolder> _practices = const [];
  PracticeFolder? _selected;
  String? _bandFolder;

  Future<void> _chooseBandFolder() async {
    final selection = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Choose your Band Folder');
    if (selection == null) {
      return;
    }
    setState(() => _bandFolder = selection);
    final practices = await _activity.run('Scanning practice folders', (update) async {
      update(null, 'Looking for practice folders…');
      final found = await _repository.discoverBandFolder(Directory(selection));
      update(1, '${found.length} practices ready');
      return found;
    });
    if (mounted) {
      setState(() {
        _practices = practices;
        _selected = practices.isEmpty ? null : practices.first;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _activity,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            title: const Text('RiffNotes'),
            actions: [
              TextButton.icon(onPressed: _chooseBandFolder, icon: const Icon(Icons.folder_open), label: const Text('Band Folder')),
            ],
          ),
          body: Column(children: [
            _ActivityStrip(activities: _activity.activities),
            Expanded(child: Row(children: [
              SizedBox(width: 260, child: _PracticeList(practices: _practices, selected: _selected, onSelect: (practice) => setState(() => _selected = practice))),
              const VerticalDivider(width: 1),
              Expanded(child: _RecordingList(practice: _selected, bandFolder: _bandFolder)),
            ])),
          ]),
        ),
      );
}

class _PracticeList extends StatelessWidget {
  const _PracticeList({required this.practices, required this.selected, required this.onSelect});
  final List<PracticeFolder> practices;
  final PracticeFolder? selected;
  final ValueChanged<PracticeFolder> onSelect;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text('PRACTICES', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          if (practices.isEmpty) const ListTile(title: Text('Choose a Band Folder to begin.')),
          for (final practice in practices)
            ListTile(
              selected: practice == selected,
              leading: const Icon(Icons.queue_music),
              title: Text(practice.name),
              subtitle: Text('${practice.recordings.length} takes'),
              onTap: () => onSelect(practice),
            ),
        ],
      );
}

class _RecordingList extends StatelessWidget {
  const _RecordingList({required this.practice, required this.bandFolder});
  final PracticeFolder? practice;
  final String? bandFolder;

  @override
  Widget build(BuildContext context) {
    if (practice == null) return Center(child: Text(bandFolder == null ? 'Start by choosing your Band Folder.' : 'No practice folders found.'));
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(practice!.name, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 6),
        const Text('Playback, waveform, notes, and safe renaming land in the next vertical slice.'),
        const SizedBox(height: 18),
        for (final recording in practice!.recordings)
          Card(child: ListTile(
            leading: Icon(recording.isBestTake ? Icons.star : Icons.audiotrack, color: recording.isBestTake ? Colors.amber : null),
            title: Text(recording.title ?? recording.filename),
            subtitle: Text(recording.title == null ? recording.filename : recording.filename),
            trailing: Text(recording.extension.replaceFirst('.', '').toUpperCase()),
          )),
      ],
    );
  }
}

class _ActivityStrip extends StatelessWidget {
  const _ActivityStrip({required this.activities});
  final List<Activity> activities;

  @override
  Widget build(BuildContext context) {
    final active = activities.where((item) => item.state == ActivityState.running).toList();
    if (active.isEmpty) return const SizedBox.shrink();
    final item = active.first;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ListTile(
        leading: const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
        title: Text(item.label),
        subtitle: Text(item.detail),
        trailing: SizedBox(width: 180, child: LinearProgressIndicator(value: item.progress)),
      ),
    );
  }
}
