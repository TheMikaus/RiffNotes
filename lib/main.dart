import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'activity.dart';
import 'audio_controller.dart';
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
  late final AudioController _audio;
  List<PracticeFolder> _practices = const [];
  PracticeFolder? _selected;
  Recording? _selectedRecording;
  String? _bandFolder;

  @override
  void initState() {
    super.initState();
    _audio = AudioController();
  }

  @override
  void dispose() {
    _audio.dispose();
    super.dispose();
  }

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
              Expanded(
                child: _RecordingList(
                  practice: _selected,
                  bandFolder: _bandFolder,
                  selected: _selectedRecording,
                  onSelect: (recording) {
                    setState(() => _selectedRecording = recording);
                    _audio.load(recording);
                  },
                  audio: _audio,
                ),
              ),
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
  const _RecordingList({
    required this.practice,
    required this.bandFolder,
    required this.selected,
    required this.onSelect,
    required this.audio,
  });
  final PracticeFolder? practice;
  final String? bandFolder;
  final Recording? selected;
  final ValueChanged<Recording> onSelect;
  final AudioController audio;

  @override
  Widget build(BuildContext context) {
    if (practice == null) return Center(child: Text(bandFolder == null ? 'Start by choosing your Band Folder.' : 'No practice folders found.'));
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(practice!.name, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 6),
              const Text('Select a take to load it into the player.'),
              const SizedBox(height: 18),
              for (final recording in practice!.recordings)
                Card(child: ListTile(
                  selected: selected?.id == recording.id,
                  leading: Icon(recording.isBestTake ? Icons.star : Icons.audiotrack, color: recording.isBestTake ? Colors.amber : null),
                  title: Text(recording.title ?? recording.filename),
                  subtitle: Text(recording.title == null ? recording.filename : recording.filename),
                  trailing: Text(recording.extension.replaceFirst('.', '').toUpperCase()),
                  onTap: () => onSelect(recording),
                )),
            ],
          ),
        ),
        _PlayerPanel(controller: audio),
      ],
    );
  }
}

class _PlayerPanel extends StatelessWidget {
  const _PlayerPanel({required this.controller});
  final AudioController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final duration = controller.duration ?? Duration.zero;
          final position = controller.position > duration ? duration : controller.position;
          final canPlay = controller.recording != null && !controller.isLoading && controller.error == null;
          return Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(controller.recording?.filename ?? 'No take selected', style: Theme.of(context).textTheme.titleMedium),
                  if (controller.isLoading) const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(),
                  ),
                  if (controller.error != null) Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(controller.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                  Row(children: [
                    IconButton(
                      tooltip: controller.isPlaying ? 'Pause' : 'Play',
                      iconSize: 32,
                      onPressed: canPlay ? controller.togglePlayback : null,
                      icon: Icon(controller.isPlaying ? Icons.pause_circle : Icons.play_circle),
                    ),
                    IconButton(
                      tooltip: 'Stop',
                      onPressed: canPlay ? controller.stop : null,
                      icon: const Icon(Icons.stop_circle_outlined),
                    ),
                    Text(_format(position)),
                    Expanded(
                      child: Slider(
                        value: duration == Duration.zero ? 0 : position.inMilliseconds / duration.inMilliseconds,
                        onChanged: canPlay && duration > Duration.zero
                            ? (value) => controller.seek(Duration(milliseconds: (value * duration.inMilliseconds).round()))
                            : null,
                      ),
                    ),
                    Text(_format(duration)),
                  ]),
                ],
              ),
            ),
          );
        },
      );

  String _format(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
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
