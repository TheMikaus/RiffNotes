import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'activity.dart';
import 'annotations.dart';
import 'audio_processing.dart';
import 'app_preferences.dart';
import 'audio_controller.dart';
import 'domain.dart';
import 'fingerprints.dart';
import 'sections.dart';
import 'sync.dart';
import 'waveform.dart';
import 'waveform_view.dart';

void main() => runApp(const RiffNotesApp());

class RiffNotesApp extends StatelessWidget {
  const RiffNotesApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'RiffNotes',
        theme: ThemeData(
            colorSchemeSeed: Colors.deepPurple,
            brightness: Brightness.dark,
            useMaterial3: true),
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
  final _sectionsRepository = SongSectionRepository();
  final _syncRepository = PracticeSyncRepository();
  final _activity = ActivityQueue();
  final _audioProcessing = AudioProcessingRepository();
  final _fingerprints = FingerprintRepository();
  final _fingerprintDecisions = FingerprintDecisionRepository();
  late final AudioController _audio;
  late final WaveformController _waveform;
  late final AppPreferences _preferences;
  List<PracticeFolder> _practices = const [];
  PracticeFolder? _selected;
  Recording? _selectedRecording;
  List<PracticeAnnotation> _notes = const [];
  List<UserAnnotation> _reviewNotes = const [];
  List<SongSection> _sections = const [];
  List<FingerprintMatch> _fingerprintMatches = const [];
  FingerprintDecisions _fingerprintDecisionState = const FingerprintDecisions();
  String? _bandFolder;
  double _volumeBoostDb = 0;
  PlaybackChannelMode _channelMode = PlaybackChannelMode.stereo;
  int? _rangeStartMs;
  String? _rangeRecordingId;
  int? _sectionStartMs;
  String? _sectionRecordingId;
  bool _showPracticeReview = false;
  String? _reviewUserFilter;
  String? _reviewRecordingFilter;
  _ReviewSort _reviewSort = _ReviewSort.trackTime;

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
    final selection = await FilePicker.platform
        .getDirectoryPath(dialogTitle: 'Choose your Band Folder');
    if (selection == null) {
      return;
    }
    await _openBandFolder(selection, remember: true);
  }

  Future<void> _chooseSyncFolder() async {
    final selection = await FilePicker.platform
        .getDirectoryPath(dialogTitle: 'Choose your Google Drive sync folder');
    if (selection == null) return;
    await _preferences.setSyncFolder(selection);
  }

  Future<void> _chooseMastersFolder() async {
    final selection = await FilePicker.platform
        .getDirectoryPath(dialogTitle: 'Choose your Masters Folder');
    if (selection == null) return;
    await _preferences.setMastersFolder(selection);
  }

  Future<Directory?> _requireMastersFolder() async {
    final saved = _preferences.mastersFolder;
    if (saved != null && await Directory(saved).exists()) {
      return Directory(saved);
    }
    await _chooseMastersFolder();
    final selected = _preferences.mastersFolder;
    if (selected == null || !await Directory(selected).exists()) return null;
    return Directory(selected);
  }

  Future<Directory?> _requireSyncFolder() async {
    final saved = _preferences.syncFolder;
    if (saved != null && await Directory(saved).exists()) {
      return Directory(saved);
    }
    await _chooseSyncFolder();
    final selected = _preferences.syncFolder;
    if (selected == null || !await Directory(selected).exists()) return null;
    return Directory(selected);
  }

  Future<void> _restorePreferences() async {
    await _preferences.load();
    final savedFolder = _preferences.bandFolder;
    if (savedFolder != null && await Directory(savedFolder).exists()) {
      await _openBandFolder(savedFolder);
    }
  }

  Future<void> _openBandFolder(String selection,
      {bool remember = false}) async {
    if (remember) {
      await _preferences.setBandFolder(selection);
    }
    if (!mounted) {
      return;
    }
    setState(() => _bandFolder = selection);
    final practices =
        await _activity.run('Scanning practice folders', (update) async {
      update(null, 'Looking for practice folders…');
      final found = await _repository.discoverBandFolder(Directory(selection));
      update(1, '${found.length} practices ready');
      return found;
    });
    if (mounted) {
      setState(() {
        _practices = practices;
        _selected = practices
                .where((item) => item.name == _preferences.lastPractice)
                .firstOrNull ??
            (practices.isEmpty ? null : practices.first);
        _selectedRecording = null;
        _rangeStartMs = null;
        _rangeRecordingId = null;
      });
      _waveform.clear();
      if (_selected != null) await _refreshPracticeReview(_selected!);
      if (_selected != null) await _refreshFingerprintDecisions(_selected!);
      final selected = _selected;
      final remembered = selected?.recordings
          .where((item) =>
              item.id == _preferences.lastRecordingForPractice(selected.name))
          .firstOrNull;
      if (remembered != null) {
        await _selectRecording(remembered);
      } else if (selected != null && selected.recordings.isNotEmpty) {
        await _selectRecording(selected.recordings.first,
            autoPlay: _preferences.autoPlayOnPracticeSelection);
      }
    }
  }

  Future<void> _selectPractice(PracticeFolder practice) async {
    setState(() {
      _selected = practice;
      _selectedRecording = null;
      _rangeStartMs = null;
      _rangeRecordingId = null;
      _sectionStartMs = null;
      _sectionRecordingId = null;
      _reviewRecordingFilter = null;
    });
    _waveform.clear();
    await _refreshPracticeReview(practice);
    await _refreshFingerprintDecisions(practice);
    await _preferences.rememberPractice(practice.name);
    final remembered = practice.recordings
        .where((item) =>
            item.id == _preferences.lastRecordingForPractice(practice.name))
        .firstOrNull;
    if (remembered != null) {
      await _selectRecording(remembered);
    } else if (practice.recordings.isNotEmpty) {
      await _selectRecording(practice.recordings.first,
          autoPlay: _preferences.autoPlayOnPracticeSelection);
    }
  }

  Future<void> _selectRecording(Recording recording,
      {bool autoPlay = false}) async {
    final rememberedBoost = _preferences.boostFor(recording.id);
    final rememberedChannelMode = _preferences.channelModeFor(recording.id);
    setState(() {
      _selectedRecording = recording;
      _volumeBoostDb = rememberedBoost;
      _channelMode = rememberedChannelMode;
    });
    final practice = _selected;
    if (practice != null) {
      unawaited(_waveform.load(practice, recording));
    }
    File? playbackFile;
    if (practice != null) {
      try {
        playbackFile = await _audioProcessing.createPlaybackFile(
          practice,
          recording,
          decibels: rememberedBoost,
          channelMode: rememberedChannelMode,
        );
      } on StateError {
        if (mounted) {
          setState(() {
            _volumeBoostDb = 0;
            _channelMode = PlaybackChannelMode.stereo;
          });
        }
      }
    }
    await _audio.load(recording,
        autoPlay: autoPlay, playbackFile: playbackFile);
    if (_selected != null)
      await _preferences.rememberSelection(_selected!.name, recording.id);
    await _refreshNotes(recording);
  }

  Future<void> _setVolumeBoost(double decibels) async {
    await _setPlaybackProcessing(decibels: decibels, channelMode: _channelMode);
  }

  Future<void> _setChannelMode(PlaybackChannelMode channelMode) async {
    await _setPlaybackProcessing(
        decibels: _volumeBoostDb, channelMode: channelMode);
  }

  Future<void> _setPlaybackProcessing({
    required double decibels,
    required PlaybackChannelMode channelMode,
  }) async {
    final practice = _selected;
    final recording = _selectedRecording;
    if (practice == null || recording == null) return;
    final resumeAt = _audio.position;
    final resumePlaying = _audio.isPlaying;
    try {
      final source =
          await _activity.run('Preparing playback audio', (update) async {
        final processingLabel = _playbackProcessingLabel(decibels, channelMode);
        update(
            null,
            decibels == 0 && channelMode == PlaybackChannelMode.stereo
                ? 'Restoring original playback…'
                : 'Creating $processingLabel playback copy…');
        final result = await _audioProcessing.createPlaybackFile(
          practice,
          recording,
          decibels: decibels,
          channelMode: channelMode,
        );
        update(1, 'Playback audio ready');
        return result;
      });
      if (!mounted || _selectedRecording?.id != recording.id) return;
      setState(() {
        _volumeBoostDb = decibels;
        _channelMode = channelMode;
      });
      await _preferences.setBoost(recording.id, decibels);
      await _preferences.setChannelMode(recording.id, channelMode);
      await _audio.load(recording,
          playbackFile: source, autoPlay: resumePlaying);
      await _audio.seek(resumeAt);
    } on ProcessException {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('FFmpeg is required to change playback processing.')));
    } on StateError catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  String _playbackProcessingLabel(
      double decibels, PlaybackChannelMode channelMode) {
    final parts = <String>[
      if (channelMode != PlaybackChannelMode.stereo) channelMode.label,
      if (decibels > 0) '+${decibels.toStringAsFixed(0)} dB',
    ];
    return parts.isEmpty ? 'original' : parts.join(', ');
  }

  Future<void> _refreshNotes(Recording recording) async {
    final practice = _selected;
    if (practice == null) return;
    final notes = await _annotations.loadForUser(
        practice.directory.path, _preferences.displayName);
    if (mounted && _selectedRecording?.id == recording.id) {
      setState(() => _notes =
          notes.where((note) => note.recordingId == recording.id).toList());
    }
  }

  Future<void> _refreshPracticeReview(PracticeFolder practice) async {
    final notes = await _annotations.loadAll(practice.directory.path);
    if (mounted && _selected?.directory.path == practice.directory.path) {
      setState(() => _reviewNotes = notes);
    }
  }

  Future<void> _refreshFingerprintDecisions(PracticeFolder practice) async {
    final decisions = await _fingerprintDecisions.load(practice.directory.path);
    if (mounted && _selected?.directory.path == practice.directory.path) {
      setState(() => _fingerprintDecisionState = decisions);
    }
  }

  Future<void> _uploadSelectedPractice() async {
    final practice = _selected;
    if (practice == null) return;
    final syncFolder = await _requireSyncFolder();
    if (syncFolder == null) return;
    try {
      final result = await _activity.run('Uploading practice', (update) async {
        update(null, 'Copying ${practice.name} to sync folder…');
        final copied = await _syncRepository.uploadPractice(
            practiceFolder: practice.directory, syncRoot: syncFolder);
        update(1, 'Upload complete');
        return copied;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Uploaded ${result.copiedFiles} files for ${practice.name}.')));
      }
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Upload failed: ${error.message}')));
      }
    } on StateError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _downloadSelectedPractice() async {
    final practice = _selected;
    if (practice == null) return;
    final syncFolder = await _requireSyncFolder();
    if (syncFolder == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Download ${practice.name}?'),
        content: const Text(
            'This copies files from the sync folder into the local practice folder. Existing files with the same names may be overwritten.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Download')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final updatedPractice =
          await _activity.run('Downloading practice', (update) async {
        update(null, 'Copying ${practice.name} from sync folder…');
        final result = await _syncRepository.downloadPractice(
            localPracticeFolder: practice.directory, syncRoot: syncFolder);
        update(.85, 'Refreshing local practice…');
        final refreshed = await _repository.openPractice(practice.directory);
        update(1, 'Download complete');
        return (result, refreshed);
      });
      if (!mounted) return;
      final result = updatedPractice.$1;
      final refreshed = updatedPractice.$2;
      setState(() {
        _selected = refreshed;
        _practices = _practices
            .map((item) => item.directory.path == refreshed.directory.path
                ? refreshed
                : item)
            .toList(growable: false);
      });
      await _refreshPracticeReview(refreshed);
      final currentRecording = _selectedRecording == null
          ? null
          : refreshed.recordings
              .where((item) => item.id == _selectedRecording!.id)
              .firstOrNull;
      if (currentRecording != null) await _selectRecording(currentRecording);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Downloaded ${result.copiedFiles} files for ${practice.name}.')));
      }
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Download failed: ${error.message}')));
      }
    } on StateError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _matchSelectedPracticeFingerprints() async {
    final practice = _selected;
    if (practice == null) return;
    final mastersFolder = await _requireMastersFolder();
    if (mastersFolder == null) return;
    try {
      final matches =
          await _activity.run('Matching fingerprints', (update) async {
        update(null, 'Fingerprinting masters and ${practice.name}…');
        final result = await _fingerprints.matchPractice(
          practice: practice,
          mastersFolder: mastersFolder,
        );
        update(1, 'Fingerprint matching complete');
        return result;
      });
      if (!mounted) return;
      final decisions =
          await _fingerprintDecisions.load(practice.directory.path);
      final visibleMatches = matches
          .where((match) => !decisions.ignoredKeys.contains(match.key))
          .toList(growable: false);
      setState(() {
        _fingerprintMatches = visibleMatches;
        _fingerprintDecisionState = decisions;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(visibleMatches.isEmpty
              ? 'No confident fingerprint matches found.'
              : 'Found ${visibleMatches.length} fingerprint match suggestions.')));
    } on ProcessException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('FFmpeg is required for fingerprint matching.')));
      }
    } on StateError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _reviewFingerprintMatches() async {
    final practice = _selected;
    if (practice == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final matches = _fingerprintMatches.toList()
            ..sort((a, b) {
              final recording =
                  a.recordingFilename.compareTo(b.recordingFilename);
              if (recording != 0) return recording;
              return b.confidence.compareTo(a.confidence);
            });
          return AlertDialog(
            title: const Text('Review fingerprint matches'),
            content: SizedBox(
              width: 820,
              child: matches.isEmpty
                  ? const Text('No pending fingerprint matches to review.')
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: matches.length,
                      itemBuilder: (context, index) {
                        final match = matches[index];
                        final recording = practice.recordings
                            .where((item) => item.id == match.recordingId)
                            .firstOrNull;
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.fingerprint),
                            title: Text(
                                '${match.recordingFilename} → ${match.displayName}'),
                            subtitle: Text(
                                'Confidence ${(match.confidence * 100).round()}%${recording?.title == null ? '' : ' • current title: ${recording!.title}'}'),
                            trailing: Wrap(
                              spacing: 8,
                              children: [
                                TextButton(
                                  onPressed: () async {
                                    await _ignoreFingerprintMatch(match);
                                    setDialogState(() {});
                                  },
                                  child: const Text('Ignore'),
                                ),
                                FilledButton(
                                  onPressed: recording == null
                                      ? null
                                      : () async {
                                          await _acceptFingerprintMatch(
                                              recording, match);
                                          setDialogState(() {});
                                        },
                                  child: const Text('Accept title'),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done')),
            ],
          );
        },
      ),
    );
  }

  Future<void> _acceptFingerprintMatch(
      Recording recording, FingerprintMatch match) async {
    final practice = _selected;
    if (practice == null) return;
    final title = match.masterTitle ??
        path.basenameWithoutExtension(match.masterFilename);
    await _updateRecording(
      recording,
      title: title,
      isBestTake: recording.isBestTake,
    );
    await _fingerprintDecisions.accept(practice.directory.path, match);
    final decisions = await _fingerprintDecisions.load(practice.directory.path);
    if (mounted) {
      setState(() {
        _fingerprintDecisionState = decisions;
        _fingerprintMatches = _fingerprintMatches
            .where((item) => item.recordingId != match.recordingId)
            .toList(growable: false);
      });
    }
  }

  Future<void> _ignoreFingerprintMatch(FingerprintMatch match) async {
    final practice = _selected;
    if (practice == null) return;
    await _fingerprintDecisions.ignore(practice.directory.path, match);
    final decisions = await _fingerprintDecisions.load(practice.directory.path);
    if (mounted) {
      setState(() {
        _fingerprintDecisionState = decisions;
        _fingerprintMatches = _fingerprintMatches
            .where((item) => item.key != match.key)
            .toList(growable: false);
      });
    }
  }

  Future<void> _saveRecordingAsMaster(Recording recording) async {
    final mastersFolder = await _requireMastersFolder();
    if (mastersFolder == null) return;
    final title =
        recording.title ?? path.basenameWithoutExtension(recording.filename);
    final target = File(path.join(
        mastersFolder.path, '${_filenameSafe(title)}${recording.extension}'));
    if (await target.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${path.basename(target.path)} already exists.')));
      }
      return;
    }
    await _activity.run('Saving master', (update) async {
      update(null, 'Copying ${recording.filename} to Masters…');
      await target.parent.create(recursive: true);
      await recording.file.copy(target.path);
      update(1, 'Master saved');
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Saved ${path.basename(target.path)} to Masters.')));
    }
  }

  Future<void> _saveSectionAsMaster(
      Recording recording, SongSection section) async {
    final mastersFolder = await _requireMastersFolder();
    if (mastersFolder == null) return;
    final title =
        recording.title ?? path.basenameWithoutExtension(recording.filename);
    final target = File(path.join(mastersFolder.path,
        '${_filenameSafe('${title}_${section.label}')}.wav'));
    if (await target.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${path.basename(target.path)} already exists.')));
      }
      return;
    }
    try {
      await _activity.run('Saving section master', (update) async {
        update(null, 'Exporting ${section.label} to Masters…');
        await _audioProcessing.exportAudio(
          recording: recording,
          output: target,
          decibels: 0,
          channelMode: PlaybackChannelMode.stereo,
          startMs: section.startMs,
          endMs: section.endMs,
        );
        update(1, 'Section master saved');
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Saved ${path.basename(target.path)} to Masters.')));
      }
    } on ProcessException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('FFmpeg is required to save a section as master.')));
      }
    } on StateError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _playReviewNote(UserAnnotation item) async {
    final practice = _selected;
    if (practice == null) return;
    final recording = practice.recordings
        .where((take) => take.id == item.annotation.recordingId)
        .firstOrNull;
    if (recording == null) return;
    if (_selectedRecording?.id != recording.id)
      await _selectRecording(recording);
    await _audio.playFromNote(item.annotation.startMs,
        endMs: item.annotation.endMs);
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
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Google Drive sync folder'),
                subtitle: Text(_preferences.syncFolder ?? 'None selected'),
                trailing: TextButton(
                    onPressed: () async {
                      await _chooseSyncFolder();
                      setDialogState(() {});
                    },
                    child: const Text('Choose')),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Masters Folder'),
                subtitle: Text(_preferences.mastersFolder ?? 'None selected'),
                trailing: TextButton(
                    onPressed: () async {
                      await _chooseMastersFolder();
                      setDialogState(() {});
                    },
                    child: const Text('Choose')),
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
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.speaker_outlined),
                title: Text('Audio output device'),
                subtitle: Text(
                    'Currently uses the Windows default output. Device selection needs an audio backend upgrade.'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'))
          ],
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
    final updatedPractice =
        await _activity.run('Saving take details', (update) async {
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
            .map((item) => item.directory.path == updatedPractice.directory.path
                ? updatedPractice
                : item)
            .toList(growable: false);
        _selectedRecording = updatedPractice.recordings
            .where((item) => item.id == recording.id)
            .firstOrNull;
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
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Save')),
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
        content: TextField(
            controller: text,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Comment')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save note')),
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

  void _startSection(Recording recording) {
    if (_audio.duration == null || _audio.duration == Duration.zero) return;
    setState(() {
      _sectionStartMs = _audio.position.inMilliseconds;
      _sectionRecordingId = recording.id;
    });
  }

  Future<void> _onWaveformSeek(double progress) async {
    final duration = _audio.duration;
    final recording = _audio.recording;
    if (duration == null || duration == Duration.zero || recording == null)
      return;
    final clickedMs = (duration.inMilliseconds * progress).round();
    final sectionStart =
        _sectionRecordingId == recording.id ? _sectionStartMs : null;
    final pendingStart =
        _rangeRecordingId == recording.id ? _rangeStartMs : null;
    await _audio.seek(Duration(milliseconds: clickedMs));
    if (sectionStart != null) {
      final startMs = sectionStart < clickedMs ? sectionStart : clickedMs;
      final endMs = sectionStart < clickedMs ? clickedMs : sectionStart;
      if (startMs != endMs) {
        if (mounted) {
          setState(() {
            _sectionStartMs = null;
            _sectionRecordingId = null;
          });
        }
        await _addSection(recording, startMs, endMs);
      }
      return;
    }
    if (pendingStart == null) return;
    final startMs = pendingStart < clickedMs ? pendingStart : clickedMs;
    final endMs = pendingStart < clickedMs ? clickedMs : pendingStart;
    if (startMs == endMs) return;
    if (mounted) {
      setState(() {
        _rangeStartMs = null;
        _rangeRecordingId = null;
      });
    }
    await _addRangeAnnotation(recording, startMs, endMs);
  }

  Future<void> _addSection(Recording recording, int startMs, int endMs) async {
    final practice = _selected;
    if (practice == null) return;
    final label = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
            'Song section: ${_formatMilliseconds(startMs)} – ${_formatMilliseconds(endMs)}'),
        content: TextField(
          controller: label,
          autofocus: true,
          decoration: const InputDecoration(
              labelText: 'Section name (Verse, Chorus, Bridge…)'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save section')),
        ],
      ),
    );
    if (accepted == true && label.text.trim().isNotEmpty) {
      await _sectionsRepository.add(
        practice.directory.path,
        SongSection(
            recordingId: recording.id,
            startMs: startMs,
            endMs: endMs,
            label: label.text.trim()),
      );
      await _refreshSections(recording);
    }
    label.dispose();
  }

  Future<void> _editSection(SongSection section) async {
    final practice = _selected;
    final recording = _selectedRecording;
    if (practice == null || recording == null) return;
    final label = TextEditingController(text: section.label);
    final start =
        TextEditingController(text: _formatMilliseconds(section.startMs));
    final end = TextEditingController(text: _formatMilliseconds(section.endMs));
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit song section'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: label,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Section name'),
            ),
            TextField(
              controller: start,
              decoration: const InputDecoration(labelText: 'Start mm:ss'),
            ),
            TextField(
              controller: end,
              decoration: const InputDecoration(labelText: 'End mm:ss'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save section')),
        ],
      ),
    );
    if (accepted == true && label.text.trim().isNotEmpty) {
      final startMs = _parseTimestamp(start.text.trim()) ?? section.startMs;
      final endMs = _parseTimestamp(end.text.trim()) ?? section.endMs;
      if (endMs <= startMs) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Section end must be after the start.')));
        }
      } else {
        await _sectionsRepository.replace(
          practice.directory.path,
          section,
          SongSection(
            recordingId: section.recordingId,
            startMs: startMs,
            endMs: endMs,
            label: label.text.trim(),
          ),
        );
        await _refreshSections(recording);
      }
    }
    label.dispose();
    start.dispose();
    end.dispose();
  }

  Future<void> _deleteSection(SongSection section) async {
    final practice = _selected;
    final recording = _selectedRecording;
    if (practice == null || recording == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${section.label}?'),
        content: Text(
            '${_formatMilliseconds(section.startMs)} – ${_formatMilliseconds(section.endMs)} will be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true) {
      await _sectionsRepository.delete(practice.directory.path, section);
      await _refreshSections(recording);
    }
  }

  Future<void> _addRangeAnnotation(
      Recording recording, int startMs, int endMs) async {
    final practice = _selected;
    if (practice == null) return;
    final text = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
            'Range note: ${_formatMilliseconds(startMs)} – ${_formatMilliseconds(endMs)}'),
        content: TextField(
            controller: text,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Comment')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save range note')),
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
      await _refreshSections(recording);
    }
    text.dispose();
  }

  Future<void> _refreshSections(Recording recording) async {
    final practice = _selected;
    if (practice == null) return;
    final sections =
        await _sectionsRepository.load(practice.directory.path, recording.id);
    if (mounted && _selectedRecording?.id == recording.id) {
      setState(() => _sections = sections
          .where((section) => section.recordingId == recording.id)
          .toList());
    }
  }

  String _formatMilliseconds(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    return '${duration.inMinutes.remainder(60).toString().padLeft(2, '0')}:${duration.inSeconds.remainder(60).toString().padLeft(2, '0')}';
  }

  int? _parseTimestamp(String value) {
    final parts = value.split(':').map((item) => int.tryParse(item)).toList();
    if (parts.any((item) => item == null)) return null;
    if (parts.length == 2) {
      return (parts[0]! * 60 + parts[1]!) * 1000;
    }
    if (parts.length == 3) {
      return (parts[0]! * 3600 + parts[1]! * 60 + parts[2]!) * 1000;
    }
    return null;
  }

  Future<void> _exportAudio(
      Recording recording, SongSection? section, String extension) async {
    final baseName = _exportBaseName(recording, section);
    final selectedPath = await FilePicker.platform.saveFile(
      dialogTitle: section == null ? 'Export track' : 'Export section',
      fileName: '$baseName.$extension',
      type: FileType.custom,
      allowedExtensions: [extension],
    );
    if (selectedPath == null) return;
    final output = File(selectedPath);
    try {
      await _activity.run('Exporting audio', (update) async {
        update(null, 'Creating ${path.basename(output.path)}…');
        await _audioProcessing.exportAudio(
          recording: recording,
          output: output,
          decibels: _volumeBoostDb,
          channelMode: _channelMode,
          startMs: section?.startMs,
          endMs: section?.endMs,
        );
        update(1, 'Export complete');
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Exported ${path.basename(output.path)}')));
      }
    } on ProcessException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('FFmpeg is required to export processed audio.')));
      }
    } on StateError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _convertSelectedWavToMp3(Recording recording) async {
    final practice = _selected;
    if (practice == null || recording.extension != '.wav') return;
    final target = File(path.join(practice.directory.path,
        '${path.basenameWithoutExtension(recording.filename)}.mp3'));
    if (await target.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${path.basename(target.path)} already exists.')));
      }
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Convert WAV to MP3?'),
        content: Text(
            'This will create ${path.basename(target.path)}, verify it, then remove ${recording.filename}. Notes and sections stay linked.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Convert')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _audio.stop();
      final updatedPractice =
          await _activity.run('Converting WAV to MP3', (update) async {
        update(null, 'Creating ${path.basename(target.path)}…');
        await _audioProcessing.convertWavToMp3(recording, target);
        update(.8, 'MP3 verified; removing original WAV…');
        await recording.file.delete();
        final result =
            await _repository.replaceRecordingFile(practice, recording, target);
        update(1, 'Conversion complete');
        return result;
      });
      if (!mounted) return;
      final converted = updatedPractice.recordings
          .where((item) => item.id == recording.id)
          .firstOrNull;
      setState(() {
        _selected = updatedPractice;
        _practices = _practices
            .map((item) => item.directory.path == updatedPractice.directory.path
                ? updatedPractice
                : item)
            .toList(growable: false);
      });
      if (converted != null) {
        await _selectRecording(converted);
      }
    } on ProcessException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('FFmpeg is required to convert WAV files to MP3.')));
      }
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Conversion failed: ${error.message}')));
      }
    } on StateError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  String _exportBaseName(Recording recording, SongSection? section) {
    final raw = [
      recording.title ?? path.basenameWithoutExtension(recording.filename),
      if (section != null) section.label,
    ].join('_');
    final sanitized = raw
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    return sanitized.isEmpty ? 'RiffNotes_Export' : sanitized;
  }

  String _filenameSafe(String value) {
    final sanitized = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    return sanitized.isEmpty ? 'Untitled' : sanitized;
  }

  Future<void> _previewAndApplyRename() async {
    final practice = _selected;
    if (practice == null) {
      return;
    }
    final proposals = _repository.planRename(practice);
    if (proposals.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Title one or more takes before batch renaming.')));
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
              Text(hasIssues
                  ? 'Resolve the listed conflicts before renaming.'
                  : 'Files keep their audio type and metadata stays linked.'),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: proposals.length,
                  itemBuilder: (context, index) {
                    final proposal = proposals[index];
                    return ListTile(
                      dense: true,
                      title: Text(
                          '${proposal.recording.filename} → ${proposal.targetFilename}'),
                      subtitle: proposal.issue == null
                          ? null
                          : Text(proposal.issue!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error)),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
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
      final updatedPractice =
          await _activity.run('Renaming takes', (update) async {
        update(null,
            'Safely renaming ${proposals.where((proposal) => proposal.willRename).length} files…');
        final result = await _repository.applyRename(practice, proposals);
        update(1, 'Rename complete');
        return result;
      });
      if (mounted) {
        setState(() {
          _selected = updatedPractice;
          _selectedRecording = null;
          _practices = _practices
              .map((item) =>
                  item.directory.path == updatedPractice.directory.path
                      ? updatedPractice
                      : item)
              .toList(growable: false);
        });
      }
    } on StateError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Rename failed: ${error.message}')));
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
              TextButton.icon(
                  onPressed: _chooseBandFolder,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Band Folder')),
              IconButton(
                  tooltip: 'Upload selected practice to sync folder',
                  onPressed: _selected == null ? null : _uploadSelectedPractice,
                  icon: const Icon(Icons.cloud_upload_outlined)),
              IconButton(
                  tooltip: 'Download selected practice from sync folder',
                  onPressed:
                      _selected == null ? null : _downloadSelectedPractice,
                  icon: const Icon(Icons.cloud_download_outlined)),
              IconButton(
                  tooltip: 'Match selected practice against Masters',
                  onPressed: _selected == null
                      ? null
                      : _matchSelectedPracticeFingerprints,
                  icon: const Icon(Icons.fingerprint)),
              IconButton(
                  tooltip:
                      'Review ${_fingerprintMatches.length} fingerprint match suggestions; ${_fingerprintDecisionState.accepted.length} accepted',
                  onPressed: _selected == null || _fingerprintMatches.isEmpty
                      ? null
                      : _reviewFingerprintMatches,
                  icon: const Icon(Icons.rule_folder_outlined)),
              IconButton(
                  tooltip: 'Preferences',
                  onPressed: _showPreferences,
                  icon: const Icon(Icons.settings_outlined)),
            ],
          ),
          body: Column(children: [
            _ActivityStrip(activities: _activity.activities),
            Expanded(
                child: Row(children: [
              SizedBox(
                  width: 260,
                  child: _PracticeList(
                      practices: _practices,
                      selected: _selected,
                      onSelect: _selectPractice)),
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
                  onStartSection: _startSection,
                  onEditSection: _editSection,
                  onDeleteSection: _deleteSection,
                  onExportAudio: _exportAudio,
                  onConvertToMp3: _convertSelectedWavToMp3,
                  onSaveRecordingAsMaster: _saveRecordingAsMaster,
                  onSaveSectionAsMaster: _saveSectionAsMaster,
                  onWaveformSeek: _onWaveformSeek,
                  rangeStartMs: _rangeRecordingId == _selectedRecording?.id
                      ? _rangeStartMs
                      : null,
                  sectionStartMs: _sectionRecordingId == _selectedRecording?.id
                      ? _sectionStartMs
                      : null,
                  volumeBoostDb: _volumeBoostDb,
                  channelMode: _channelMode,
                  onSetVolumeBoost: _setVolumeBoost,
                  onSetChannelMode: _setChannelMode,
                  notes: _notes,
                  sections: _sections,
                  showPracticeReview: _showPracticeReview,
                  onTogglePracticeReview: (value) =>
                      setState(() => _showPracticeReview = value),
                  reviewUserFilter: _reviewUserFilter,
                  reviewRecordingFilter: _reviewRecordingFilter,
                  reviewSort: _reviewSort,
                  onSetReviewUserFilter: (value) =>
                      setState(() => _reviewUserFilter = value),
                  onSetReviewRecordingFilter: (value) =>
                      setState(() => _reviewRecordingFilter = value),
                  onSetReviewSort: (value) =>
                      setState(() => _reviewSort = value),
                  reviewNotes: _reviewNotes,
                  fingerprintMatches: _fingerprintMatches,
                  onPlayReviewNote: _playReviewNote,
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
  const _PracticeList(
      {required this.practices,
      required this.selected,
      required this.onSelect});
  final List<PracticeFolder> practices;
  final PracticeFolder? selected;
  final ValueChanged<PracticeFolder> onSelect;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text('PRACTICES', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          if (practices.isEmpty)
            const ListTile(title: Text('Choose a Band Folder to begin.')),
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

enum _ReviewSort {
  trackTime('Track time'),
  created('Created'),
  user('User');

  const _ReviewSort(this.label);

  final String label;
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
    required this.onStartSection,
    required this.onEditSection,
    required this.onDeleteSection,
    required this.onExportAudio,
    required this.onConvertToMp3,
    required this.onSaveRecordingAsMaster,
    required this.onSaveSectionAsMaster,
    required this.onWaveformSeek,
    required this.rangeStartMs,
    required this.sectionStartMs,
    required this.volumeBoostDb,
    required this.channelMode,
    required this.onSetVolumeBoost,
    required this.onSetChannelMode,
    required this.notes,
    required this.sections,
    required this.showPracticeReview,
    required this.onTogglePracticeReview,
    required this.reviewUserFilter,
    required this.reviewRecordingFilter,
    required this.reviewSort,
    required this.onSetReviewUserFilter,
    required this.onSetReviewRecordingFilter,
    required this.onSetReviewSort,
    required this.reviewNotes,
    required this.fingerprintMatches,
    required this.onPlayReviewNote,
    required this.audio,
    required this.waveform,
  });
  final PracticeFolder? practice;
  final String? bandFolder;
  final Recording? selected;
  final ValueChanged<Recording> onSelect;
  final ValueChanged<Recording> onEditTitle;
  final Future<void> Function(Recording recording, bool isBestTake)
      onToggleBest;
  final Future<void> Function() onBatchRename;
  final ValueChanged<Recording> onAddAnnotation;
  final ValueChanged<Recording> onStartRangeNote;
  final ValueChanged<Recording> onStartSection;
  final ValueChanged<SongSection> onEditSection;
  final ValueChanged<SongSection> onDeleteSection;
  final Future<void> Function(
          Recording recording, SongSection? section, String extension)
      onExportAudio;
  final ValueChanged<Recording> onConvertToMp3;
  final ValueChanged<Recording> onSaveRecordingAsMaster;
  final void Function(Recording recording, SongSection section)
      onSaveSectionAsMaster;
  final ValueChanged<double> onWaveformSeek;
  final int? rangeStartMs;
  final int? sectionStartMs;
  final double volumeBoostDb;
  final PlaybackChannelMode channelMode;
  final ValueChanged<double> onSetVolumeBoost;
  final ValueChanged<PlaybackChannelMode> onSetChannelMode;
  final List<PracticeAnnotation> notes;
  final List<SongSection> sections;
  final bool showPracticeReview;
  final ValueChanged<bool> onTogglePracticeReview;
  final String? reviewUserFilter;
  final String? reviewRecordingFilter;
  final _ReviewSort reviewSort;
  final ValueChanged<String?> onSetReviewUserFilter;
  final ValueChanged<String?> onSetReviewRecordingFilter;
  final ValueChanged<_ReviewSort> onSetReviewSort;
  final List<UserAnnotation> reviewNotes;
  final List<FingerprintMatch> fingerprintMatches;
  final ValueChanged<UserAnnotation> onPlayReviewNote;
  final AudioController audio;
  final WaveformController waveform;

  @override
  Widget build(BuildContext context) {
    if (practice == null)
      return Center(
          child: Text(bandFolder == null
              ? 'Start by choosing your Band Folder.'
              : 'No practice folders found.'));
    final visibleReviewNotes = _visibleReviewNotes(practice!);
    final reviewUsers = reviewNotes.map((item) => item.user).toSet().toList()
      ..sort();
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Row(children: [
                Expanded(
                    child: Text(practice!.name,
                        style: Theme.of(context).textTheme.headlineMedium)),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                        value: false,
                        label: Text('Takes'),
                        icon: Icon(Icons.queue_music)),
                    ButtonSegment(
                        value: true,
                        label: Text('Practice review'),
                        icon: Icon(Icons.rate_review_outlined)),
                  ],
                  selected: {showPracticeReview},
                  onSelectionChanged: (value) =>
                      onTogglePracticeReview(value.first),
                ),
              ]),
              if (showPracticeReview) ...[
                const SizedBox(height: 12),
                Text('All bandmate notes in this practice',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    DropdownMenu<String?>(
                      label: const Text('User'),
                      initialSelection: reviewUserFilter,
                      dropdownMenuEntries: [
                        const DropdownMenuEntry<String?>(
                            value: null, label: 'All users'),
                        for (final user in reviewUsers)
                          DropdownMenuEntry<String?>(value: user, label: user),
                      ],
                      onSelected: onSetReviewUserFilter,
                    ),
                    DropdownMenu<String?>(
                      label: const Text('Take'),
                      initialSelection: reviewRecordingFilter,
                      dropdownMenuEntries: [
                        const DropdownMenuEntry<String?>(
                            value: null, label: 'All takes'),
                        for (final recording in practice!.recordings)
                          DropdownMenuEntry<String?>(
                              value: recording.id,
                              label: recording.title ?? recording.filename),
                      ],
                      onSelected: onSetReviewRecordingFilter,
                    ),
                    DropdownMenu<_ReviewSort>(
                      label: const Text('Sort'),
                      initialSelection: reviewSort,
                      dropdownMenuEntries: [
                        for (final sort in _ReviewSort.values)
                          DropdownMenuEntry<_ReviewSort>(
                              value: sort, label: sort.label),
                      ],
                      onSelected: (value) {
                        if (value != null) onSetReviewSort(value);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (visibleReviewNotes.isEmpty)
                  const ListTile(
                      title: Text(
                          'No notes match the current practice review filters.')),
                for (final item in visibleReviewNotes)
                  Card(
                      child: ListTile(
                    leading: Icon(item.annotation.isRange
                        ? Icons.compare_arrows
                        : Icons.bookmark_outline),
                    title: Text(item.annotation.text),
                    subtitle: Text(
                        '${_recordingLabel(practice!, item.annotation.recordingId)} • ${item.user} • ${_reviewTime(item.annotation)}'),
                    trailing: const Icon(Icons.play_arrow),
                    onTap: () => onPlayReviewNote(item),
                  )),
              ] else ...[
                Row(children: [
                  const Expanded(
                      child: Text('Select a take to load it into the player.')),
                  FilledButton.icon(
                    onPressed: onBatchRename,
                    icon: const Icon(Icons.drive_file_rename_outline),
                    label: const Text('Batch rename'),
                  ),
                ]),
                const SizedBox(height: 18),
                for (final recording in practice!.recordings)
                  Card(
                      child: ListTile(
                    selected: selected?.id == recording.id,
                    leading: Icon(
                        recording.isBestTake ? Icons.star : Icons.audiotrack,
                        color: recording.isBestTake ? Colors.amber : null),
                    title: Text(recording.title ?? recording.filename),
                    subtitle: Text(
                      _recordingSubtitle(recording),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: recording.isBestTake
                              ? 'Remove Best Take'
                              : 'Mark Best Take',
                          icon: Icon(recording.isBestTake
                              ? Icons.star
                              : Icons.star_border),
                          color: recording.isBestTake ? Colors.amber : null,
                          onPressed: () =>
                              onToggleBest(recording, !recording.isBestTake),
                        ),
                        IconButton(
                          tooltip: 'Title this take',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => onEditTitle(recording),
                        ),
                        IconButton(
                          tooltip: 'Save take as new master',
                          icon: const Icon(Icons.library_music_outlined),
                          onPressed: () => onSaveRecordingAsMaster(recording),
                        ),
                        Text(recording.extension
                            .replaceFirst('.', '')
                            .toUpperCase()),
                      ],
                    ),
                    onTap: () => onSelect(recording),
                  )),
              ],
            ],
          ),
        ),
        _PlayerPanel(
          controller: audio,
          waveform: waveform,
          onAddAnnotation: onAddAnnotation,
          onStartRangeNote: onStartRangeNote,
          onStartSection: onStartSection,
          onEditSection: onEditSection,
          onDeleteSection: onDeleteSection,
          onExportAudio: onExportAudio,
          onConvertToMp3: onConvertToMp3,
          onSaveRecordingAsMaster: onSaveRecordingAsMaster,
          onSaveSectionAsMaster: onSaveSectionAsMaster,
          onWaveformSeek: onWaveformSeek,
          rangeStartMs: rangeStartMs,
          sectionStartMs: sectionStartMs,
          volumeBoostDb: volumeBoostDb,
          channelMode: channelMode,
          onSetVolumeBoost: onSetVolumeBoost,
          onSetChannelMode: onSetChannelMode,
          notes: notes,
          sections: sections,
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

  String _recordingSubtitle(Recording recording) {
    final pieces = <String>[
      if (recording.title != null) recording.filename,
      _fileDetails(recording),
      if (_bestFingerprintMatch(recording) case final match?)
        'Match: ${match.displayName} (${(match.confidence * 100).round()}%)',
    ];
    return pieces.join(' • ');
  }

  FingerprintMatch? _bestFingerprintMatch(Recording recording) {
    final matches = fingerprintMatches
        .where((item) => item.recordingId == recording.id)
        .toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    return matches.isEmpty ? null : matches.first;
  }

  List<UserAnnotation> _visibleReviewNotes(PracticeFolder practice) {
    final filtered = reviewNotes.where((item) {
      final matchesUser =
          reviewUserFilter == null || item.user == reviewUserFilter;
      final matchesRecording = reviewRecordingFilter == null ||
          item.annotation.recordingId == reviewRecordingFilter;
      return matchesUser && matchesRecording;
    }).toList();
    filtered.sort((a, b) {
      switch (reviewSort) {
        case _ReviewSort.created:
          return a.annotation.createdAt.compareTo(b.annotation.createdAt);
        case _ReviewSort.user:
          final user = a.user.compareTo(b.user);
          if (user != 0) return user;
          return a.annotation.startMs.compareTo(b.annotation.startMs);
        case _ReviewSort.trackTime:
          final recording = _recordingIndex(practice, a.annotation.recordingId)
              .compareTo(_recordingIndex(practice, b.annotation.recordingId));
          if (recording != 0) return recording;
          return a.annotation.startMs.compareTo(b.annotation.startMs);
      }
    });
    return filtered;
  }

  int _recordingIndex(PracticeFolder practice, String recordingId) {
    final index =
        practice.recordings.indexWhere((item) => item.id == recordingId);
    return index == -1 ? 999999 : index;
  }

  String _recordingLabel(PracticeFolder practice, String recordingId) {
    final recording =
        practice.recordings.where((item) => item.id == recordingId).firstOrNull;
    return recording?.title ?? recording?.filename ?? 'Missing take';
  }

  String _reviewTime(PracticeAnnotation note) {
    String stamp(int ms) =>
        '${(ms ~/ 60000).toString().padLeft(2, '0')}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}';
    return note.isRange
        ? '${stamp(note.startMs)} – ${stamp(note.endMs!)}'
        : stamp(note.startMs);
  }
}

class _PlayerPanel extends StatefulWidget {
  const _PlayerPanel({
    required this.controller,
    required this.waveform,
    required this.onAddAnnotation,
    required this.onStartRangeNote,
    required this.onStartSection,
    required this.onEditSection,
    required this.onDeleteSection,
    required this.onExportAudio,
    required this.onConvertToMp3,
    required this.onSaveRecordingAsMaster,
    required this.onSaveSectionAsMaster,
    required this.onWaveformSeek,
    required this.rangeStartMs,
    required this.sectionStartMs,
    required this.volumeBoostDb,
    required this.channelMode,
    required this.onSetVolumeBoost,
    required this.onSetChannelMode,
    required this.notes,
    required this.sections,
  });
  final AudioController controller;
  final WaveformController waveform;
  final ValueChanged<Recording> onAddAnnotation;
  final ValueChanged<Recording> onStartRangeNote;
  final ValueChanged<Recording> onStartSection;
  final ValueChanged<SongSection> onEditSection;
  final ValueChanged<SongSection> onDeleteSection;
  final Future<void> Function(
          Recording recording, SongSection? section, String extension)
      onExportAudio;
  final ValueChanged<Recording> onConvertToMp3;
  final ValueChanged<Recording> onSaveRecordingAsMaster;
  final void Function(Recording recording, SongSection section)
      onSaveSectionAsMaster;
  final ValueChanged<double> onWaveformSeek;
  final int? rangeStartMs;
  final int? sectionStartMs;
  final double volumeBoostDb;
  final PlaybackChannelMode channelMode;
  final ValueChanged<double> onSetVolumeBoost;
  final ValueChanged<PlaybackChannelMode> onSetChannelMode;
  final List<PracticeAnnotation> notes;
  final List<SongSection> sections;

  @override
  State<_PlayerPanel> createState() => _PlayerPanelState();
}

class _ExportChoice {
  const _ExportChoice(this.extension, this.sectionOnly);

  final String extension;
  final bool sectionOnly;
}

class _PlayerPanelState extends State<_PlayerPanel> {
  double? _hoverProgress;
  PracticeAnnotation? _hoveredNote;
  SongSection? _selectedSection;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final waveform = widget.waveform;
    final onAddAnnotation = widget.onAddAnnotation;
    final onStartRangeNote = widget.onStartRangeNote;
    final onStartSection = widget.onStartSection;
    final onEditSection = widget.onEditSection;
    final onDeleteSection = widget.onDeleteSection;
    final onExportAudio = widget.onExportAudio;
    final onConvertToMp3 = widget.onConvertToMp3;
    final onSaveRecordingAsMaster = widget.onSaveRecordingAsMaster;
    final onSaveSectionAsMaster = widget.onSaveSectionAsMaster;
    final onWaveformSeek = widget.onWaveformSeek;
    final rangeStartMs = widget.rangeStartMs;
    final sectionStartMs = widget.sectionStartMs;
    final volumeBoostDb = widget.volumeBoostDb;
    final channelMode = widget.channelMode;
    final onSetVolumeBoost = widget.onSetVolumeBoost;
    final onSetChannelMode = widget.onSetChannelMode;
    final notes = widget.notes;
    final sections = widget.sections;
    return AnimatedBuilder(
      animation: Listenable.merge([controller, waveform]),
      builder: (context, _) {
        final duration = controller.duration ?? Duration.zero;
        final position =
            controller.position > duration ? duration : controller.position;
        final canPlay = controller.recording != null &&
            !controller.isLoading &&
            controller.error == null;
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(controller.recording?.filename ?? 'No take selected',
                    style: Theme.of(context).textTheme.titleMedium),
                if (controller.isLoading)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(),
                  ),
                if (controller.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(controller.error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ),
                if (controller.recording != null) ...[
                  const SizedBox(height: 8),
                  if (waveform.isLoading) const LinearProgressIndicator(),
                  if (waveform.isLoading)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                          'Generating waveform… you can keep listening while this runs.'),
                    ),
                  if (waveform.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(waveform.error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ),
                  if (waveform.data case final data?) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(children: [
                        const Icon(Icons.graphic_eq, size: 16),
                        const SizedBox(width: 6),
                        Text(data.fromCache
                            ? 'Waveform loaded from practice cache'
                            : 'Waveform generated and cached'),
                      ]),
                    ),
                    Container(
                      decoration: BoxDecoration(
                        color:
                            Theme.of(context).colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          SectionTimeline(
                            sections: sections,
                            duration: duration,
                            selectedSection: _selectedSection,
                            onSectionTap: (section) {
                              setState(() => _selectedSection = section);
                              unawaited(controller.seek(
                                  Duration(milliseconds: section.startMs)));
                            },
                          ),
                          WaveformView(
                            peaks: data.peaks,
                            progress: duration == Duration.zero
                                ? 0
                                : position.inMilliseconds /
                                    duration.inMilliseconds,
                            rangeStartProgress:
                                (rangeStartMs ?? sectionStartMs) == null ||
                                        duration == Duration.zero
                                    ? null
                                    : (rangeStartMs ?? sectionStartMs!) /
                                        duration.inMilliseconds,
                            hoverProgress: _hoverProgress,
                            hoverTimeLabel: _hoverProgress == null ||
                                    duration == Duration.zero
                                ? null
                                : _format(Duration(
                                    milliseconds: (_hoverProgress! *
                                            duration.inMilliseconds)
                                        .round())),
                            highlightStartProgress: _hoveredNote == null ||
                                    duration == Duration.zero
                                ? null
                                : _hoveredNote!.startMs /
                                    duration.inMilliseconds,
                            highlightEndProgress: _hoveredNote == null ||
                                    duration == Duration.zero
                                ? null
                                : (_hoveredNote!.endMs ??
                                        _hoveredNote!.startMs) /
                                    duration.inMilliseconds,
                            onSeekProgress: onWaveformSeek,
                            onHoverProgress: (progress) {
                              if (_hoverProgress != progress)
                                setState(() => _hoverProgress = progress);
                            },
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                            child: Row(children: [
                              IconButton(
                                tooltip:
                                    controller.isPlaying ? 'Pause' : 'Play',
                                iconSize: 32,
                                onPressed:
                                    canPlay ? controller.togglePlayback : null,
                                icon: Icon(controller.isPlaying
                                    ? Icons.pause_circle
                                    : Icons.play_circle),
                              ),
                              IconButton(
                                tooltip: 'Stop',
                                onPressed: canPlay ? controller.stop : null,
                                icon: const Icon(Icons.stop_circle_outlined),
                              ),
                              if (_selectedSection != null)
                                IconButton(
                                  tooltip: controller.isLoopingRange
                                      ? 'Stop looping ${_selectedSection!.label}'
                                      : 'Loop ${_selectedSection!.label}',
                                  onPressed: () {
                                    if (controller.isLoopingRange) {
                                      controller.stopRangeLoop();
                                    } else {
                                      unawaited(controller.playRange(
                                        _selectedSection!.startMs,
                                        endMs: _selectedSection!.endMs,
                                        loop: true,
                                      ));
                                    }
                                  },
                                  icon: Icon(controller.isLoopingRange
                                      ? Icons.repeat_one
                                      : Icons.repeat),
                                ),
                              if (_selectedSection != null)
                                IconButton(
                                  tooltip: 'Edit ${_selectedSection!.label}',
                                  onPressed: () {
                                    final section = _selectedSection!;
                                    setState(() => _selectedSection = null);
                                    onEditSection(section);
                                  },
                                  icon: const Icon(Icons.edit_note_outlined),
                                ),
                              if (_selectedSection != null)
                                IconButton(
                                  tooltip: 'Delete ${_selectedSection!.label}',
                                  onPressed: () {
                                    final section = _selectedSection!;
                                    setState(() => _selectedSection = null);
                                    onDeleteSection(section);
                                  },
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              if (_selectedSection != null)
                                IconButton(
                                  tooltip:
                                      'Save ${_selectedSection!.label} as master clip',
                                  onPressed: controller.recording == null
                                      ? null
                                      : () => onSaveSectionAsMaster(
                                          controller.recording!,
                                          _selectedSection!),
                                  icon: const Icon(Icons.library_add_outlined),
                                ),
                              const SizedBox(width: 8),
                              Text(
                                  '${_format(position)} / ${_format(duration)}'),
                              const SizedBox(width: 12),
                              const Expanded(
                                  child: Text('Click waveform to seek')),
                            ]),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
                if (controller.recording != null)
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () => onAddAnnotation(controller.recording!),
                        icon: const Icon(Icons.add_comment_outlined),
                        label: const Text('Add point note'),
                      ),
                      TextButton.icon(
                        onPressed: canPlay
                            ? () => onStartSection(controller.recording!)
                            : null,
                        icon: const Icon(Icons.view_timeline_outlined),
                        label: Text(sectionStartMs == null
                            ? 'Start song section here'
                            : 'Click waveform to end section'),
                      ),
                      TextButton.icon(
                        onPressed: canPlay
                            ? () => onStartRangeNote(controller.recording!)
                            : null,
                        icon: const Icon(Icons.select_all_outlined),
                        label: Text(rangeStartMs == null
                            ? 'Start range note here'
                            : 'Click waveform to end range'),
                      ),
                      PopupMenuButton<double>(
                        tooltip: 'Playback volume boost',
                        onSelected: onSetVolumeBoost,
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                              value: 0, child: Text('Original level (0 dB)')),
                          PopupMenuItem(value: 3, child: Text('Boost +3 dB')),
                          PopupMenuItem(value: 6, child: Text('Boost +6 dB')),
                          PopupMenuItem(value: 9, child: Text('Boost +9 dB')),
                          PopupMenuItem(value: 12, child: Text('Boost +12 dB')),
                          PopupMenuItem(value: 15, child: Text('Boost +15 dB')),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 8),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.volume_up_outlined),
                            const SizedBox(width: 6),
                            Text(_volumeLabel(volumeBoostDb)),
                          ]),
                        ),
                      ),
                      PopupMenuButton<PlaybackChannelMode>(
                        tooltip: 'Playback channel mode',
                        onSelected: onSetChannelMode,
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                              value: PlaybackChannelMode.stereo,
                              child: Text('Stereo / original channels')),
                          PopupMenuItem(
                              value: PlaybackChannelMode.muteLeft,
                              child: Text('Mute left channel')),
                          PopupMenuItem(
                              value: PlaybackChannelMode.muteRight,
                              child: Text('Mute right channel')),
                          PopupMenuItem(
                              value: PlaybackChannelMode.mono,
                              child: Text('Make mono')),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 8),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.surround_sound_outlined),
                            const SizedBox(width: 6),
                            Text(channelMode.label),
                          ]),
                        ),
                      ),
                      PopupMenuButton<_ExportChoice>(
                        tooltip: 'Export audio',
                        onSelected: (choice) {
                          final recording = controller.recording!;
                          final section =
                              choice.sectionOnly ? _selectedSection : null;
                          unawaited(onExportAudio(
                              recording, section, choice.extension));
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                              value: _ExportChoice('wav', false),
                              child: Text('Export track as WAV')),
                          const PopupMenuItem(
                              value: _ExportChoice('mp3', false),
                              child: Text('Export track as MP3')),
                          if (_selectedSection != null) ...const [
                            PopupMenuDivider(),
                            PopupMenuItem(
                                value: _ExportChoice('wav', true),
                                child: Text('Export selected section as WAV')),
                            PopupMenuItem(
                                value: _ExportChoice('mp3', true),
                                child: Text('Export selected section as MP3')),
                          ],
                        ],
                        child: const Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.ios_share_outlined),
                            SizedBox(width: 6),
                            Text('Export'),
                          ]),
                        ),
                      ),
                      if (controller.recording!.extension == '.wav' ||
                          controller.recording!.extension == '.wave')
                        TextButton.icon(
                          onPressed: () =>
                              onConvertToMp3(controller.recording!),
                          icon: const Icon(Icons.audio_file_outlined),
                          label: const Text('Convert to MP3'),
                        ),
                      TextButton.icon(
                        onPressed: () =>
                            onSaveRecordingAsMaster(controller.recording!),
                        icon: const Icon(Icons.library_music_outlined),
                        label: const Text('Save as master'),
                      ),
                    ],
                  ),
                if (controller.recording != null)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text('Notes (${notes.length})'),
                    children: notes.isEmpty
                        ? const [
                            ListTile(
                                dense: true,
                                title: Text('No notes for this take yet.'))
                          ]
                        : notes
                            .map((note) => MouseRegion(
                                  onEnter: (_) =>
                                      setState(() => _hoveredNote = note),
                                  onExit: (_) {
                                    if (_hoveredNote?.id == note.id)
                                      setState(() => _hoveredNote = null);
                                  },
                                  child: ListTile(
                                    dense: true,
                                    leading: Icon(note.isRange
                                        ? Icons.compare_arrows
                                        : Icons.bookmark_outline),
                                    title: Text(note.isRange
                                        ? 'Range note • ${note.text}'
                                        : 'Point note • ${note.text}'),
                                    subtitle: Text(note.isRange
                                        ? '${_format(Duration(milliseconds: note.startMs))} – ${_format(Duration(milliseconds: note.endMs!))}'
                                        : _format(Duration(
                                            milliseconds: note.startMs))),
                                    onTap: () => controller.playFromNote(
                                        note.startMs,
                                        endMs: note.endMs),
                                  ),
                                ))
                            .toList(),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _format(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _volumeLabel(double decibels) =>
      decibels == 0 ? 'Original level' : '+${decibels.toStringAsFixed(0)} dB';
}

class _ActivityStrip extends StatelessWidget {
  const _ActivityStrip({required this.activities});
  final List<Activity> activities;

  @override
  Widget build(BuildContext context) {
    final active = activities
        .where((item) => item.state == ActivityState.running)
        .toList();
    if (active.isEmpty) return const SizedBox.shrink();
    final item = active.first;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ListTile(
        leading: const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2)),
        title: Text(item.label),
        subtitle: Text(item.detail),
        trailing: SizedBox(
            width: 180, child: LinearProgressIndicator(value: item.progress)),
      ),
    );
  }
}
