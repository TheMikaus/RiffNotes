import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'activity.dart';
import 'annotations.dart';
import 'app_preferences.dart';
import 'audio_controller.dart';
import 'domain.dart';
import 'waveform.dart';
import 'waveform_view.dart';

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
  final _annotations = AnnotationRepository();
  final _activity = ActivityQueue();
  late final AudioController _audio;
  late final WaveformController _waveform;
  late final AppPreferences _preferences;
  List<PracticeFolder> _practices = const [];
  PracticeFolder? _selected;
  Recording? _selectedRecording;
  List<PracticeAnnotation> _notes = const [];
  String? _bandFolder;
  int? _rangeStartMs;
  String? _rangeRecordingId;

  @override
  void initState() {
    super.initState();
    _audio = AudioController();
    _waveform = WaveformController();
    _preferences = AppPreferences();
    _restorePreferences();
  }

  @override
  void dispose() {
    _audio.dispose();
    _waveform.dispose();
    super.dispose();
  }

  Future<void> _chooseBandFolder() async {
    final selection = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Choose your Band Folder');
    if (selection == null) {
      return;
    }
    await _openBandFolder(selection, remember: true);
  }

  Future<void> _restorePreferences() async {
    await _preferences.load();
    final savedFolder = _preferences.bandFolder;
    if (savedFolder != null && await Directory(savedFolder).exists()) {
      await _openBandFolder(savedFolder);
    }
  }

  Future<void> _openBandFolder(String selection, {bool remember = false}) async {
    if (remember) {
      await _preferences.setBandFolder(selection);
    }
    if (!mounted) {
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
        _selected = practices.where((item) => item.name == _preferences.lastPractice).firstOrNull ?? (practices.isEmpty ? null : practices.first);
        _selectedRecording = null;
        _rangeStartMs = null;
        _rangeRecordingId = null;
      });
      _waveform.clear();
      final selected = _selected;
      final remembered = selected?.recordings.where((item) => item.id == _preferences.lastRecording).firstOrNull;
      if (remembered != null) {
        await _selectRecording(remembered);
      } else if (_preferences.autoPlayOnPracticeSelection && selected != null && selected.recordings.isNotEmpty) {
        await _selectRecording(selected.recordings.first, autoPlay: true);
      }
    }
  }

  Future<void> _selectPractice(PracticeFolder practice) async {
    setState(() {
      _selected = practice;
      _selectedRecording = null;
      _rangeStartMs = null;
      _rangeRecordingId = null;
    });
    _waveform.clear();
    await _preferences.rememberSelection(practice.name, null);
    if (_preferences.autoPlayOnPracticeSelection && practice.recordings.isNotEmpty) {
      await _selectRecording(practice.recordings.first, autoPlay: true);
    }
  }

  Future<void> _selectRecording(Recording recording, {bool autoPlay = false}) async {
    setState(() => _selectedRecording = recording);
    final practice = _selected;
    if (practice != null) {
      unawaited(_waveform.load(practice, recording));
    }
    await _audio.load(recording, autoPlay: autoPlay);
    if (_selected != null) await _preferences.rememberSelection(_selected!.name, recording.id);
    await _refreshNotes(recording);
  }

  Future<void> _refreshNotes(Recording recording) async {
    final practice = _selected;
    if (practice == null) return;
    final notes = await _annotations.loadForUser(practice.directory.path, _preferences.displayName);
    if (mounted && _selectedRecording?.id == recording.id) {
      setState(() => _notes = notes.where((note) => note.recordingId == recording.id).toList());
    }
  }

  Future<void> _showPreferences() async {
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Preferences'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Remembered Band Folder'),
                subtitle: Text(_preferences.bandFolder ?? 'None selected'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Play when I select a take'),
                value: _preferences.autoPlayOnTakeSelection,
                onChanged: (value) async {
                  await _preferences.setAutoPlayOnTakeSelection(value);
                  setDialogState(() {});
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Play first take when I open a practice'),
                value: _preferences.autoPlayOnPracticeSelection,
                onChanged: (value) async {
                  await _preferences.setAutoPlayOnPracticeSelection(value);
                  setDialogState(() {});
                },
              ),
            ],
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
        ),
      ),
    );
  }

  Future<void> _updateRecording(
    Recording recording, {
    required String? title,
    required bool isBestTake,
  }) async {
    final practice = _selected;
    if (practice == null) {
      return;
    }
    final updatedPractice = await _activity.run('Saving take details', (update) async {
      update(null, 'Saving ${recording.filename}…');
      final result = await _repository.updateRecording(
        practice,
        recording,
        title: title,
        isBestTake: isBestTake,
      );
      update(1, 'Saved');
      return result;
    });
    if (mounted) {
      setState(() {
        _selected = updatedPractice;
        _practices = _practices
            .map((item) => item.directory.path == updatedPractice.directory.path ? updatedPractice : item)
            .toList(growable: false);
        _selectedRecording = updatedPractice.recordings.where((item) => item.id == recording.id).firstOrNull;
      });
    }
  }

  Future<void> _editTitle(Recording recording) async {
    final controller = TextEditingController(text: recording.title ?? '');
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Title this take'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Song or idea name'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (title != null) {
      final cleaned = title.trim();
      await _updateRecording(
        recording,
        title: cleaned.isEmpty ? null : cleaned,
        isBestTake: recording.isBestTake,
      );
    }
  }

  Future<void> _addAnnotation(Recording recording) async {
    final practice = _selected;
    if (practice == null) return;
    final text = TextEditingController();
    final startMs = _audio.position.inMilliseconds;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
          title: Text('Point note at ${_formatMilliseconds(startMs)}'),
          content: TextField(controller: text, autofocus: true, maxLines: 3, decoration: const InputDecoration(labelText: 'Comment')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save note')),
          ],
      ),
    );
    if (accepted == true && text.text.trim().isNotEmpty) {
      await _annotations.add(
        practiceFolder: practice.directory.path,
        user: _preferences.displayName,
        recording: recording,
        startMs: startMs,
        text: text.text.trim(),
      );
      await _refreshNotes(recording);
    }
    text.dispose();
  }

  void _startRangeNote(Recording recording) {
    if (_audio.duration == null || _audio.duration == Duration.zero) return;
    setState(() {
      _rangeStartMs = _audio.position.inMilliseconds;
      _rangeRecordingId = recording.id;
    });
  }

  Future<void> _onWaveformSeek(double progress) async {
    final duration = _audio.duration;
    final recording = _audio.recording;
    if (duration == null || duration == Duration.zero || recording == null) return;
    final clickedMs = (duration.inMilliseconds * progress).round();
    final pendingStart = _rangeRecordingId == recording.id ? _rangeStartMs : null;
    await _audio.seek(Duration(milliseconds: clickedMs));
    if (pendingStart == null) return;
    final startMs = pendingStart < clickedMs ? pendingStart : clickedMs;
    final endMs = pendingStart < clickedMs ? clickedMs : pendingStart;
    if (startMs == endMs) return;
    if (mounted) setState(() {
      _rangeStartMs = null;
      _rangeRecordingId = null;
    });
    await _addRangeAnnotation(recording, startMs, endMs);
  }

  Future<void> _addRangeAnnotation(Recording recording, int startMs, int endMs) async {
    final practice = _selected;
    if (practice == null) return;
    final text = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Range note: ${_formatMilliseconds(startMs)} – ${_formatMilliseconds(endMs)}'),
        content: TextField(controller: text, autofocus: true, maxLines: 3, decoration: const InputDecoration(labelText: 'Comment')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save range note')),
        ],
      ),
    );
    if (accepted == true && text.text.trim().isNotEmpty) {
      await _annotations.add(
        practiceFolder: practice.directory.path,
        user: _preferences.displayName,
        recording: recording,
        startMs: startMs,
        endMs: endMs,
        text: text.text.trim(),
      );
      await _refreshNotes(recording);
    }
    text.dispose();
  }

  String _formatMilliseconds(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    return '${duration.inMinutes.remainder(60).toString().padLeft(2, '0')}:${duration.inSeconds.remainder(60).toString().padLeft(2, '0')}';
  }

  Future<void> _previewAndApplyRename() async {
    final practice = _selected;
    if (practice == null) {
      return;
    }
    final proposals = _repository.planRename(practice);
    if (proposals.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Title one or more takes before batch renaming.')));
      return;
    }
    final hasIssues = proposals.any((proposal) => proposal.issue != null);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Preview batch rename'),
        content: SizedBox(
          width: 700,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(hasIssues ? 'Resolve the listed conflicts before renaming.' : 'Files keep their audio type and metadata stays linked.'),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: proposals.length,
                  itemBuilder: (context, index) {
                    final proposal = proposals[index];
                    return ListTile(
                      dense: true,
                      title: Text('${proposal.recording.filename} → ${proposal.targetFilename}'),
                      subtitle: proposal.issue == null ? null : Text(proposal.issue!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: hasIssues ? null : () => Navigator.pop(context, true),
            child: const Text('Rename files'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await _audio.stop();
      final updatedPractice = await _activity.run('Renaming takes', (update) async {
        update(null, 'Safely renaming ${proposals.where((proposal) => proposal.willRename).length} files…');
        final result = await _repository.applyRename(practice, proposals);
        update(1, 'Rename complete');
        return result;
      });
      if (mounted) {
        setState(() {
          _selected = updatedPractice;
          _selectedRecording = null;
          _practices = _practices
              .map((item) => item.directory.path == updatedPractice.directory.path ? updatedPractice : item)
              .toList(growable: false);
        });
      }
    } on StateError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Rename failed: ${error.message}')));
      }
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
              IconButton(tooltip: 'Preferences', onPressed: _showPreferences, icon: const Icon(Icons.settings_outlined)),
            ],
          ),
          body: Column(children: [
            _ActivityStrip(activities: _activity.activities),
            Expanded(child: Row(children: [
              SizedBox(width: 260, child: _PracticeList(practices: _practices, selected: _selected, onSelect: _selectPractice)),
              const VerticalDivider(width: 1),
              Expanded(
                child: _RecordingList(
                  practice: _selected,
                  bandFolder: _bandFolder,
                  selected: _selectedRecording,
                  onSelect: (recording) => _selectRecording(
                    recording,
                    autoPlay: _preferences.autoPlayOnTakeSelection,
                  ),
                  onEditTitle: _editTitle,
                  onToggleBest: (recording, isBestTake) => _updateRecording(
                    recording,
                    title: recording.title,
                    isBestTake: isBestTake,
                  ),
                  onBatchRename: _previewAndApplyRename,
                  onAddAnnotation: _addAnnotation,
                  onStartRangeNote: _startRangeNote,
                  onWaveformSeek: _onWaveformSeek,
                  rangeStartMs: _rangeRecordingId == _selectedRecording?.id ? _rangeStartMs : null,
                  notes: _notes,
                  audio: _audio,
                  waveform: _waveform,
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
    required this.onEditTitle,
    required this.onToggleBest,
    required this.onBatchRename,
    required this.onAddAnnotation,
    required this.onStartRangeNote,
    required this.onWaveformSeek,
    required this.rangeStartMs,
    required this.notes,
    required this.audio,
    required this.waveform,
  });
  final PracticeFolder? practice;
  final String? bandFolder;
  final Recording? selected;
  final ValueChanged<Recording> onSelect;
  final ValueChanged<Recording> onEditTitle;
  final Future<void> Function(Recording recording, bool isBestTake) onToggleBest;
  final Future<void> Function() onBatchRename;
  final ValueChanged<Recording> onAddAnnotation;
  final ValueChanged<Recording> onStartRangeNote;
  final ValueChanged<double> onWaveformSeek;
  final int? rangeStartMs;
  final List<PracticeAnnotation> notes;
  final AudioController audio;
  final WaveformController waveform;

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
              Row(children: [
                const Expanded(child: Text('Select a take to load it into the player.')),
                FilledButton.icon(
                  onPressed: onBatchRename,
                  icon: const Icon(Icons.drive_file_rename_outline),
                  label: const Text('Batch rename'),
                ),
              ]),
              const SizedBox(height: 18),
              for (final recording in practice!.recordings)
                Card(child: ListTile(
                  selected: selected?.id == recording.id,
                  leading: Icon(recording.isBestTake ? Icons.star : Icons.audiotrack, color: recording.isBestTake ? Colors.amber : null),
                  title: Text(recording.title ?? recording.filename),
                  subtitle: Text(
                    recording.title == null
                        ? _fileDetails(recording)
                        : '${recording.filename} • ${_fileDetails(recording)}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: recording.isBestTake ? 'Remove Best Take' : 'Mark Best Take',
                        icon: Icon(recording.isBestTake ? Icons.star : Icons.star_border),
                        color: recording.isBestTake ? Colors.amber : null,
                        onPressed: () => onToggleBest(recording, !recording.isBestTake),
                      ),
                      IconButton(
                        tooltip: 'Title this take',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => onEditTitle(recording),
                      ),
                      Text(recording.extension.replaceFirst('.', '').toUpperCase()),
                    ],
                  ),
                  onTap: () => onSelect(recording),
                )),
            ],
          ),
        ),
        _PlayerPanel(
          controller: audio,
          waveform: waveform,
          onAddAnnotation: onAddAnnotation,
          onStartRangeNote: onStartRangeNote,
          onWaveformSeek: onWaveformSeek,
          rangeStartMs: rangeStartMs,
          notes: notes,
        ),
      ],
    );
  }

  String _fileDetails(Recording recording) {
    try {
      final bytes = recording.file.lengthSync();
      if (bytes < 1024 * 1024) {
        return '${(bytes / 1024).toStringAsFixed(0)} KB';
      }
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } on FileSystemException {
      return 'File unavailable';
    }
  }
}

class _PlayerPanel extends StatelessWidget {
  const _PlayerPanel({
    required this.controller,
    required this.waveform,
    required this.onAddAnnotation,
    required this.onStartRangeNote,
    required this.onWaveformSeek,
    required this.rangeStartMs,
    required this.notes,
  });
  final AudioController controller;
  final WaveformController waveform;
  final ValueChanged<Recording> onAddAnnotation;
  final ValueChanged<Recording> onStartRangeNote;
  final ValueChanged<double> onWaveformSeek;
  final int? rangeStartMs;
  final List<PracticeAnnotation> notes;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: Listenable.merge([controller, waveform]),
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
                  if (controller.recording != null) ...[
                    const SizedBox(height: 8),
                    if (waveform.isLoading) const LinearProgressIndicator(),
                    if (waveform.isLoading)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text('Generating waveform… you can keep listening while this runs.'),
                      ),
                    if (waveform.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(waveform.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ),
                    if (waveform.data case final data?) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(children: [
                          const Icon(Icons.graphic_eq, size: 16),
                          const SizedBox(width: 6),
                          Text(data.fromCache ? 'Waveform loaded from practice cache' : 'Waveform generated and cached'),
                        ]),
                      ),
                      WaveformView(
                        peaks: data.peaks,
                        progress: duration == Duration.zero ? 0 : position.inMilliseconds / duration.inMilliseconds,
                        rangeStartProgress: rangeStartMs == null || duration == Duration.zero ? null : rangeStartMs! / duration.inMilliseconds,
                        onSeekProgress: onWaveformSeek,
                      ),
                    ],
                  ],
                  if (controller.recording != null) Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () => onAddAnnotation(controller.recording!),
                        icon: const Icon(Icons.add_comment_outlined),
                        label: const Text('Add point note'),
                      ),
                      TextButton.icon(
                        onPressed: canPlay ? () => onStartRangeNote(controller.recording!) : null,
                        icon: const Icon(Icons.select_all_outlined),
                        label: Text(rangeStartMs == null ? 'Start range note here' : 'Click waveform to end range'),
                      ),
                    ],
                  ),
                  if (controller.recording != null)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text('Notes (${notes.length})'),
                      children: notes.isEmpty
                          ? const [ListTile(dense: true, title: Text('No notes for this take yet.'))]
                          : notes.map((note) => ListTile(
                                dense: true,
                                leading: Icon(note.isRange ? Icons.compare_arrows : Icons.bookmark_outline),
                                title: Text(note.isRange ? 'Range note • ${note.text}' : 'Point note • ${note.text}'),
                                subtitle: Text(note.isRange
                                    ? '${_format(Duration(milliseconds: note.startMs))} – ${_format(Duration(milliseconds: note.endMs!))}'
                                    : _format(Duration(milliseconds: note.startMs))),
                                onTap: () => controller.playFromNote(note.startMs, endMs: note.endMs),
                              )).toList(),
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
                    const SizedBox(width: 8),
                    Text('${_format(position)} / ${_format(duration)}'),
                    const SizedBox(width: 12),
                    const Expanded(child: Text('Click the waveform to seek')),
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
