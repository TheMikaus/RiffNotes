import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;

import 'activity.dart';
import 'annotations.dart';
import 'app_log.dart';
import 'audio_processing.dart';
import 'app_preferences.dart';
import 'audio_controller.dart';
import 'domain.dart';
import 'fingerprints.dart';
import 'google_drive_sync.dart';
import 'sections.dart';
import 'sync.dart';
import 'waveform.dart';
import 'waveform_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const RiffNotesApp());
}

class RiffNotesApp extends StatelessWidget {
  const RiffNotesApp({super.key, this.disableAudio = false});

  final bool disableAudio;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'RiffNotes',
        theme: ThemeData(
            colorSchemeSeed: Colors.deepPurple,
            brightness: Brightness.dark,
            useMaterial3: true),
        home: LibraryScreen(disableAudio: disableAudio),
      );
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, this.disableAudio = false});

  final bool disableAudio;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _repository = PracticeRepository();
  final _annotations = AnnotationRepository();
  final _sectionsRepository = SongSectionRepository();
  final _syncRepository = PracticeSyncRepository();
  final _googleDriveSync = GoogleDriveSyncRepository();
  final _activity = ActivityQueue();
  final _log = AppLog();
  final _audioProcessing = AudioProcessingRepository();
  final _fingerprints = FingerprintRepository();
  final _fingerprintDecisions = FingerprintDecisionRepository();
  final _fingerprintSuggestions = FingerprintSuggestionRepository();
  final _fingerprintLearning = FingerprintLearningRepository();
  final _fingerprintCorrections = FingerprintCorrectionRepository();
  late final AudioController _audio;
  late final WaveformController _waveform;
  late final AppPreferences _preferences;
  StreamSubscription<FileSystemEvent>? _selectedFolderWatcher;
  Timer? _selectedFolderRefreshTimer;
  List<PracticeFolder> _practices = const [];
  PracticeFolder? _mastersPractice;
  PracticeFolder? _selected;
  bool _selectedIsMasters = false;
  Recording? _selectedRecording;
  List<PracticeAnnotation> _notes = const [];
  List<UserAnnotation> _reviewNotes = const [];
  List<SongSection> _sections = const [];
  final List<List<SongSection>> _sectionUndoStack = <List<SongSection>>[];
  List<FingerprintMatch> _fingerprintRawMatches = const [];
  List<FingerprintMatch> _fingerprintMatches = const [];
  FingerprintDecisions _fingerprintDecisionState = const FingerprintDecisions();
  GoogleDriveOAuthConfig? _bundledGoogleOAuthConfig;
  GoogleDriveConnection? _googleDriveConnection;
  StreamSubscription? _googleDriveCredentialSubscription;
  PackageInfo? _packageInfo;
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
  bool _playerPanelCollapsed = false;
  bool _applyingAudioOutput = false;
  bool _refreshingSelectedFolder = false;
  String? _appliedAudioOutputDevice;
  DateTime? _lastSectionResizeLogAt;
  bool _sectionResizeGestureActive = false;

  @override
  void initState() {
    super.initState();
    _audio = widget.disableAudio ? AudioController.inert() : AudioController();
    _waveform = WaveformController();
    _preferences = AppPreferences();
    unawaited(_restorePreferences());
  }

  @override
  void dispose() {
    unawaited(_selectedFolderWatcher?.cancel());
    _selectedFolderRefreshTimer?.cancel();
    unawaited(_googleDriveCredentialSubscription?.cancel());
    _googleDriveConnection?.close();
    _audio.dispose();
    _waveform.dispose();
    super.dispose();
  }

  Directory? get _resolvedMastersFolder {
    final saved = _preferences.mastersFolder?.trim();
    if (saved != null && saved.isNotEmpty) {
      if (path.isAbsolute(saved)) return Directory(saved);
      final bandFolder = _bandFolder ?? _preferences.bandFolder;
      if (bandFolder != null && bandFolder.trim().isNotEmpty) {
        return Directory(path.join(bandFolder, saved));
      }
      return Directory(saved);
    }
    final bandFolder = _bandFolder ?? _preferences.bandFolder;
    if (bandFolder == null || bandFolder.trim().isEmpty) return null;
    return Directory(path.join(bandFolder, 'Masters'));
  }

  Future<void> _chooseBandFolder() async {
    final selection = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose Band Folder',
    );
    if (selection == null || selection.trim().isEmpty) return;
    await _openBandFolder(selection, remember: true);
  }

  Future<void> _chooseSyncFolder() async {
    final selection = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose Sync Folder',
    );
    if (selection == null || selection.trim().isEmpty) return;
    await _preferences.setSyncFolder(selection);
  }

  Future<void> _chooseMastersFolder() async {
    final selection = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose Masters Folder',
    );
    if (selection == null || selection.trim().isEmpty) return;
    await _preferences.setMastersFolder(selection);
    await _refreshMastersList();
  }

  Future<Directory?> _requireSyncFolder() async {
    final saved = _preferences.syncFolder?.trim();
    if (saved != null && saved.isNotEmpty) return Directory(saved);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Choose a Google Drive sync folder in Preferences.')));
    }
    return null;
  }

  Future<Directory?> _requireMastersFolder() async {
    final resolved = _resolvedMastersFolder;
    if (resolved != null) return resolved;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Choose or create a Masters folder in Preferences.')));
    }
    return null;
  }

  Future<void> _importGoogleOAuthJson() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle: 'Choose Google OAuth JSON',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      final file = picked?.files.firstOrNull;
      if (file == null) return;
      final bytes = file.bytes ?? await File(file.path!).readAsBytes();
      final content = utf8.decode(bytes);
      final config = GoogleDriveOAuthConfig.fromJsonContent(content);
      if (config == null || !config.isConfigured) {
        throw const FormatException('Missing client_id in OAuth JSON.');
      }
      await _preferences.setGoogleClientConfig(
        clientId: config.clientId,
        clientSecret: config.clientSecret,
      );
      await _disconnectGoogleDrive();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Google OAuth JSON imported. Connect when ready.')));
      }
    } on FormatException catch (error) {
      if (mounted) {
        _showCopyableError(
            'Could not import Google OAuth JSON: ${error.message}');
      }
    } catch (error) {
      if (mounted) {
        _showCopyableError('Could not import Google OAuth JSON: $error');
      }
    }
  }

  Future<void> _editGoogleClientConfig() async {
    final clientIdController =
        TextEditingController(text: _preferences.googleClientId ?? '');
    final clientSecretController =
        TextEditingController(text: _preferences.googleClientSecret ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Google OAuth client'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: clientIdController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Client ID'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: clientSecretController,
                decoration: const InputDecoration(
                    labelText: 'Client secret (optional)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved == true) {
      await _preferences.setGoogleClientConfig(
        clientId: clientIdController.text,
        clientSecret: clientSecretController.text,
      );
      await _disconnectGoogleDrive();
    }
    clientIdController.dispose();
    clientSecretController.dispose();
  }

  Future<GoogleDriveConnection> _requireGoogleDriveConnection() async {
    final existing = _googleDriveConnection;
    if (existing != null) return existing;
    final bundled = _bundledGoogleOAuthConfig;
    final clientId = _preferences.googleClientId ?? bundled?.clientId;
    final clientSecret =
        _preferences.googleClientSecret ?? bundled?.clientSecret;
    if (clientId == null || clientId.trim().isEmpty) {
      throw StateError('Import OAuth JSON in Preferences before connecting.');
    }
    final connection = await _googleDriveSync.connect(
      clientId: clientId,
      clientSecret: clientSecret,
      savedCredentialsJson: _preferences.googleDriveCredentials,
    );
    await _googleDriveCredentialSubscription?.cancel();
    _googleDriveCredentialSubscription =
        connection.credentialUpdates.listen((credentials) {
      unawaited(_preferences
          .setGoogleDriveCredentials(jsonEncode(credentials.toJson())));
    });
    await _preferences.setGoogleDriveCredentials(connection.credentialsJson);
    _googleDriveConnection = connection;
    return connection;
  }

  Future<void> _connectGoogleDrive() async {
    try {
      await _requireGoogleDriveConnection();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Google Drive connected.')));
      }
    } on StateError catch (error) {
      if (mounted) {
        _showCopyableError(error.message);
      }
    } catch (error) {
      if (mounted) {
        _showCopyableError('Google Drive connection failed: $error');
      }
    }
  }

  Future<void> _disconnectGoogleDrive() async {
    await _googleDriveCredentialSubscription?.cancel();
    _googleDriveCredentialSubscription = null;
    _googleDriveConnection?.close();
    _googleDriveConnection = null;
    await _preferences.clearGoogleDriveConnection();
  }

  Future<void> _chooseGoogleDriveRootFolder() async {
    try {
      final connection = await _requireGoogleDriveConnection();
      if (!mounted) return;
      final selected = await showDialog<GoogleDriveFolder>(
        context: context,
        builder: (context) => _GoogleDriveFolderBrowser(connection: connection),
      );
      if (selected == null) return;
      await _preferences.setGoogleDriveRootFolder(
        id: selected.id,
        name: selected.name,
      );
    } on StateError catch (error) {
      if (mounted) {
        _showCopyableError(error.message);
      }
    } catch (error) {
      if (mounted) {
        _showCopyableError('Could not browse Google Drive: $error');
      }
    }
  }

  void _showCopyableError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      action: SnackBarAction(
        label: 'Copy',
        onPressed: () => Clipboard.setData(ClipboardData(text: message)),
      ),
    ));
  }

  Future<void> _restorePreferences() async {
    await _preferences.load();
    final bundledGoogleOAuthConfig = await GoogleDriveOAuthConfig.loadBundled();
    final packageInfo = await PackageInfo.fromPlatform();
    _bundledGoogleOAuthConfig = bundledGoogleOAuthConfig;
    _packageInfo = packageInfo;
    if (_preferences.fingerprintFeatureWeights.isNotEmpty) {
      _fingerprints
          .setFeatureWeightProfile(_preferences.fingerprintFeatureWeights);
    }
    if (mounted) {
      setState(() => _playerPanelCollapsed = _preferences.playerPanelCollapsed);
    }
    _applyPreferredAudioOutputIfPossible();
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
    final mastersPractice = await _loadMastersPractice();
    if (mounted) {
      setState(() {
        _practices = practices;
        _mastersPractice = mastersPractice;
        _selectedIsMasters = false;
        _selected = practices
                .where((item) => item.name == _preferences.lastPractice)
                .firstOrNull ??
            (practices.isEmpty ? null : practices.first);
        _selectedRecording = null;
        _sections = const [];
        _sectionUndoStack.clear();
        _rangeStartMs = null;
        _rangeRecordingId = null;
      });
      _watchSelectedFolder(_selected);
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

  Future<void> _setPlayerPanelCollapsed(bool value) async {
    setState(() => _playerPanelCollapsed = value);
    await _preferences.setPlayerPanelCollapsed(value);
  }

  Future<void> _selectPractice(PracticeFolder practice) async {
    final refreshed = await _repository.openPractice(practice.directory);
    setState(() {
      _selectedIsMasters = false;
      _replaceSelectedPractice(refreshed);
      _selectedRecording = null;
      _sections = const [];
      _sectionUndoStack.clear();
      _rangeStartMs = null;
      _rangeRecordingId = null;
      _sectionStartMs = null;
      _sectionRecordingId = null;
      _reviewRecordingFilter = null;
    });
    _watchSelectedFolder(refreshed);
    _waveform.clear();
    await _refreshPracticeReview(refreshed);
    await _refreshFingerprintDecisions(refreshed);
    await _preferences.rememberPractice(refreshed.name);
    final remembered = refreshed.recordings
        .where((item) =>
            item.id == _preferences.lastRecordingForPractice(refreshed.name))
        .firstOrNull;
    if (remembered != null) {
      await _selectRecording(remembered);
    } else if (refreshed.recordings.isNotEmpty) {
      await _selectRecording(refreshed.recordings.first,
          autoPlay: _preferences.autoPlayOnPracticeSelection);
    }
  }

  Future<PracticeFolder?> _loadMastersPractice({bool create = false}) async {
    final directory = _resolvedMastersFolder;
    if (directory == null) return null;
    if (!await directory.exists()) {
      if (!create) {
        return PracticeFolder(directory: directory, recordings: const []);
      }
      await directory.create(recursive: true);
    }
    return _repository.openPractice(directory);
  }

  Future<void> _selectMastersLibrary() async {
    final masters = await _activity.run('Opening Masters', (update) async {
      update(null, 'Loading master recordings…');
      final result = await _loadMastersPractice(create: true);
      update(1, 'Masters ready');
      return result;
    });
    if (!mounted || masters == null) return;
    setState(() {
      _mastersPractice = masters;
      _selected = masters;
      _selectedIsMasters = true;
      _selectedRecording = null;
      _sections = const [];
      _sectionUndoStack.clear();
      _rangeStartMs = null;
      _rangeRecordingId = null;
      _sectionStartMs = null;
      _sectionRecordingId = null;
      _reviewRecordingFilter = null;
      _showPracticeReview = false;
      _fingerprintRawMatches = const [];
      _fingerprintMatches = const [];
      _fingerprintDecisionState = const FingerprintDecisions();
      _reviewNotes = const [];
    });
    _watchSelectedFolder(masters);
    _waveform.clear();
    if (masters.recordings.isNotEmpty) {
      await _selectRecording(masters.recordings.first,
          autoPlay: _preferences.autoPlayOnPracticeSelection);
    }
  }

  Future<void> _selectRecording(Recording recording,
      {bool autoPlay = false}) async {
    final rememberedBoost = _preferences.boostFor(recording.id);
    final rememberedChannelMode = _preferences.channelModeFor(recording.id);
    setState(() {
      _selectedRecording = recording;
      _sectionUndoStack.clear();
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
    if (_selected != null) {
      await _preferences.rememberSelection(_selected!.name, recording.id);
    }
    await _refreshNotes(recording);
    await _refreshSections(recording);
  }

  void _replaceSelectedPractice(PracticeFolder updatedPractice) {
    _selected = updatedPractice;
    if (_selectedIsMasters) {
      _mastersPractice = updatedPractice;
    } else {
      _practices = _practices
          .map((item) => item.directory.path == updatedPractice.directory.path
              ? updatedPractice
              : item)
          .toList(growable: false);
    }
  }

  void _watchSelectedFolder(PracticeFolder? practice) {
    unawaited(_selectedFolderWatcher?.cancel());
    _selectedFolderWatcher = null;
    _selectedFolderRefreshTimer?.cancel();
    _selectedFolderRefreshTimer = null;
    if (practice == null) return;
    try {
      _selectedFolderWatcher = practice.directory.watch().listen((event) {
        if (!_isAudioFilePath(event.path)) return;
        _scheduleSelectedFolderRefresh();
      }, onError: (_) {});
    } on FileSystemException {
      // Some folders cannot be watched. They still refresh when selected/opened.
    }
  }

  bool _isAudioFilePath(String filePath) =>
      supportedAudioExtensions.contains(path.extension(filePath).toLowerCase());

  void _scheduleSelectedFolderRefresh() {
    _selectedFolderRefreshTimer?.cancel();
    _selectedFolderRefreshTimer = Timer(
        const Duration(milliseconds: 700), _refreshSelectedFolderFromDisk);
  }

  Future<void> _refreshSelectedFolderFromDisk() async {
    if (_refreshingSelectedFolder) {
      _scheduleSelectedFolderRefresh();
      return;
    }
    final current = _selected;
    if (current == null) return;
    _refreshingSelectedFolder = true;
    final selectedPath = current.directory.path;
    final previousRecording = _selectedRecording;
    try {
      final refreshed = await _repository.openPractice(current.directory);
      if (!mounted || _selected?.directory.path != selectedPath) return;
      final nextRecording = _bestRefreshedRecording(
        refreshed,
        previousRecording,
      );
      setState(() {
        _replaceSelectedPractice(refreshed);
        _selectedRecording = nextRecording;
        if (nextRecording == null) {
          _notes = const [];
          _sections = const [];
          _sectionUndoStack.clear();
          _rangeStartMs = null;
          _rangeRecordingId = null;
          _sectionStartMs = null;
          _sectionRecordingId = null;
        }
      });
      if (nextRecording == null) {
        await _audio.stop();
        _waveform.clear();
        if (!_selectedIsMasters) {
          await _refreshPracticeReview(refreshed);
          await _refreshFingerprintDecisions(refreshed);
        }
        return;
      }
      if (previousRecording?.id != nextRecording.id ||
          previousRecording?.filename != nextRecording.filename) {
        await _selectRecording(nextRecording);
      } else {
        await _refreshNotes(nextRecording);
        await _refreshSections(nextRecording);
      }
      if (!_selectedIsMasters) {
        await _refreshPracticeReview(refreshed);
        await _refreshFingerprintDecisions(refreshed);
      }
    } finally {
      _refreshingSelectedFolder = false;
    }
  }

  Recording? _bestRefreshedRecording(
    PracticeFolder refreshed,
    Recording? previous,
  ) {
    if (refreshed.recordings.isEmpty) return null;
    if (previous == null) return refreshed.recordings.first;
    return refreshed.recordings
            .where((item) => item.id == previous.id)
            .firstOrNull ??
        refreshed.recordings
            .where((item) => item.filename == previous.filename)
            .firstOrNull ??
        refreshed.recordings.first;
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

  void _applyPreferredAudioOutputIfPossible() {
    final saved = _preferences.audioOutputDevice;
    if (saved == null || saved == _appliedAudioOutputDevice) return;
    final device =
        _audio.audioDevices.where((item) => item.name == saved).firstOrNull;
    if (device == null || _applyingAudioOutput) return;
    _applyingAudioOutput = true;
    unawaited(_audio.setAudioDevice(device).then((_) {
      _appliedAudioOutputDevice = saved;
    }).whenComplete(() {
      _applyingAudioOutput = false;
    }));
  }

  Future<void> _setAudioOutputDevice(AudioDevice device) async {
    await _audio.setAudioDevice(device);
    await _preferences
        .setAudioOutputDevice(device.name == 'auto' ? null : device.name);
    _appliedAudioOutputDevice = device.name == 'auto' ? null : device.name;
  }

  String _audioDeviceLabel(AudioDevice device) {
    if (device.name == 'auto') return 'Windows default output';
    final description = device.description.trim();
    return description.isEmpty ? device.name : description;
  }

  String _audioOutputSubtitle() => _audioDeviceLabel(_audio.audioDevice);

  String _mastersFolderLabel() {
    final saved = _preferences.mastersFolder;
    final resolved = _resolvedMastersFolder;
    if (resolved == null) return 'None selected';
    if (saved == null || saved.trim().isEmpty) {
      return '${resolved.path} (default)';
    }
    return path.isAbsolute(saved) ? saved : '$saved → ${resolved.path}';
  }

  String _googleDriveStatusLabel() {
    if (!_hasGoogleOAuthConfig) {
      return 'No OAuth JSON imported yet.';
    }
    if (_preferences.googleDriveCredentials == null) {
      if (_preferences.hasGoogleClientConfig) {
        return 'OAuth JSON imported. Not connected yet.';
      }
      return 'Ready to connect with the bundled RiffNotes OAuth client.';
    }
    return 'Connected. Direct Drive upload/download is the next slice.';
  }

  bool get _hasGoogleOAuthConfig =>
      _bundledGoogleOAuthConfig?.isConfigured == true ||
      _preferences.hasGoogleClientConfig;

  String _googleDriveRootLabel() {
    final name = _preferences.googleDriveRootFolderName;
    final id = _preferences.googleDriveRootFolderId;
    if (name == null || id == null) return 'No Drive folder selected.';
    return '$name ($id)';
  }

  String _appVersionLabel() {
    final info = _packageInfo;
    if (info == null) return 'Version loading…';
    return 'Version ${info.version}+${info.buildNumber}';
  }

  String _recordingDisplayName(Recording recording) {
    final title = recording.title?.trim();
    if (title == null || title.isEmpty) return recording.filename;
    return '$title (${recording.filename})';
  }

  List<String> _quickSongTitlesForPractice(PracticeFolder practice) {
    final titles = <String>{
      ..._preferences.fingerprintSongTitlesForPractice(practice.directory.path),
      ...(_mastersPractice?.recordings
              .map((item) => item.title?.trim())
              .whereType<String>()
              .where((item) => item.isNotEmpty) ??
          const <String>[]),
      ...practice.recordings
          .map((item) => item.title?.trim())
          .whereType<String>()
          .where((item) => item.isNotEmpty),
    };
    final result = titles.toList(growable: false)
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return result;
  }

  Future<void> _quickSetRecordingTitle(
      Recording recording, String title) async {
    final cleaned = title.trim();
    if (cleaned.isEmpty) return;
    await _updateRecording(
      recording,
      title: cleaned,
      isBestTake: recording.isBestTake,
    );
    await _teachFingerprintGuessFromQuickTitle(recording, cleaned);
  }

  Future<void> _teachFingerprintGuessFromQuickTitle(
      Recording recording, String title) async {
    final practice = _selected;
    if (practice == null) return;
    final matches = _fingerprintRawMatches
        .where((item) => item.recordingId == recording.id)
        .toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    final mastersFolder = _resolvedMastersFolder;
    if (mastersFolder != null && matches.isNotEmpty) {
      await _fingerprintCorrections.add(
        mastersFolder.path,
        FingerprintCorrection(
          recordingId: recording.id,
          recordingFilename: recording.filename,
          recordingTitle: title,
          practiceName: practice.name,
          practicePath: practice.directory.path,
          correctType: 'new',
          correctMasterRecordingId: null,
          correctMasterFilename: null,
          correctMasterTitle: null,
          correctSectionLabel: null,
          notes: '',
          report: _fingerprintCorrectionReport(
            recording: recording,
            matches: matches,
            correctType: 'new',
            correctMaster: null,
            correctSectionLabel: null,
            newSongTitle: title,
            notes: '',
          ),
          recordedAt: DateTime.now().toUtc(),
        ),
      );
    }
    await _clearFingerprintGuessForRecording(recording.id);
    await _preferences.rememberFingerprintSongTitle(
        practice.directory.path, title);
  }

  Future<void> _clearFingerprintGuessForRecording(String recordingId) async {
    final remainingRaw =
        _fingerprintRawMatches.where((item) => item.recordingId != recordingId);
    final remainingVisible =
        _fingerprintMatches.where((item) => item.recordingId != recordingId);
    if (mounted) {
      setState(() {
        _fingerprintRawMatches = remainingRaw.toList(growable: false);
        _fingerprintMatches = remainingVisible.toList(growable: false);
      });
    }
    final practice = _selected;
    if (practice != null) {
      await _fingerprintSuggestions.save(
          practice.directory.path, _fingerprintRawMatches);
    }
  }

  Map<String, double> _currentFingerprintWeightProfile() {
    final defaults = FingerprintRepository.defaultFeatureWeightProfile();
    final current = _fingerprints.featureWeightProfile();
    return {
      for (final entry in defaults.entries)
        entry.key: current[entry.key] ?? entry.value,
    };
  }

  Future<void> _applyFingerprintWeightProfile(
      Map<String, double> profile) async {
    _fingerprints.setFeatureWeightProfile(profile);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Fingerprint weight profile applied for this session.')));
  }

  Future<void> _saveFingerprintWeightProfile(
      Map<String, double> profile) async {
    _fingerprints.setFeatureWeightProfile(profile);
    await _preferences.setFingerprintFeatureWeights(profile);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fingerprint weight profile saved.')));
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
    final suggestions =
        await _fingerprintSuggestions.load(practice.directory.path);
    final visibleMatches =
        _visibleFingerprintMatches(practice, suggestions, decisions);
    _logFingerprintState(
      practicePath: practice.directory.path,
      phase: 'refresh',
      suggestions: suggestions,
      decisions: decisions,
      visibleMatches: visibleMatches,
    );
    if (mounted && _selected?.directory.path == practice.directory.path) {
      setState(() {
        _fingerprintDecisionState = decisions;
        _fingerprintRawMatches = suggestions;
        _fingerprintMatches = visibleMatches;
      });
    }
  }

  Future<void> _uploadSelectedPractice() async {
    final practice = _selected;
    if (practice == null) return;
    final syncFolder = await _requireSyncFolder();
    if (syncFolder == null) return;
    try {
      final candidates = await _syncRepository.listUploadCandidates(
        practiceFolder: practice.directory,
        syncRoot: syncFolder,
      );
      if (!mounted) return;
      if (candidates.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No uploadable files were found.')));
        return;
      }
      final decision = await _confirmUploadSelection(practice, candidates);
      if (decision == null) return;
      if (decision.files.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Nothing selected.')));
        return;
      }
      final result = await _activity.run('Uploading practice', (update) async {
        update(null,
            'Copying ${decision.files.length} files from ${practice.name} to sync folder…');
        final copied = await _syncRepository.uploadPracticeSelection(
          practiceFolder: practice.directory,
          syncRoot: syncFolder,
          relativePaths:
              decision.files.map((item) => item.relativePath).toSet(),
          changedOnly: decision.changedOnly,
          deleteMissingFiles: decision.deleteMissingFiles,
        );
        update(1, 'Upload complete');
        return copied;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_syncSummary(
                verb: 'Uploaded',
                result: result,
                practiceName: practice.name))));
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

  Future<
          ({
            List<SyncFileCandidate> files,
            bool changedOnly,
            bool deleteMissingFiles
          })?>
      _confirmUploadSelection(
          PracticeFolder practice, List<SyncFileCandidate> candidates) async {
    final selectedPaths = candidates.map((item) => item.relativePath).toSet();
    var changedOnly = true;
    var deleteMissingFiles = false;
    return showDialog<
        ({
          List<SyncFileCandidate> files,
          bool changedOnly,
          bool deleteMissingFiles
        })>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final allSelected = selectedPaths.length == candidates.length;
          final changedCount =
              candidates.where((item) => item.isLikelyChanged).length;
          return AlertDialog(
            title: Text('Upload ${practice.name}'),
            content: SizedBox(
              width: 860,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      'Select files to upload to the sync folder. All files start selected.'),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: changedOnly,
                    onChanged: (value) =>
                        setDialogState(() => changedOnly = value ?? true),
                    title: const Text('Only copy changed files'),
                    subtitle: Text(
                        'Estimated changed files: $changedCount/${candidates.length}'),
                  ),
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: deleteMissingFiles,
                    onChanged: (value) => setDialogState(
                        () => deleteMissingFiles = value ?? false),
                    title: const Text(
                        'Delete files in sync folder that are missing locally'),
                    subtitle: const Text(
                        'Use carefully. With partial selection, unselected files can be deleted.'),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: allSelected
                            ? null
                            : () => setDialogState(() {
                                  selectedPaths
                                    ..clear()
                                    ..addAll(candidates
                                        .map((item) => item.relativePath));
                                }),
                        child: const Text('Select all'),
                      ),
                      TextButton(
                        onPressed: selectedPaths.isEmpty
                            ? null
                            : () => setDialogState(selectedPaths.clear),
                        child: const Text('Clear all'),
                      ),
                      Text(
                          '${selectedPaths.length}/${candidates.length} selected'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: candidates.length,
                      itemBuilder: (context, index) {
                        final candidate = candidates[index];
                        final isSelected =
                            selectedPaths.contains(candidate.relativePath);
                        return CheckboxListTile(
                          dense: true,
                          value: isSelected,
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged: (value) {
                            setDialogState(() {
                              if (value == true) {
                                selectedPaths.add(candidate.relativePath);
                              } else {
                                selectedPaths.remove(candidate.relativePath);
                              }
                            });
                          },
                          title: Text(candidate.relativePath),
                          subtitle: Text(
                              '${_formatBytes(candidate.sizeBytes)}${candidate.existsInSync ? ' • exists in sync folder' : ''}${candidate.existsInSync && !candidate.isLikelyChanged ? ' • unchanged' : ''}'),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: selectedPaths.isEmpty
                    ? null
                    : () {
                        final selection = candidates
                            .where((item) =>
                                selectedPaths.contains(item.relativePath))
                            .toList(growable: false);
                        Navigator.pop(context, (
                          files: selection,
                          changedOnly: changedOnly,
                          deleteMissingFiles: deleteMissingFiles,
                        ));
                      },
                child: Text('Upload ${selectedPaths.length} files'),
              ),
            ],
          );
        },
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(1)} GB';
  }

  String _syncSummary({
    required String verb,
    required SyncResult result,
    required String practiceName,
  }) {
    final details = <String>[];
    if (result.skippedItems > 0) {
      details.add('${result.skippedItems} skipped');
    }
    if (result.deletedFiles > 0) {
      details.add('${result.deletedFiles} deleted');
    }
    final suffix = details.isEmpty ? '' : ' (${details.join(', ')})';
    return '$verb ${result.copiedFiles} files for $practiceName$suffix.';
  }

  Future<void> _downloadSelectedPractice() async {
    final practice = _selected;
    if (practice == null) return;
    final syncFolder = await _requireSyncFolder();
    if (syncFolder == null) return;
    final options = await _confirmDownloadSyncOptions(practice);
    if (options == null) return;
    try {
      final updatedPractice =
          await _activity.run('Downloading practice', (update) async {
        update(null, 'Copying ${practice.name} from sync folder…');
        final result = await _syncRepository.downloadPractice(
          localPracticeFolder: practice.directory,
          syncRoot: syncFolder,
          changedOnly: options.changedOnly,
          deleteMissingFiles: options.deleteMissingFiles,
        );
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
            content: Text(_syncSummary(
                verb: 'Downloaded',
                result: result,
                practiceName: practice.name))));
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

  Future<({bool changedOnly, bool deleteMissingFiles})?>
      _confirmDownloadSyncOptions(PracticeFolder practice) async {
    var changedOnly = true;
    var deleteMissingFiles = false;
    return showDialog<({bool changedOnly, bool deleteMissingFiles})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Download ${practice.name}?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'This copies files from the sync folder into the local practice folder.'),
              const SizedBox(height: 8),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: changedOnly,
                onChanged: (value) =>
                    setDialogState(() => changedOnly = value ?? true),
                title: const Text('Only copy changed files'),
              ),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: deleteMissingFiles,
                onChanged: (value) =>
                    setDialogState(() => deleteMissingFiles = value ?? false),
                title:
                    const Text('Delete local files missing from sync folder'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, (
                      changedOnly: changedOnly,
                      deleteMissingFiles: deleteMissingFiles,
                    )),
                child: const Text('Download')),
          ],
        ),
      ),
    );
  }

  Future<void> _clearSelectedPracticeCache() async {
    final practice = _selected;
    if (practice == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Clear cache for ${practice.name}?'),
        content: const Text(
            'Waveforms, processed playback files, fingerprint files, pending fingerprint suggestions, and fingerprint review decisions will be regenerated or rebuilt when needed. Notes, sections, titles, Best Take flags, audio files, and Masters learning are not removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Clear cache')),
        ],
      ),
    );
    if (confirmed != true) return;
    final cache =
        Directory(path.join(practice.directory.path, '.riffnotes-cache'));
    try {
      await _activity.run('Clearing practice cache', (update) async {
        update(null, 'Removing generated cache and fingerprint state…');
        if (await cache.exists()) await cache.delete(recursive: true);
        await _clearFingerprintState(practice.directory.path);
        update(1, 'Cache cleared');
      });
      _waveform.clear();
      if (mounted && _selected?.directory.path == practice.directory.path) {
        setState(() {
          _fingerprintRawMatches = const [];
          _fingerprintMatches = const [];
          _fingerprintDecisionState = const FingerprintDecisions();
        });
      }
      final recording = _selectedRecording;
      if (recording != null) unawaited(_waveform.load(practice, recording));
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Cache clear failed: ${error.message}')));
      }
    }
  }

  Future<void> _clearMastersCache() async {
    final mastersFolder = _resolvedMastersFolder;
    if (mastersFolder == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Masters cache?'),
        content: Text(
            'Generated waveform and fingerprint files in ${mastersFolder.path} will be regenerated when needed. Master recordings, sections, learning, and correction reports are not removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Clear Masters cache')),
        ],
      ),
    );
    if (confirmed != true) return;
    final cache = Directory(path.join(mastersFolder.path, '.riffnotes-cache'));
    try {
      await _activity.run('Clearing Masters cache', (update) async {
        update(null,
            'Removing generated Masters cache and current fingerprint review state…');
        if (await cache.exists()) await cache.delete(recursive: true);
        final selectedPractice = _selected;
        if (selectedPractice != null) {
          await _clearFingerprintState(selectedPractice.directory.path);
        }
        update(1, 'Masters cache cleared');
      });
      _waveform.clear();
      final selectedPractice = _selected;
      final recording = _selectedRecording;
      if (mounted) {
        setState(() {
          _fingerprintRawMatches = const [];
          _fingerprintMatches = const [];
          _fingerprintDecisionState = const FingerprintDecisions();
        });
      }
      if (selectedPractice != null &&
          recording != null &&
          selectedPractice.directory.path == mastersFolder.path) {
        unawaited(_waveform.load(selectedPractice, recording));
      }
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Masters cache clear failed: ${error.message}')));
      }
    }
  }

  Future<void> _clearFingerprintState(String practicePath) async {
    _logFingerprintState(practicePath: practicePath, phase: 'before-clear');
    await _fingerprintSuggestions.clear(practicePath);
    await _fingerprintDecisions.clear(practicePath);
    _logFingerprintState(practicePath: practicePath, phase: 'after-clear');
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
        final decisions =
            await _fingerprintDecisions.load(practice.directory.path);
        _log.info(
          'fingerprint',
          'Starting run for ${practice.name}; skipAccepted=${decisions.accepted.length}; weights=${_fingerprints.featureWeightProfile()}',
        );
        final result = await _fingerprints.matchPracticeInBackground(
          practicePath: practice.directory.path,
          mastersPath: mastersFolder.path,
          weightProfile: _fingerprints.featureWeightProfile(),
          skipRecordingIds:
              decisions.accepted.map((item) => item.recordingId).toSet(),
          actionableOnly: false,
        );
        update(1, 'Fingerprint matching complete');
        return result;
      });
      if (!mounted) return;
      final decisions =
          await _fingerprintDecisions.load(practice.directory.path);
      final visibleMatches =
          _visibleFingerprintMatches(practice, matches, decisions);
      setState(() {
        _fingerprintRawMatches = matches;
        _fingerprintMatches = visibleMatches;
        _fingerprintDecisionState = decisions;
      });
      try {
        _logFingerprintRunSummary(practice, matches, visibleMatches, decisions);
      } catch (error) {
        _log.warning(
            'fingerprint', 'Run summary logging failed: ${error.toString()}');
      }
      await _fingerprintSuggestions.save(practice.directory.path, matches);
      _logFingerprintState(
        practicePath: practice.directory.path,
        phase: 'after-save',
        suggestions: matches,
        decisions: decisions,
        visibleMatches: visibleMatches,
      );
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

  void _logFingerprintRunSummary(
    PracticeFolder practice,
    List<FingerprintMatch> rawMatches,
    List<FingerprintMatch> visibleMatches,
    FingerprintDecisions decisions,
  ) {
    final rawByRecording = <String, List<FingerprintMatch>>{};
    for (final match in rawMatches) {
      rawByRecording.putIfAbsent(match.recordingId, () => []).add(match);
    }
    final visibleByRecording = <String, List<FingerprintMatch>>{};
    for (final match in visibleMatches) {
      visibleByRecording.putIfAbsent(match.recordingId, () => []).add(match);
    }
    _log.info('fingerprint',
        'Run complete for ${practice.name}: raw=${rawMatches.length}, visible=${visibleMatches.length}, accepted=${decisions.accepted.length}, ignored=${decisions.ignoredKeys.length}');
    _log.info(
      'fingerprint',
      'Run distribution: recordingsWithRaw=${rawByRecording.length}, recordingsWithVisible=${visibleByRecording.length}, totalRecordings=${practice.recordings.length}',
    );
    for (final recording in practice.recordings) {
      if (_isJamRecording(recording)) {
        _log.info('fingerprint',
            '${recording.filename}: skipped because title is Jam');
        continue;
      }
      final rawForRecording =
          (rawByRecording[recording.id] ?? const <FingerprintMatch>[])
              .toList(growable: true);
      final visibleForRecording =
          (visibleByRecording[recording.id] ?? const <FingerprintMatch>[])
              .toList(growable: true);
      if (rawForRecording.isEmpty && visibleForRecording.isEmpty) {
        _log.info('fingerprint',
            '${recording.filename}: no raw or visible suggestions');
        continue;
      }
      rawForRecording.sort((a, b) => b.confidence.compareTo(a.confidence));
      visibleForRecording.sort((a, b) => b.confidence.compareTo(a.confidence));
      final rawBest = rawForRecording.firstOrNull;
      final visibleBest = visibleForRecording.firstOrNull;
      _log.info('fingerprint',
          '${recording.filename}: rawCount=${rawForRecording.length}, visibleCount=${visibleForRecording.length}, rawBest=${rawBest?.displayName ?? 'none'} (${rawBest?.scoreDetails ?? 'n/a'}); visibleBest=${visibleBest?.displayName ?? 'none'} (${visibleBest?.scoreDetails ?? 'n/a'})');
      final topCount = rawForRecording.length < 2 ? rawForRecording.length : 2;
      for (var index = 0; index < topCount; index += 1) {
        final candidate = rawForRecording[index];
        _log.info(
          'fingerprint-candidate',
          '${recording.filename} #${index + 1}: ${candidate.displayName} | ${candidate.scoreDetails} | groupDeltas=${_featureGroupDeltaSummary(candidate)} | ${_fingerprints.actionabilitySummary(candidate)}',
        );
      }
    }
  }

  String _featureGroupDeltaSummary(FingerprintMatch match) {
    const groups = <String>[
      'chroma',
      'energy',
      'attack',
      'lowMotion',
      'highMotion',
      'zeroCrossing',
      'peaks',
    ];
    final parts = <String>[];
    for (final group in groups) {
      final agreement = _featureGroupAgreement(match, group);
      final delta = (1.0 - agreement).clamp(0.0, 1.0).toDouble();
      parts.add('$group ${(delta * 100).toStringAsFixed(1)}%');
    }
    return parts.join(', ');
  }

  double _featureGroupAgreement(FingerprintMatch match, String group) {
    if (group == 'chroma') {
      var total = 0.0;
      var count = 0;
      for (var index = 0; index < 12; index += 1) {
        final value = match.featureScores['chroma$index'];
        if (value == null) continue;
        total += value;
        count += 1;
      }
      if (count == 0) return 0;
      return (total / count).clamp(0.0, 1.0).toDouble();
    }
    return (match.featureScores[group] ?? 0).clamp(0.0, 1.0).toDouble();
  }

  Future<void> _logFingerprintState({
    required String practicePath,
    required String phase,
    List<FingerprintMatch>? suggestions,
    FingerprintDecisions? decisions,
    List<FingerprintMatch>? visibleMatches,
  }) async {
    final suggestionsFile = File(
        path.join(practicePath, '.riffnotes.fingerprint-suggestions.json'));
    final decisionsFile =
        File(path.join(practicePath, '.riffnotes.fingerprint-decisions.json'));
    final suggestionsExists = await suggestionsFile.exists();
    final decisionsExists = await decisionsFile.exists();
    final loadedSuggestions =
        suggestions ?? await _fingerprintSuggestions.load(practicePath);
    final loadedDecisions =
        decisions ?? await _fingerprintDecisions.load(practicePath);
    _log.info(
      'fingerprint-state',
      '[$phase] suggestionsFile=${suggestionsExists ? 'present' : 'missing'}; decisionsFile=${decisionsExists ? 'present' : 'missing'}; suggestions=${loadedSuggestions.length}; accepted=${loadedDecisions.accepted.length}; ignored=${loadedDecisions.ignoredKeys.length}; visible=${visibleMatches?.length ?? 'n/a'}',
    );
  }

  Future<void> _evaluateFingerprintCorrections() async {
    final practice = _selected;
    final mastersFolder = _resolvedMastersFolder;
    if (practice == null || mastersFolder == null) return;
    final reportFuture =
        _buildFingerprintEvaluationReport(practice, mastersFolder);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Fingerprint evaluation'),
        content: FutureBuilder<String>(
          future: reportFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                width: 520,
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    SizedBox(width: 16),
                    Expanded(
                      child: Text(
                          'Calculating evaluation from fresh fingerprint data. This can take a while on larger practices…'),
                    ),
                  ],
                ),
              );
            }
            if (snapshot.hasError) {
              return SizedBox(
                width: 680,
                child: SelectableText(
                    'Evaluation failed: ${snapshot.error ?? 'Unknown error'}'),
              );
            }
            final reportText = snapshot.data ?? '';
            return SizedBox(
              width: 760,
              height: 520,
              child: reportText.contains('Corrections evaluated: 0')
                  ? SelectableText(
                      'No fingerprint corrections found for ${practice.name}.\n\nUse “Teach correct match” on a few takes, then run this evaluation again.')
                  : SingleChildScrollView(child: SelectableText(reportText)),
            );
          },
        ),
        actions: [
          FutureBuilder<String>(
            future: reportFuture,
            builder: (context, snapshot) => TextButton.icon(
                onPressed: snapshot.connectionState == ConnectionState.done &&
                        snapshot.hasData
                    ? () async {
                        final reportText = snapshot.data ?? '';
                        await Clipboard.setData(
                            ClipboardData(text: reportText));
                        if (context.mounted) Navigator.pop(context);
                        if (mounted) {
                          ScaffoldMessenger.of(this.context).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      'Fingerprint evaluation report copied')));
                        }
                      }
                    : null,
                icon: const Icon(Icons.copy),
                label: const Text('Copy report')),
          ),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _showFingerprintFeatureChartDialog() async {
    final practice = _selected;
    if (practice == null) return;
    final masters =
        _mastersPractice ?? await _loadMastersPractice(create: true);
    if (masters == null) return;
    if (practice.recordings.isEmpty || masters.recordings.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Feature chart needs at least one recording and one master.')));
      }
      return;
    }

    final practiceCandidates = practice.recordings
        .where((recording) => !_isJamRecording(recording))
        .toList(growable: false);
    final practicePool =
        practiceCandidates.isEmpty ? practice.recordings : practiceCandidates;
    var selectedRecordingId = (_selectedRecording != null &&
            practicePool.any((item) => item.id == _selectedRecording!.id))
        ? _selectedRecording!.id
        : practicePool.first.id;
    var weightProfile = _currentFingerprintWeightProfile();
    const weightRanges = <String, (double, double)>{
      'chroma': (0.0, 0.25),
      'energy': (0.0, 2.0),
      'attack': (0.0, 2.0),
      'lowMotion': (0.0, 2.0),
      'highMotion': (0.0, 2.0),
      'zeroCrossing': (0.0, 2.0),
      'peaks': (0.0, 1.0),
    };
    Future<_FingerprintFeatureChartData> chartFuture() {
      final recording =
          practicePool.firstWhere((item) => item.id == selectedRecordingId);
      return _buildFingerprintFeatureChartData(
        practice: practice,
        masters: masters,
        recording: recording,
      );
    }

    var future = chartFuture();
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Fingerprint feature chart'),
          content: SizedBox(
            width: 920,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  value: selectedRecordingId,
                  decoration:
                      const InputDecoration(labelText: 'Practice recording'),
                  items: [
                    for (final recording in practicePool)
                      DropdownMenuItem(
                        value: recording.id,
                        child: Text(_recordingDisplayName(recording)),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() {
                      selectedRecordingId = value;
                      future = chartFuture();
                    });
                  },
                ),
                const SizedBox(height: 12),
                FutureBuilder<_FingerprintFeatureChartData>(
                  future: future,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2.5),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                                child: Text(
                                    'Loading cached fingerprints and building feature comparison…')),
                          ],
                        ),
                      );
                    }
                    if (snapshot.hasError || !snapshot.hasData) {
                      return SelectableText(
                          'Could not build feature chart: ${snapshot.error ?? 'Unknown error'}');
                    }
                    final data = snapshot.data!;
                    final featureColumns =
                        _tableColumnsForProfile(weightProfile, maxColumns: 7);
                    final tableRows = _tableRowsForProfile(
                        data, weightProfile, featureColumns);
                    return SizedBox(
                      height: 560,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Practice song: ${data.recordingLabel}'),
                          const SizedBox(height: 4),
                          Text(
                              'All masters compared against the selected practice song.'),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest
                                  .withOpacity(.25),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                      'Feature table sorted by lowest total weighted delta. Hover A-G to see feature names.'),
                                ),
                                TextButton.icon(
                                  onPressed: () async {
                                    await _exportFingerprintFeatureChartSnapshot(
                                        data, weightProfile);
                                  },
                                  icon: const Icon(Icons.download_outlined),
                                  label: const Text('Export snapshot'),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: ClipRect(
                              child: SingleChildScrollView(
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: DataTable(
                                    columnSpacing: 18,
                                    columns: [
                                      const DataColumn(
                                          label: Text('Master Song Name')),
                                      DataColumn(
                                          label: Tooltip(
                                              message: featureColumns
                                                      .elementAtOrNull(0) ??
                                                  'n/a',
                                              child: const Text('A'))),
                                      DataColumn(
                                          label: Tooltip(
                                              message: featureColumns
                                                      .elementAtOrNull(1) ??
                                                  'n/a',
                                              child: const Text('B'))),
                                      DataColumn(
                                          label: Tooltip(
                                              message: featureColumns
                                                      .elementAtOrNull(2) ??
                                                  'n/a',
                                              child: const Text('C'))),
                                      DataColumn(
                                          label: Tooltip(
                                              message: featureColumns
                                                      .elementAtOrNull(3) ??
                                                  'n/a',
                                              child: const Text('D'))),
                                      DataColumn(
                                          label: Tooltip(
                                              message: featureColumns
                                                      .elementAtOrNull(4) ??
                                                  'n/a',
                                              child: const Text('E'))),
                                      DataColumn(
                                          label: Tooltip(
                                              message: featureColumns
                                                      .elementAtOrNull(5) ??
                                                  'n/a',
                                              child: const Text('F'))),
                                      DataColumn(
                                          label: Tooltip(
                                              message: featureColumns
                                                      .elementAtOrNull(6) ??
                                                  'n/a',
                                              child: const Text('G'))),
                                      const DataColumn(
                                          label: Text('Confidence')),
                                      const DataColumn(
                                          label:
                                              Text('Total Delta after weight')),
                                    ],
                                    rows: [
                                      for (final row in tableRows)
                                        DataRow(cells: [
                                          DataCell(Tooltip(
                                              message: row.masterFilename,
                                              child: Text(row.masterLabel))),
                                          DataCell(Text(_percent(row
                                                  .featureDeltas
                                                  .elementAtOrNull(0) ??
                                              0))),
                                          DataCell(Text(_percent(row
                                                  .featureDeltas
                                                  .elementAtOrNull(1) ??
                                              0))),
                                          DataCell(Text(_percent(row
                                                  .featureDeltas
                                                  .elementAtOrNull(2) ??
                                              0))),
                                          DataCell(Text(_percent(row
                                                  .featureDeltas
                                                  .elementAtOrNull(3) ??
                                              0))),
                                          DataCell(Text(_percent(row
                                                  .featureDeltas
                                                  .elementAtOrNull(4) ??
                                              0))),
                                          DataCell(Text(_percent(row
                                                  .featureDeltas
                                                  .elementAtOrNull(5) ??
                                              0))),
                                          DataCell(Text(_percent(row
                                                  .featureDeltas
                                                  .elementAtOrNull(6) ??
                                              0))),
                                          DataCell(
                                              Text(_percent(row.confidence))),
                                          DataCell(Text(_percent(
                                              row.totalWeightedDelta))),
                                        ]),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Divider(height: 1),
                          const SizedBox(height: 10),
                          const Text('Weight adjusters'),
                          const SizedBox(height: 6),
                          SizedBox(
                            height: 170,
                            child: SingleChildScrollView(
                              child: Wrap(
                                spacing: 12,
                                runSpacing: 10,
                                children: [
                                  for (final entry in weightRanges.entries)
                                    SizedBox(
                                      width: 280,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                              '${entry.key}: ${(weightProfile[entry.key] ?? 0).toStringAsFixed(2)}'),
                                          Slider(
                                            min: entry.value.$1,
                                            max: entry.value.$2,
                                            divisions: 40,
                                            value:
                                                (weightProfile[entry.key] ?? 0)
                                                    .clamp(entry.value.$1,
                                                        entry.value.$2),
                                            label:
                                                (weightProfile[entry.key] ?? 0)
                                                    .toStringAsFixed(2),
                                            onChanged: (value) {
                                              setDialogState(() {
                                                weightProfile = {
                                                  ...weightProfile,
                                                  entry.key: value,
                                                };
                                              });
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () {
                  setDialogState(() {
                    weightProfile =
                        FingerprintRepository.defaultFeatureWeightProfile();
                  });
                },
                child: const Text('Reset draft')),
            TextButton(
                onPressed: () async {
                  final defaults =
                      FingerprintRepository.defaultFeatureWeightProfile();
                  setDialogState(() {
                    weightProfile = defaults;
                  });
                  await _saveFingerprintWeightProfile(defaults);
                },
                child: const Text('Reset saved')),
            TextButton(
                onPressed: () async {
                  await _applyFingerprintWeightProfile(weightProfile);
                },
                child: const Text('Apply')),
            FilledButton(
                onPressed: () async {
                  await _saveFingerprintWeightProfile(weightProfile);
                },
                child: const Text('Save profile')),
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close')),
          ],
        ),
      ),
    );
  }

  Future<_FingerprintFeatureChartData> _buildFingerprintFeatureChartData({
    required PracticeFolder practice,
    required PracticeFolder masters,
    required Recording recording,
  }) async {
    final recordingFingerprint = await _fingerprints.loadOrGenerateFingerprint(
        practice.directory, recording);
    final masterSnapshots = <_MasterFeatureSnapshot>[];
    for (final master in masters.recordings) {
      final fingerprint = await _fingerprints.loadOrGenerateFingerprint(
          masters.directory, master);
      masterSnapshots.add(_MasterFeatureSnapshot(
        recording: master,
        fingerprint: fingerprint,
      ));
    }
    const featureGroups = <String>[
      'chroma',
      'energy',
      'attack',
      'lowMotion',
      'highMotion',
      'zeroCrossing',
      'peaks',
    ];
    final masterRows = <_MasterDeltaRow>[];
    for (final snapshot in masterSnapshots) {
      final featureDeltasByGroup = <String, double>{
        for (final feature in featureGroups)
          feature: (_groupFeatureAverage(recordingFingerprint, feature) -
                  _groupFeatureAverage(snapshot.fingerprint, feature))
              .abs(),
      };
      masterRows.add(_MasterDeltaRow(
        masterLabel: _recordingSongName(snapshot.recording),
        masterFilename: snapshot.recording.filename,
        featureDeltasByGroup: featureDeltasByGroup,
      ));
    }
    return _FingerprintFeatureChartData(
      recordingLabel: _recordingDisplayName(recording),
      masterRows: masterRows,
      recordingId: recording.id,
      generatedAt: DateTime.now().toUtc(),
    );
  }

  String _recordingSongName(Recording recording) {
    final title = recording.title?.trim();
    if (title != null && title.isNotEmpty) return title;
    return path.basenameWithoutExtension(recording.filename);
  }

  List<String> _tableColumnsForProfile(
    Map<String, double> weightProfile, {
    int maxColumns = 6,
  }) {
    const featureGroups = <String>[
      'chroma',
      'energy',
      'attack',
      'lowMotion',
      'highMotion',
      'zeroCrossing',
      'peaks',
    ];
    final sorted = featureGroups
        .where((feature) => feature != 'chroma')
        .toList(growable: false)
      ..sort((a, b) {
        final byWeight = (_featureWeightForChart(b, weightProfile))
            .compareTo(_featureWeightForChart(a, weightProfile));
        return byWeight != 0 ? byWeight : a.compareTo(b);
      });
    if (maxColumns <= 0) return const <String>[];
    final columns = <String>['chroma'];
    columns.addAll(sorted.take(maxColumns - 1));
    return columns;
  }

  List<_MasterDeltaRow> _tableRowsForProfile(
    _FingerprintFeatureChartData data,
    Map<String, double> weightProfile,
    List<String> columns,
  ) {
    final rows = data.masterRows
        .map((row) => row.withComputedValues(
              columns: columns,
              weightProfile: weightProfile,
            ))
        .toList(growable: false)
      ..sort((a, b) => a.totalWeightedDelta.compareTo(b.totalWeightedDelta));
    return rows;
  }

  double _groupFeatureAverage(AudioFingerprint fingerprint, String feature) {
    if (feature == 'chroma') {
      var total = 0.0;
      var count = 0;
      for (var index = 0; index < 12; index += 1) {
        total += _featureAverage(fingerprint.features['chroma$index']);
        count += 1;
      }
      if (count == 0) return 0;
      return (total / count).clamp(0.0, 1.0).toDouble();
    }
    return _featureAverage(fingerprint.features[feature]);
  }

  String _percent(double value) => '${(value * 100).toStringAsFixed(1)}%';

  Future<void> _exportFingerprintFeatureChartSnapshot(
      _FingerprintFeatureChartData data,
      Map<String, double> weightProfile) async {
    final featureColumns =
        _tableColumnsForProfile(weightProfile, maxColumns: 7);
    final tableRows = _tableRowsForProfile(data, weightProfile, featureColumns);
    final baseName = _filenameSafe(
        'Fingerprint_${data.recordingLabel}_${DateTime.now().toIso8601String()}');
    final selectedPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export fingerprint snapshot',
      fileName: '$baseName.json',
      type: FileType.custom,
      allowedExtensions: const ['json', 'md'],
    );
    if (selectedPath == null) return;
    final output = File(selectedPath);
    await output.parent.create(recursive: true);
    final payload = <String, dynamic>{
      'recordingLabel': data.recordingLabel,
      'recordingId': data.recordingId,
      'generatedAt': data.generatedAt.toIso8601String(),
      'featureColumns': featureColumns,
      'weightProfile': weightProfile,
      'masterRows':
          tableRows.map((row) => row.toJson()).toList(growable: false),
    };
    final ext = path.extension(output.path).toLowerCase();
    if (ext == '.md') {
      await output.writeAsString(_fingerprintSnapshotMarkdown(payload),
          flush: true);
    } else {
      await output.writeAsString(
          const JsonEncoder.withIndent('  ').convert(payload),
          flush: true);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Exported fingerprint snapshot to ${path.basename(output.path)}')));
    }
  }

  String _fingerprintSnapshotMarkdown(Map<String, dynamic> payload) {
    final buffer = StringBuffer()
      ..writeln('# Fingerprint Snapshot')
      ..writeln()
      ..writeln('- Recording: ${payload['recordingLabel']}')
      ..writeln('- Generated: ${payload['generatedAt']}')
      ..writeln();
    final columns = (payload['featureColumns'] as List<dynamic>).cast<String>();
    final masterRows =
        (payload['masterRows'] as List<dynamic>).cast<Map<String, dynamic>>();
    buffer
      ..writeln('## Master Comparison Table')
      ..writeln()
      ..writeln(
          '| Master Song Name | A (${columns.elementAtOrNull(0) ?? 'n/a'}) | B (${columns.elementAtOrNull(1) ?? 'n/a'}) | C (${columns.elementAtOrNull(2) ?? 'n/a'}) | D (${columns.elementAtOrNull(3) ?? 'n/a'}) | E (${columns.elementAtOrNull(4) ?? 'n/a'}) | F (${columns.elementAtOrNull(5) ?? 'n/a'}) | G (${columns.elementAtOrNull(6) ?? 'n/a'}) | Confidence | Total Delta after weight |')
      ..writeln('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|');
    for (final row in masterRows) {
      final deltas = (row['featureDeltas'] as List<dynamic>)
          .map((item) => (item as num).toDouble())
          .toList(growable: false);
      buffer.writeln(
          '| ${row['masterLabel']} | ${_percent(deltas.elementAtOrNull(0) ?? 0)} | ${_percent(deltas.elementAtOrNull(1) ?? 0)} | ${_percent(deltas.elementAtOrNull(2) ?? 0)} | ${_percent(deltas.elementAtOrNull(3) ?? 0)} | ${_percent(deltas.elementAtOrNull(4) ?? 0)} | ${_percent(deltas.elementAtOrNull(5) ?? 0)} | ${_percent(deltas.elementAtOrNull(6) ?? 0)} | ${_percent((row['confidence'] as num?)?.toDouble() ?? 0)} | ${_percent((row['totalWeightedDelta'] as num).toDouble())} |');
    }
    return buffer.toString();
  }

  double _featureWeightForChart(String feature, Map<String, double> profile) {
    if (feature.startsWith('chroma')) return profile['chroma'] ?? 0;
    return profile[feature] ?? 0;
  }

  double _featureAverage(List<double>? values) {
    if (values == null || values.isEmpty) return 0;
    var total = 0.0;
    for (final value in values) {
      total += value;
    }
    return (total / values.length).clamp(0.0, 1.0).toDouble();
  }

  Future<String> _buildFingerprintEvaluationReport(
    PracticeFolder practice,
    Directory mastersFolder,
  ) async {
    final corrections = await _fingerprintCorrections.load(mastersFolder.path);
    final evaluationData =
        await _activity.run('Refreshing evaluation data', (update) async {
      update(null, 'Running a fresh fingerprint match for evaluation…');
      final freshMatches = await _fingerprints.matchPracticeInBackground(
        practicePath: practice.directory.path,
        mastersPath: mastersFolder.path,
        weightProfile: _fingerprints.featureWeightProfile(),
        actionableOnly: false,
      );
      update(.75, 'Loading current fingerprint review decisions…');
      final decisions =
          await _fingerprintDecisions.load(practice.directory.path);
      update(1, 'Evaluation data refreshed');
      return (matches: freshMatches, decisions: decisions);
    });
    if (mounted) {
      final visibleMatches = _visibleFingerprintMatches(
        practice,
        evaluationData.matches,
        evaluationData.decisions,
      );
      setState(() {
        _fingerprintRawMatches = evaluationData.matches;
        _fingerprintMatches = visibleMatches;
        _fingerprintDecisionState = evaluationData.decisions;
      });
    }
    await _fingerprintSuggestions.save(
        practice.directory.path, evaluationData.matches);
    final report = FingerprintEvaluation.evaluate(
      appVersion: _appVersionLabel(),
      practiceName: practice.name,
      practicePath: practice.directory.path,
      mastersPath: mastersFolder.path,
      corrections: corrections,
      matches: evaluationData.matches,
      acceptedDecisions: evaluationData.decisions.accepted,
    );
    final reportText = report.toText();
    final tuningAppendix = _buildFingerprintEvaluationTuningAppendix(
      corrections: corrections,
      matches: evaluationData.matches,
      acceptedDecisions: evaluationData.decisions.accepted,
      weightProfile: _fingerprints.featureWeightProfile(),
    );
    return '$reportText\n\n$tuningAppendix';
  }

  String _buildFingerprintEvaluationTuningAppendix({
    required List<FingerprintCorrection> corrections,
    required List<FingerprintMatch> matches,
    required List<FingerprintDecision> acceptedDecisions,
    required Map<String, double> weightProfile,
  }) {
    final latestCorrections = <String, FingerprintCorrection>{};
    for (final correction in corrections) {
      final existing = latestCorrections[correction.recordingId];
      if (existing == null ||
          correction.recordedAt.isAfter(existing.recordedAt)) {
        latestCorrections[correction.recordingId] = correction;
      }
    }
    final matchesByRecording = <String, List<FingerprintMatch>>{};
    for (final match in matches) {
      matchesByRecording.putIfAbsent(
          match.recordingId, () => <FingerprintMatch>[])
        ..add(match);
    }
    for (final recordingMatches in matchesByRecording.values) {
      recordingMatches.sort((a, b) => b.confidence.compareTo(a.confidence));
    }
    final acceptedByRecording = <String, FingerprintDecision>{
      for (final item in acceptedDecisions) item.recordingId: item,
    };

    final rows = latestCorrections.values.toList()
      ..sort((a, b) => a.recordingFilename.compareTo(b.recordingFilename));

    final buffer = StringBuffer()
      ..writeln('Tuning diagnostics')
      ..writeln('  Active weight profile: $weightProfile')
      ..writeln('  Evaluated corrections: ${rows.length}')
      ..writeln(
          '  Accepted decisions at eval time: ${acceptedDecisions.length}')
      ..writeln(
          '  Historical tuner scoring ignores accepted decisions and scores raw matcher output only.')
      ..writeln('')
      ..writeln('Per-recording candidate diagnostics');

    for (final correction in rows) {
      final recordingMatches = matchesByRecording[correction.recordingId] ??
          const <FingerprintMatch>[];
      final accepted = acceptedByRecording[correction.recordingId];
      final expected = _expectedDisplayForCorrection(correction);
      buffer
        ..writeln('- ${correction.recordingFilename}')
        ..writeln('    expected: $expected')
        ..writeln('    corrected-as: ${correction.correctType}')
        ..writeln('    candidateCount: ${recordingMatches.length}')
        ..writeln(
            '    acceptedDecision: ${accepted == null ? 'none' : '${accepted.displayName} (${(accepted.confidence * 100).toStringAsFixed(1)}%)'}');

      if (recordingMatches.isEmpty) {
        buffer.writeln('    topCandidates: none');
        continue;
      }

      final topCandidates = recordingMatches.take(2).toList(growable: false);
      for (var index = 0; index < topCandidates.length; index += 1) {
        final candidate = topCandidates[index];
        buffer
          ..writeln('    #${index + 1}: ${candidate.displayName}')
          ..writeln('      score: ${candidate.scoreDetails}')
          ..writeln(
              '      gate: ${_fingerprints.actionabilitySummary(candidate)}')
          ..writeln(
              '      groupDeltas: ${_featureGroupDeltaSummary(candidate)}')
          ..writeln(
              '      featureScores: ${_compactFeatureScores(candidate.featureScores)}');
      }
    }

    return buffer.toString();
  }

  String _expectedDisplayForCorrection(FingerprintCorrection correction) {
    final expectsNoMaster = correction.correctType == 'new' ||
        correction.correctType == 'jam' ||
        correction.correctType == 'unknown';
    if (expectsNoMaster) return correction.correctType;
    final song = correction.correctMasterTitle ??
        correction.correctMasterFilename ??
        correction.correctMasterRecordingId ??
        'unknown master';
    final section = correction.correctSectionLabel?.trim();
    if (section == null || section.isEmpty) return song;
    return '$song / $section';
  }

  String _compactFeatureScores(Map<String, double> featureScores) {
    if (featureScores.isEmpty) return 'none';
    final keys = featureScores.keys.toList(growable: false)..sort();
    final parts = <String>[];
    for (final key in keys) {
      final value = featureScores[key] ?? 0;
      parts.add('$key ${(value * 100).toStringAsFixed(1)}%');
    }
    return parts.join(', ');
  }

  Future<void> _reEvaluateFingerprintWeightsFromHistory() async {
    final mastersFolder = await _requireMastersFolder();
    if (mastersFolder == null) return;
    try {
      final outcome = await _activity.run('Re-evaluating fingerprint tuning',
          (update) async {
        final startedAt = DateTime.now();
        update(0, 'Loading correction history…');
        final corrections =
            await _fingerprintCorrections.load(mastersFolder.path);
        if (corrections.isEmpty) {
          throw StateError(
              'No fingerprint corrections were found. Use Teach correct match first, then re-evaluate tuning.');
        }

        final byPractice = <String, List<FingerprintCorrection>>{};
        for (final correction in corrections) {
          final practicePath = correction.practicePath;
          if (practicePath == null || practicePath.trim().isEmpty) continue;
          byPractice
              .putIfAbsent(practicePath, () => <FingerprintCorrection>[])
              .add(correction);
        }
        if (byPractice.isEmpty) {
          throw StateError(
              'Corrections are missing practice paths, so historical re-evaluation cannot run yet.');
        }

        final practiceInputs = <_TuningPracticeInput>[];
        final practiceEntries = byPractice.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        for (final entry in practiceEntries) {
          final pathValue = entry.key;
          final directory = Directory(pathValue);
          if (!await directory.exists()) {
            _log.warning('fingerprint-tune',
                'Skipping missing practice path in corrections: $pathValue');
            continue;
          }
          final decisions = await _fingerprintDecisions.load(pathValue);
          final latestByRecording = <String, FingerprintCorrection>{};
          for (final correction in entry.value) {
            final existing = latestByRecording[correction.recordingId];
            if (existing == null ||
                correction.recordedAt.isAfter(existing.recordedAt)) {
              latestByRecording[correction.recordingId] = correction;
            }
          }
          final practiceName = entry.value
                  .map((item) => item.practiceName)
                  .whereType<String>()
                  .where((value) => value.trim().isNotEmpty)
                  .lastOrNull ??
              directory.uri.pathSegments
                  .where((segment) => segment.trim().isNotEmpty)
                  .lastOrNull ??
              path.basename(pathValue);
          practiceInputs.add(_TuningPracticeInput(
            practicePath: pathValue,
            practiceName: practiceName,
            acceptedDecisions: decisions.accepted,
            correctionCount: latestByRecording.length,
          ));
        }
        if (practiceInputs.isEmpty) {
          throw StateError(
              'No correction practice folders exist on disk anymore, so re-evaluation cannot run.');
        }

        final currentProfile = _currentFingerprintWeightProfile();
        final candidates =
            _candidateProfilesForHistoricalTuning(currentProfile);
        _log.info('fingerprint-tune',
            'Starting historical tuning: practices=${practiceInputs.length}, candidates=${candidates.length}, masters=${mastersFolder.path}');

        final totalSteps = candidates.length * practiceInputs.length;
        var completedSteps = 0;
        final summaries = <_ProfileEvaluationSummary>[];

        for (final candidate in candidates) {
          final reports = <String, FingerprintEvaluationReport>{};
          for (final practice in practiceInputs) {
            completedSteps += 1;
            final progress = totalSteps == 0
                ? 1.0
                : (completedSteps / totalSteps).clamp(0.0, 1.0);
            update(progress,
                'Evaluating ${candidate.label} on ${practice.practiceName} ($completedSteps/$totalSteps)…');
            final matches = await _fingerprints.matchPracticeInBackground(
              practicePath: practice.practicePath,
              mastersPath: mastersFolder.path,
              actionableOnly: false,
              weightProfile: candidate.profile,
            );
            final report = FingerprintEvaluation.evaluate(
              appVersion: _appVersionLabel(),
              practiceName: practice.practiceName,
              practicePath: practice.practicePath,
              mastersPath: mastersFolder.path,
              corrections: corrections,
              matches: matches,
              acceptedDecisions: const <FingerprintDecision>[],
            );
            reports[practice.practicePath] = report;
          }
          final summary = _summarizeProfileEvaluation(candidate, reports);
          _log.info('fingerprint-tune', summary.logLine());
          summaries.add(summary);
        }

        final baseline = summaries
            .where((summary) => summary.profile.label == 'Current profile')
            .firstOrNull;
        if (baseline == null) {
          throw StateError('Could not compute baseline for current profile.');
        }

        final noRegression = summaries
            .where((summary) =>
                !_isRegressionComparedToBaseline(summary, baseline))
            .toList(growable: false);
        final ranked = (noRegression.isEmpty ? summaries : noRegression)
          ..sort((a, b) {
            final byScore = b.score.compareTo(a.score);
            if (byScore != 0) return byScore;
            final bySong = b.songAccuracy.compareTo(a.songAccuracy);
            if (bySong != 0) return bySong;
            return b.exactAccuracy.compareTo(a.exactAccuracy);
          });
        final recommended = ranked.first;
        final elapsed = DateTime.now().difference(startedAt);
        _log.info('fingerprint-tune',
            'Re-evaluation complete in ${elapsed.inSeconds}s. Recommended=${recommended.profile.label}; score=${recommended.score.toStringAsFixed(2)}; songAcc=${(recommended.songAccuracy * 100).toStringAsFixed(1)}%; exact=${(recommended.exactAccuracy * 100).toStringAsFixed(1)}%');
        update(1, 'Re-evaluation complete');
        return _FingerprintTuningOutcome(
          generatedAt: DateTime.now().toUtc(),
          baseline: baseline,
          recommended: recommended,
          allSummaries: summaries,
          noRegressionCount: noRegression.length,
        );
      });

      if (!mounted) return;
      await _showFingerprintTuningOutcomeDialog(outcome);
    } on ProcessException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'FFmpeg is required for historical fingerprint re-evaluation.')));
      }
    } on StateError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  List<_NamedWeightProfile> _candidateProfilesForHistoricalTuning(
      Map<String, double> currentProfile) {
    final defaults = FingerprintRepository.defaultFeatureWeightProfile();
    const ranges = <String, (double, double)>{
      'chroma': (0.0, 0.25),
      'energy': (0.0, 2.0),
      'attack': (0.0, 2.0),
      'lowMotion': (0.0, 2.0),
      'highMotion': (0.0, 2.0),
      'zeroCrossing': (0.0, 2.0),
      'peaks': (0.0, 1.0),
    };

    Map<String, double> normalize(Map<String, double> profile) {
      final next = <String, double>{};
      for (final entry in defaults.entries) {
        final range = ranges[entry.key] ?? (0.0, 2.5);
        final value = profile[entry.key] ?? entry.value;
        next[entry.key] = value.clamp(range.$1, range.$2).toDouble();
      }
      return next;
    }

    String keyFor(Map<String, double> profile) {
      final keys = profile.keys.toList(growable: false)..sort();
      return keys
          .map((key) => '$key=${(profile[key] ?? 0).toStringAsFixed(4)}')
          .join('|');
    }

    final output = <_NamedWeightProfile>[];
    final seen = <String>{};
    void add(String label, Map<String, double> profile) {
      final normalized = normalize(profile);
      final signature = keyFor(normalized);
      if (!seen.add(signature)) return;
      output.add(_NamedWeightProfile(label: label, profile: normalized));
    }

    add('Current profile', currentProfile);
    add('Default profile', defaults);

    for (final entry in defaults.entries) {
      final key = entry.key;
      final step = switch (key) {
        'chroma' => 0.02,
        'peaks' => 0.05,
        _ => 0.15,
      };

      add('$key +1 step (from current)', {
        ...currentProfile,
        key: (currentProfile[key] ?? entry.value) + step,
      });
      add('$key -1 step (from current)', {
        ...currentProfile,
        key: (currentProfile[key] ?? entry.value) - step,
      });
      add('$key +1 step (from default)', {
        ...defaults,
        key: entry.value + step,
      });
      add('$key -1 step (from default)', {
        ...defaults,
        key: entry.value - step,
      });
    }

    return output;
  }

  _ProfileEvaluationSummary _summarizeProfileEvaluation(
    _NamedWeightProfile profile,
    Map<String, FingerprintEvaluationReport> reports,
  ) {
    var total = 0;
    var exact = 0;
    var songCorrect = 0;
    var wrong = 0;
    var notSuggested = 0;
    var missed = 0;
    var falsePositiveActionable = 0;
    var falsePositiveNonActionable = 0;

    for (final report in reports.values) {
      total += report.total;
      exact += report.exactCorrect;
      songCorrect += report.songCorrect;
      wrong += report.wrong;
      notSuggested += report.notSuggested;
      missed += report.missed;
      falsePositiveActionable += report.falsePositiveActionable;
      falsePositiveNonActionable += report.falsePositiveNonActionable;
    }

    final useful = exact + songCorrect;
    final songAccuracy = total == 0 ? 0.0 : useful / total;
    final exactAccuracy = total == 0 ? 0.0 : exact / total;
    final score = (exact * 4.0) +
        (songCorrect * 2.5) -
        (wrong * 6.0) -
        (notSuggested * 3.0) -
        (missed * 3.5) -
        (falsePositiveActionable * 4.0) -
        (falsePositiveNonActionable * 1.8);

    return _ProfileEvaluationSummary(
      profile: profile,
      reportsByPractice: reports,
      total: total,
      exact: exact,
      songCorrect: songCorrect,
      wrong: wrong,
      notSuggested: notSuggested,
      missed: missed,
      falsePositiveActionable: falsePositiveActionable,
      falsePositiveNonActionable: falsePositiveNonActionable,
      songAccuracy: songAccuracy,
      exactAccuracy: exactAccuracy,
      score: score,
    );
  }

  bool _isRegressionComparedToBaseline(
    _ProfileEvaluationSummary candidate,
    _ProfileEvaluationSummary baseline,
  ) {
    if (candidate.songAccuracy + 1e-9 < baseline.songAccuracy) return true;
    if (candidate.wrong > baseline.wrong) return true;
    if (candidate.falsePositiveActionable > baseline.falsePositiveActionable) {
      return true;
    }
    return false;
  }

  Future<void> _showFingerprintTuningOutcomeDialog(
      _FingerprintTuningOutcome outcome) async {
    final reportText = _fingerprintTuningOutcomeText(outcome);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Fingerprint tuning re-evaluation'),
        content: SizedBox(
          width: 820,
          height: 520,
          child: SingleChildScrollView(
            child: SelectableText(reportText),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: reportText));
              if (context.mounted) Navigator.pop(context);
              if (mounted) {
                ScaffoldMessenger.of(this.context).showSnackBar(
                    const SnackBar(content: Text('Tuning report copied')));
              }
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy report'),
          ),
          TextButton(
            onPressed: () async {
              await _applyFingerprintWeightProfile(
                  outcome.recommended.profile.profile);
            },
            child: const Text('Apply recommendation'),
          ),
          FilledButton(
            onPressed: () async {
              await _saveFingerprintWeightProfile(
                  outcome.recommended.profile.profile);
            },
            child: const Text('Save recommendation'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  String _fingerprintTuningOutcomeText(_FingerprintTuningOutcome outcome) {
    final baseline = outcome.baseline;
    final recommended = outcome.recommended;
    final top = outcome.allSummaries.toList(growable: false)
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        return b.songAccuracy.compareTo(a.songAccuracy);
      });
    final buffer = StringBuffer()
      ..writeln('RiffNotes fingerprint tuning re-evaluation')
      ..writeln('Generated: ${outcome.generatedAt.toIso8601String()}')
      ..writeln('Candidate profiles evaluated: ${outcome.allSummaries.length}')
      ..writeln('No-regression candidates: ${outcome.noRegressionCount}')
      ..writeln('')
      ..writeln('Recommended profile')
      ..writeln('  Label: ${recommended.profile.label}')
      ..writeln('  Weights: ${recommended.profile.profile}')
      ..writeln(
          '  Score: ${recommended.score.toStringAsFixed(2)} | songAcc ${_percent(recommended.songAccuracy)} | exact ${_percent(recommended.exactAccuracy)}')
      ..writeln('')
      ..writeln('Baseline profile')
      ..writeln('  Label: ${baseline.profile.label}')
      ..writeln('  Weights: ${baseline.profile.profile}')
      ..writeln(
          '  Score: ${baseline.score.toStringAsFixed(2)} | songAcc ${_percent(baseline.songAccuracy)} | exact ${_percent(baseline.exactAccuracy)}')
      ..writeln('')
      ..writeln('Top profiles');

    for (final summary in top.take(8)) {
      buffer.writeln(
          '  - ${summary.profile.label}: score ${summary.score.toStringAsFixed(2)} | songAcc ${_percent(summary.songAccuracy)} | exact ${_percent(summary.exactAccuracy)} | wrong ${summary.wrong} | notSuggested ${summary.notSuggested} | missed ${summary.missed} | fpA ${summary.falsePositiveActionable} | fpN ${summary.falsePositiveNonActionable}');
    }
    return buffer.toString();
  }

  List<FingerprintMatch> _visibleFingerprintMatches(
    PracticeFolder practice,
    List<FingerprintMatch> suggestions,
    FingerprintDecisions decisions,
  ) {
    final jamRecordingIds = practice.recordings
        .where(_isJamRecording)
        .map((recording) => recording.id)
        .toSet();
    final eligible = suggestions
        .where((match) => !jamRecordingIds.contains(match.recordingId))
        .where((match) => !decisions.ignoredKeys.contains(match.key))
        .where((match) => decisions.accepted
            .every((item) => item.recordingId != match.recordingId))
        .toList(growable: false);
    final byRecording = <String, List<FingerprintMatch>>{};
    for (final match in eligible) {
      byRecording.putIfAbsent(match.recordingId, () => <FingerprintMatch>[])
        ..add(match);
    }

    final visible = <FingerprintMatch>[];
    for (final entry in byRecording.entries) {
      final candidates = entry.value.toList(growable: true)
        ..sort((a, b) => b.confidence.compareTo(a.confidence));
      final actionable = candidates
          .where(_fingerprints.isActionableSuggestion)
          .toList(growable: false);
      if (actionable.isNotEmpty) {
        visible.addAll(actionable);
        continue;
      }

      final best = candidates.firstOrNull;
      if (best == null) continue;
      final includeFallback = switch (best.targetType) {
        FingerprintTargetType.song =>
          best.confidence >= .80 && (best.rawConfidence ?? 0) >= .84,
        FingerprintTargetType.section =>
          best.confidence >= .80 && (best.songConfidence ?? 0) >= .74,
      };
      if (includeFallback) {
        visible.add(best);
      }
    }
    return visible;
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
    await _applyMasterSectionsForAcceptedMatch(recording, match);
    await _fingerprintDecisions.accept(practice.directory.path, match);
    final mastersFolder = _resolvedMastersFolder;
    if (mastersFolder != null) {
      await _fingerprintLearning.recordAccepted(mastersFolder.path, match);
    }
    final decisions = await _fingerprintDecisions.load(practice.directory.path);
    if (mounted) {
      setState(() {
        _fingerprintDecisionState = decisions;
        _fingerprintRawMatches = _fingerprintRawMatches
            .where((item) => item.recordingId != match.recordingId)
            .toList(growable: false);
        _fingerprintMatches = _fingerprintMatches
            .where((item) => item.recordingId != match.recordingId)
            .toList(growable: false);
      });
    }
    await _fingerprintSuggestions.save(
        practice.directory.path, _fingerprintRawMatches);
  }

  Future<void> _acceptBestFingerprintGuessForRecording(
      Recording recording) async {
    final match = _fingerprintRawMatches
        .where((item) => item.recordingId == recording.id)
        .toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    if (match.isEmpty) return;
    await _acceptFingerprintMatch(recording, match.first);
  }

  Future<void> _dontKnowFingerprintForRecording(Recording recording) async {
    final matches = _fingerprintRawMatches
        .where((item) => item.recordingId == recording.id)
        .toList(growable: false);
    for (final match in matches) {
      await _ignoreFingerprintMatch(match);
    }
  }

  Future<void> _showFingerprintInfoForRecording(Recording recording) async {
    final matches = _fingerprintMatches
        .where((item) => item.recordingId == recording.id)
        .toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    final report = _fingerprintDebugReport(recording, matches);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title:
            Text('Fingerprint info: ${recording.title ?? recording.filename}'),
        content: SizedBox(
          width: 720,
          child: matches.isEmpty
              ? Text(_isJamRecording(recording)
                  ? 'This take is titled Jam, so it is intentionally skipped by fingerprint matching.'
                  : 'No pending fingerprint suggestions are available for this take. Run fingerprint matching, or clear generated cache if you need to force a full re-run. Use Copy report if this seems wrong.')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                        'These details are useful when tuning the algorithm. Matching is two-stage: first whole-song candidates, then sections from likely songs. Confidence is the final score; raw is before learning adjustments; margin is the gap to the next candidate.'),
                    const SizedBox(height: 12),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: matches.length,
                        itemBuilder: (context, index) {
                          final match = matches[index];
                          return Card(
                            child: ListTile(
                              leading: Text('#${index + 1}'),
                              title: Text(match.displayName),
                              subtitle: SelectableText(match.diagnosticDetails),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
        ),
        actions: [
          TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: report));
                if (context.mounted) Navigator.pop(context);
                if (mounted) {
                  ScaffoldMessenger.of(this.context).showSnackBar(
                      const SnackBar(
                          content: Text('Fingerprint report copied')));
                }
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy report')),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _teachFingerprintCorrectionForRecording(
      Recording recording) async {
    final practice = _selected;
    if (practice == null) return;
    final masters =
        _mastersPractice ?? await _loadMastersPractice(create: true);
    final mastersFolder = _resolvedMastersFolder;
    if (masters == null || mastersFolder == null) return;
    final matches = _fingerprintMatches
        .where((item) => item.recordingId == recording.id)
        .toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    final sectionMap = <String, List<SongSection>>{};
    for (final master in masters.recordings) {
      sectionMap[master.id] =
          await _sectionsRepository.load(masters.directory.path, master.id);
    }
    final notes = TextEditingController();
    final songTitleController = TextEditingController(
        text: _preferences
                .fingerprintSongTitlesForPractice(practice.directory.path)
                .firstOrNull ??
            '');
    var correctType = 'whole';
    String? selectedMasterId =
        masters.recordings.isEmpty ? null : masters.recordings.first.id;
    String? selectedSectionLabel;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final needsMaster = correctType == 'whole' ||
              correctType == 'partial' ||
              correctType == 'section';
          final masterDropdownValue = needsMaster ? selectedMasterId : null;
          final selectedMaster = masters.recordings
              .where((item) => item.id == masterDropdownValue)
              .firstOrNull;
          final sections = masterDropdownValue == null
              ? const <SongSection>[]
              : sectionMap[masterDropdownValue] ?? const <SongSection>[];
          final recentSongTitles = <String>{
            ...masters.recordings
                .map((item) => item.title?.trim())
                .whereType<String>()
                .where((item) => item.isNotEmpty),
            ..._preferences
                .fingerprintSongTitlesForPractice(practice.directory.path),
          }.toList(growable: false)
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
          return AlertDialog(
            title: Text(
                'Teach fingerprint: ${recording.title ?? recording.filename}'),
            content: SizedBox(
              width: 720,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      matches.isEmpty
                          ? 'No guess is pending for this take. Tell RiffNotes what it should have known.'
                          : 'Current best guess: ${matches.first.displayName} (${matches.first.scoreDetails})',
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: correctType,
                      decoration:
                          const InputDecoration(labelText: 'Actual result'),
                      items: const [
                        DropdownMenuItem(
                            value: 'whole', child: Text('Whole song')),
                        DropdownMenuItem(
                            value: 'partial', child: Text('Partial song')),
                        DropdownMenuItem(
                            value: 'section', child: Text('Specific section')),
                        DropdownMenuItem(
                            value: 'new',
                            child: Text('New song / not in Masters')),
                        DropdownMenuItem(
                            value: 'jam',
                            child: Text('Jam / ignore fingerprinting')),
                        DropdownMenuItem(
                            value: 'unknown', child: Text('Unknown right now')),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setDialogState(() {
                          correctType = value;
                          final nowNeedsMaster = correctType == 'whole' ||
                              correctType == 'partial' ||
                              correctType == 'section';
                          if (!nowNeedsMaster) {
                            selectedMasterId = null;
                            selectedSectionLabel = null;
                          } else {
                            selectedMasterId ??= masters.recordings.isEmpty
                                ? null
                                : masters.recordings.first.id;
                          }
                          if (correctType != 'section') {
                            selectedSectionLabel = null;
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: masterDropdownValue,
                      decoration: const InputDecoration(
                          labelText: 'Correct master song'),
                      items: [
                        for (final master in masters.recordings)
                          DropdownMenuItem(
                            value: master.id,
                            child: Text(master.title ?? master.filename),
                          ),
                      ],
                      onChanged: needsMaster
                          ? (value) => setDialogState(() {
                                selectedMasterId = value;
                                selectedSectionLabel = null;
                              })
                          : null,
                    ),
                    const SizedBox(height: 12),
                    if (correctType == 'new') ...[
                      DropdownButtonFormField<String>(
                        value: songTitleController.text.trim().isEmpty
                            ? null
                            : songTitleController.text.trim(),
                        decoration: const InputDecoration(
                            labelText: 'Quick select remembered title'),
                        items: [
                          for (final title in recentSongTitles)
                            DropdownMenuItem(
                              value: title,
                              child: Text(title),
                            ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setDialogState(() {
                            songTitleController.text = value;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: songTitleController,
                        decoration: const InputDecoration(
                          labelText: 'New song title',
                          hintText:
                              'Type the song name here and RiffNotes will remember it for this practice.',
                        ),
                        onChanged: (_) => setDialogState(() {}),
                      ),
                      const SizedBox(height: 12),
                    ],
                    DropdownButtonFormField<String?>(
                      value: selectedSectionLabel,
                      decoration:
                          const InputDecoration(labelText: 'Correct section'),
                      items: [
                        const DropdownMenuItem<String?>(
                            value: null, child: Text('No specific section')),
                        for (final section in sections)
                          DropdownMenuItem<String?>(
                            value: section.label,
                            child: Text(section.label),
                          ),
                      ],
                      onChanged: correctType == 'section'
                          ? (value) =>
                              setDialogState(() => selectedSectionLabel = value)
                          : null,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: notes,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Notes for Codex / tuning',
                        hintText:
                            'Example: should be chorus of The Song, starts around 1:10, guessed the wrong song.',
                      ),
                    ),
                    if (needsMaster && masters.recordings.isEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        'No master recordings are available yet.',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ],
                    if (correctType == 'new' &&
                        songTitleController.text.trim().isEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Enter a title so it can be remembered for this practice.',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: (needsMaster && selectedMaster == null) ||
                        (correctType == 'new' &&
                            songTitleController.text.trim().isEmpty)
                    ? null
                    : () => Navigator.pop(context, true),
                child: const Text('Save + copy report'),
              ),
            ],
          );
        },
      ),
    );
    if (saved != true) {
      notes.dispose();
      return;
    }
    final needsMaster = correctType == 'whole' ||
        correctType == 'partial' ||
        correctType == 'section';
    final newSongTitle = correctType == 'new'
        ? _sanitizeRememberedTitle(songTitleController.text)
        : null;
    final selectedMaster = masters.recordings
        .where((item) => needsMaster && item.id == selectedMasterId)
        .firstOrNull;
    final report = _fingerprintCorrectionReport(
      recording: recording,
      matches: matches,
      correctType: correctType,
      correctMaster: selectedMaster,
      correctSectionLabel: selectedSectionLabel,
      newSongTitle: newSongTitle,
      notes: notes.text.trim(),
    );
    await _fingerprintCorrections.add(
      mastersFolder.path,
      FingerprintCorrection(
        recordingId: recording.id,
        recordingFilename: recording.filename,
        recordingTitle: recording.title,
        practiceName: practice.name,
        practicePath: practice.directory.path,
        correctType: correctType,
        correctMasterRecordingId: selectedMaster?.id,
        correctMasterFilename: selectedMaster?.filename,
        correctMasterTitle: selectedMaster?.title,
        correctSectionLabel: selectedSectionLabel,
        notes: notes.text.trim(),
        report: report,
        recordedAt: DateTime.now().toUtc(),
      ),
    );
    await _clearFingerprintGuessForRecording(recording.id);
    if (newSongTitle != null) {
      await _updateRecording(
        recording,
        title: newSongTitle,
        isBestTake: recording.isBestTake,
      );
      await _preferences.rememberFingerprintSongTitle(
          practice.directory.path, newSongTitle);
    }
    if (needsMaster && selectedMaster != null) {
      final syntheticMatch = FingerprintMatch(
        recordingId: recording.id,
        recordingFilename: recording.filename,
        masterRecordingId: selectedMaster.id,
        masterFilename: selectedMaster.filename,
        masterTitle: selectedMaster.title,
        sectionLabel: selectedSectionLabel,
        confidence: 1,
      );
      await _fingerprintLearning.recordAccepted(
          mastersFolder.path, syntheticMatch);
      final wrongBest = matches.firstOrNull;
      if (wrongBest != null && wrongBest.key != syntheticMatch.key) {
        await _fingerprintLearning.recordIgnored(mastersFolder.path, wrongBest);
      }
    } else {
      for (final match in matches) {
        await _fingerprintLearning.recordIgnored(mastersFolder.path, match);
      }
    }
    await Clipboard.setData(ClipboardData(text: report));
    notes.dispose();
    songTitleController.dispose();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Correction saved and report copied')));
    }
  }

  String _fingerprintDebugReport(
      Recording recording, List<FingerprintMatch> matches) {
    final practice = _selected;
    final buffer = StringBuffer()
      ..writeln('RiffNotes fingerprint debug report')
      ..writeln('Generated: ${DateTime.now().toIso8601String()}')
      ..writeln('App: ${_appVersionLabel()}')
      ..writeln('Practice: ${practice?.name ?? 'none'}')
      ..writeln('Practice path: ${practice?.directory.path ?? 'none'}')
      ..writeln('Masters path: ${_resolvedMastersFolder?.path ?? 'none'}')
      ..writeln('Recording id: ${recording.id}')
      ..writeln('Recording file: ${recording.filename}')
      ..writeln('Recording title: ${recording.title ?? 'none'}')
      ..writeln('Jam excluded: ${_isJamRecording(recording)}')
      ..writeln('Pending visible matches for take: ${matches.length}')
      ..writeln(
          'Accepted decisions in practice: ${_fingerprintDecisionState.accepted.length}')
      ..writeln(
          'Ignored decisions in practice: ${_fingerprintDecisionState.ignoredKeys.length}')
      ..writeln('');
    if (matches.isEmpty) {
      buffer
        ..writeln('No visible matches are pending for this recording.')
        ..writeln(
            'If matching was just run and this should have matched, clear generated cache from Preferences and re-run matching, then copy this report again.');
      return buffer.toString();
    }
    for (var index = 0; index < matches.length; index += 1) {
      final match = matches[index];
      buffer
        ..writeln('Candidate ${index + 1}')
        ..writeln('  Display: ${match.displayName}')
        ..writeln('  Type: ${match.targetType.name}')
        ..writeln('  Master id: ${match.masterRecordingId}')
        ..writeln('  Master file: ${match.masterFilename}')
        ..writeln('  Master title: ${match.masterTitle ?? 'none'}')
        ..writeln('  Section: ${match.sectionLabel ?? 'whole song'}')
        ..writeln('  Score: ${match.scoreDetails}')
        ..writeln('  Key: ${match.key}');
      if (match.featureScores.isNotEmpty) {
        final featureEntries = match.featureScores.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        buffer.writeln('  Feature scores:');
        for (final entry in featureEntries) {
          buffer.writeln(
              '    ${entry.key}: ${(entry.value * 100).toStringAsFixed(1)}%');
        }
      }
      buffer.writeln('');
    }
    return buffer.toString();
  }

  String _fingerprintCorrectionReport({
    required Recording recording,
    required List<FingerprintMatch> matches,
    required String correctType,
    required Recording? correctMaster,
    required String? correctSectionLabel,
    required String? newSongTitle,
    required String notes,
  }) {
    final buffer = StringBuffer()
      ..writeln('RiffNotes fingerprint correction report')
      ..writeln('')
      ..writeln('Ground truth')
      ..writeln('  Actual result: $correctType')
      ..writeln(
          '  Correct master: ${correctMaster == null ? 'none' : '${correctMaster.title ?? correctMaster.filename} (${correctMaster.filename})'}')
      ..writeln('  Correct master id: ${correctMaster?.id ?? 'none'}')
      ..writeln('  Correct section: ${correctSectionLabel ?? 'none'}')
      ..writeln('  New song title: ${newSongTitle ?? 'none'}')
      ..writeln('  Notes: ${notes.isEmpty ? 'none' : notes}')
      ..writeln('')
      ..write(_fingerprintDebugReport(recording, matches));
    return buffer.toString();
  }

  String? _sanitizeRememberedTitle(String value) {
    final cleaned = value.trim();
    return cleaned.isEmpty ? null : cleaned;
  }

  Future<void> _applyMasterSectionsForAcceptedMatch(
      Recording recording, FingerprintMatch match) async {
    final practice = _selected;
    if (practice == null) return;
    final masters = _mastersPractice ?? await _loadMastersPractice();
    if (masters == null) return;
    final masterRecording = masters.recordings
        .where((item) => item.id == match.masterRecordingId)
        .firstOrNull;
    if (masterRecording == null) return;
    final masterSections = await _sectionsRepository.load(
        masters.directory.path, match.masterRecordingId);
    if (masterSections.isEmpty) return;
    final mappedSections = await _fingerprints.alignSectionsToRecording(
      practiceFolder: practice.directory,
      recording: recording,
      mastersFolder: masters.directory,
      masterRecording: masterRecording,
      masterSections: masterSections,
    );
    if (mappedSections.isEmpty) return;
    if (_selectedRecording?.id == recording.id) {
      _rememberSectionUndo();
    }
    await _sectionsRepository.saveAll(
        practice.directory.path, recording.id, mappedSections);
    if (_selectedRecording?.id == recording.id) {
      await _refreshSections(recording);
    }
  }

  Future<void> _ignoreFingerprintMatch(FingerprintMatch match) async {
    final practice = _selected;
    if (practice == null) return;
    await _fingerprintDecisions.ignore(practice.directory.path, match);
    final mastersFolder = _resolvedMastersFolder;
    if (mastersFolder != null) {
      await _fingerprintLearning.recordIgnored(mastersFolder.path, match);
    }
    final decisions = await _fingerprintDecisions.load(practice.directory.path);
    if (mounted) {
      setState(() {
        _fingerprintDecisionState = decisions;
        _fingerprintMatches = _fingerprintMatches
            .where((item) => item.key != match.key)
            .toList(growable: false);
      });
    }
    await _fingerprintSuggestions.save(
        practice.directory.path, _fingerprintRawMatches);
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
    await _refreshMastersList();
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
      await _refreshMastersList();
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

  Future<void> _refreshMastersList() async {
    final masters = await _loadMastersPractice();
    if (!mounted || masters == null) return;
    setState(() {
      _mastersPractice = masters;
      if (_selectedIsMasters) {
        _selected = masters;
        if (_selectedRecording != null) {
          _selectedRecording = masters.recordings
              .where((item) => item.id == _selectedRecording!.id)
              .firstOrNull;
        }
      }
    });
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
        builder: (context, setDialogState) {
          final driveConnected = _preferences.googleDriveCredentials != null;
          Widget sectionHeader(String title, String subtitle) => Padding(
                padding: const EdgeInsets.only(top: 34, bottom: 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      subtitle,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(height: 1.25),
                    ),
                    const SizedBox(height: 18),
                    const Divider(height: 1),
                  ],
                ),
              );
          return AlertDialog(
            title: const Text('Preferences'),
            content: SizedBox(
              width: 760,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  sectionHeader('Most Used',
                      'Common controls you are likely to use while working in the app.'),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.person_outline),
                    title: const Text('Display name'),
                    subtitle: Text(_preferences.displayName),
                    trailing: TextButton(
                        onPressed: () async {
                          await _editDisplayName();
                          setDialogState(() {});
                        },
                        child: const Text('Edit')),
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
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.speaker_outlined),
                    title: const Text('Audio output device'),
                    subtitle: Text(_audioOutputSubtitle()),
                    trailing: PopupMenuButton<AudioDevice>(
                      tooltip: 'Choose output device',
                      onSelected: (device) async {
                        await _setAudioOutputDevice(device);
                        setDialogState(() {});
                      },
                      itemBuilder: (context) => [
                        for (final device in _audio.audioDevices)
                          PopupMenuItem(
                            value: device,
                            child: Text(_audioDeviceLabel(device)),
                          ),
                      ],
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Text('Choose'),
                      ),
                    ),
                  ),
                  sectionHeader('Fingerprinting',
                      'Matching, tuning, weights, evaluation, and cache control.'),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.analytics_outlined),
                    title: const Text('Evaluate fingerprint corrections'),
                    subtitle: Text(_selected == null
                        ? 'Select a practice to compare current guesses against saved corrections.'
                        : 'Compare current visible suggestions for ${_selected!.name} against saved correction reports.'),
                    trailing: TextButton(
                      onPressed:
                          _selected == null || _resolvedMastersFolder == null
                              ? null
                              : () async {
                                  await _evaluateFingerprintCorrections();
                                  setDialogState(() {});
                                },
                      child: const Text('Evaluate'),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.tune_outlined),
                    title: const Text('Re-evaluate fingerprint tuning'),
                    subtitle: Text(_resolvedMastersFolder == null
                        ? 'Choose or create a Masters folder before tuning from historical evaluations.'
                        : 'Run a historical profile search across saved correction evaluations. Does not auto-apply unless you choose Apply/Save.'),
                    trailing: TextButton(
                      onPressed: _resolvedMastersFolder == null
                          ? null
                          : () async {
                              Navigator.pop(context);
                              await _reEvaluateFingerprintWeightsFromHistory();
                            },
                      child: const Text('Re-evaluate'),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.stacked_bar_chart_outlined),
                    title: const Text('Fingerprint feature chart'),
                    subtitle: Text(_selected == null
                        ? 'Select a practice to compare one recording against one master.'
                        : 'Inspect feature averages and current weights for ${_selected!.name}.'),
                    trailing: TextButton(
                      onPressed:
                          _selected == null || _resolvedMastersFolder == null
                              ? null
                              : () async {
                                  await _showFingerprintFeatureChartDialog();
                                  setDialogState(() {});
                                },
                      child: const Text('View'),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.tune),
                    title: const Text('Fingerprint weight profile'),
                    subtitle: Text(
                        'Current profile: ${_currentFingerprintWeightProfile()}'),
                    trailing: Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: () async {
                            final defaults = FingerprintRepository
                                .defaultFeatureWeightProfile();
                            await _applyFingerprintWeightProfile(defaults);
                            setDialogState(() {});
                          },
                          child: const Text('Apply defaults'),
                        ),
                        TextButton(
                          onPressed: () async {
                            final defaults = FingerprintRepository
                                .defaultFeatureWeightProfile();
                            await _saveFingerprintWeightProfile(defaults);
                            setDialogState(() {});
                          },
                          child: const Text('Reset saved'),
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.cleaning_services_outlined),
                    title: const Text('Selected practice generated cache'),
                    subtitle: Text(_selected == null
                        ? 'Select a practice to clear waveform, playback, and fingerprint cache.'
                        : 'Clear generated cache and force ${_selected!.name} to redo fingerprint matching.'),
                    trailing: TextButton(
                      onPressed: _selected == null
                          ? null
                          : () async {
                              await _clearSelectedPracticeCache();
                              setDialogState(() {});
                            },
                      child: const Text('Clear'),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.library_music_outlined),
                    title: const Text('Masters generated cache'),
                    subtitle: Text(_resolvedMastersFolder == null
                        ? 'Choose or create a Masters folder before clearing its generated cache.'
                        : 'Clear generated waveforms and fingerprints for ${_resolvedMastersFolder!.path}.'),
                    trailing: TextButton(
                      onPressed: _resolvedMastersFolder == null
                          ? null
                          : () async {
                              await _clearMastersCache();
                              setDialogState(() {});
                            },
                      child: const Text('Clear'),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Masters Folder'),
                    subtitle: Text(_mastersFolderLabel()),
                    trailing: TextButton(
                        onPressed: () async {
                          await _chooseMastersFolder();
                          setDialogState(() {});
                        },
                        child: const Text('Choose')),
                  ),
                  sectionHeader('Sync And Cloud',
                      'Band sync, Google Drive connection, and remote folder settings.'),
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
                    leading: const Icon(Icons.cloud_outlined),
                    title: const Text('Google Drive account'),
                    subtitle: Text(_googleDriveStatusLabel()),
                    trailing: Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: () async {
                            await _importGoogleOAuthJson();
                            setDialogState(() {});
                          },
                          child: const Text('Import JSON'),
                        ),
                        TextButton(
                          onPressed: () async {
                            await _editGoogleClientConfig();
                            setDialogState(() {});
                          },
                          child: Text(_preferences.hasGoogleClientConfig
                              ? 'Edit OAuth'
                              : 'Add OAuth'),
                        ),
                        TextButton(
                          onPressed: _hasGoogleOAuthConfig && !driveConnected
                              ? () async {
                                  await _connectGoogleDrive();
                                  setDialogState(() {});
                                }
                              : null,
                          child: const Text('Connect'),
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    enabled: driveConnected,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_shared_outlined),
                    title: const Text('Google Drive remote root'),
                    subtitle: Text(driveConnected
                        ? _googleDriveRootLabel()
                        : 'Connect Google Drive before choosing a remote folder.'),
                    trailing: Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: driveConnected
                              ? () async {
                                  await _chooseGoogleDriveRootFolder();
                                  setDialogState(() {});
                                }
                              : null,
                          child: const Text('Browse'),
                        ),
                        TextButton(
                          onPressed: _preferences.googleDriveCredentials == null
                              ? null
                              : () async {
                                  await _disconnectGoogleDrive();
                                  setDialogState(() {});
                                },
                          child: const Text('Disconnect'),
                        ),
                      ],
                    ),
                  ),
                  sectionHeader('Folders And App',
                      'Less frequently changed root folder settings and app information.'),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Remembered Band Folder'),
                    subtitle: Text(_preferences.bandFolder ?? 'None selected'),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.info_outline),
                    title: const Text('RiffNotes version'),
                    subtitle: Text(_appVersionLabel()),
                  ),
                ]),
              ),
            ),
            actions: [
              FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done'))
            ],
          );
        },
      ),
    );
  }

  Future<void> _editDisplayName() async {
    final controller = TextEditingController(text: _preferences.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Display name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name used for your note file',
            helperText: 'This controls .riffnotes.<name>.bandnotes',
          ),
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
    if (name == null) return;
    await _preferences.setDisplayName(name);
    final recording = _selectedRecording;
    if (recording != null) await _refreshNotes(recording);
    final practice = _selected;
    if (practice != null) await _refreshPracticeReview(practice);
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
        _replaceSelectedPractice(updatedPractice);
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

  Future<void> _deleteTake(Recording recording) async {
    final practice = _selected;
    if (practice == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete take?'),
        content: Text(
            'This will permanently delete ${recording.filename} from ${practice.name}.'),
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
    if (confirmed != true) return;
    try {
      await _audio.stop();
      final updatedPractice =
          await _activity.run('Deleting take', (update) async {
        update(null, 'Removing ${recording.filename}…');
        final result = await _repository.deleteRecording(practice, recording);
        update(1, 'Take deleted');
        return result;
      });
      if (!mounted) return;
      final deletedSelected = _selectedRecording?.id == recording.id;
      setState(() {
        _replaceSelectedPractice(updatedPractice);
        _fingerprintRawMatches = _fingerprintRawMatches
            .where((item) => item.recordingId != recording.id)
            .toList(growable: false);
        _fingerprintMatches = _fingerprintMatches
            .where((item) => item.recordingId != recording.id)
            .toList(growable: false);
        if (deletedSelected) {
          _selectedRecording = null;
          _notes = const [];
          _sections = const [];
          _sectionUndoStack.clear();
          _rangeStartMs = null;
          _rangeRecordingId = null;
          _sectionStartMs = null;
          _sectionRecordingId = null;
        }
      });
      await _refreshPracticeReview(updatedPractice);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Deleted ${recording.filename}.')));
      }
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Delete failed: ${error.message}')));
      }
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
    final normalized = _normalizedNewSectionRange(startMs, endMs);
    if (normalized == null) return;
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
            startMs: normalized.$1,
            endMs: normalized.$2,
            label: label.text.trim(),
            colorIndex: _sectionColorIndexForLabel(label.text.trim())),
      );
      _rememberSectionUndo();
      await _refreshSections(recording);
    }
    label.dispose();
  }

  Future<void> _addSectionRangeFromLane(
      Recording recording, int startMs, int endMs) async {
    final durationMs = _audio.duration?.inMilliseconds;
    if (durationMs == null || durationMs <= 0) return;
    final clampedStart = startMs.clamp(0, durationMs).toInt();
    final clampedEnd = endMs.clamp(0, durationMs).toInt();
    final sectionStart = clampedStart < clampedEnd ? clampedStart : clampedEnd;
    final sectionEnd = clampedStart < clampedEnd ? clampedEnd : clampedStart;
    if (sectionEnd - sectionStart < 250) return;
    await _addSection(recording, sectionStart, sectionEnd);
  }

  Future<void> _splitSectionAt(int clickedMs) async {
    final practice = _selected;
    final recording = _selectedRecording;
    final durationMs = _audio.duration?.inMilliseconds;
    if (practice == null || recording == null || durationMs == null) {
      _log.warning('sections', 'Split ignored: no practice/recording/duration');
      return;
    }
    final splitMs = clickedMs.clamp(0, durationMs).toInt();
    _log.info('sections',
        'Split requested at ${_formatMilliseconds(splitMs)} for ${recording.filename}');
    final sorted = _sections.toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    final containing = sorted
        .where((section) =>
            splitMs > section.startMs + 250 && splitMs < section.endMs - 250)
        .firstOrNull;
    final updated = List<SongSection>.of(sorted);
    if (containing != null) {
      _log.info('sections', 'Splitting existing section "${containing.label}"');
      final index = updated.indexOf(containing);
      final newLabel = _nextSectionLabel(sorted);
      updated
        ..removeAt(index)
        ..insertAll(index, [
          SongSection(
            recordingId: containing.recordingId,
            startMs: containing.startMs,
            endMs: splitMs,
            label: containing.label,
            colorIndex: containing.colorIndex,
          ),
          SongSection(
            recordingId: containing.recordingId,
            startMs: splitMs,
            endMs: containing.endMs,
            label: newLabel,
            colorIndex: _sectionColorIndexForLabel(newLabel),
          ),
        ]);
    } else {
      final previousEnd = sorted
          .where((section) => section.endMs <= splitMs)
          .fold<int>(
              0,
              (latest, section) =>
                  section.endMs > latest ? section.endMs : latest);
      final nextStart = sorted
          .where((section) => section.startMs >= splitMs)
          .fold<int>(
              durationMs,
              (earliest, section) =>
                  section.startMs < earliest ? section.startMs : earliest);
      if (splitMs <= previousEnd + 250 || splitMs >= nextStart - 250) return;
      _log.info('sections',
          'Splitting empty lane ${_formatMilliseconds(previousEnd)}-${_formatMilliseconds(nextStart)}');
      updated.addAll([
        SongSection(
          recordingId: recording.id,
          startMs: previousEnd,
          endMs: splitMs,
          label: _nextSectionLabel(updated),
          colorIndex: _sectionColorIndexForLabel(_nextSectionLabel(updated)),
        ),
        SongSection(
          recordingId: recording.id,
          startMs: splitMs,
          endMs: nextStart,
          label: _nextSectionLabel(updated, offset: 1),
          colorIndex:
              _sectionColorIndexForLabel(_nextSectionLabel(updated, offset: 1)),
        ),
      ]);
    }
    _rememberSectionUndo();
    await _sectionsRepository.saveAll(
        practice.directory.path, recording.id, updated);
    await _refreshSections(recording);
    _log.info('sections', 'Split saved; ${updated.length} sections now');
  }

  Future<void> _resizeSection(
      SongSection section, int startMs, int endMs) async {
    final practice = _selected;
    final recording = _selectedRecording;
    if (practice == null || recording == null) {
      _log.warning('sections', 'Resize ignored: no practice/recording');
      return;
    }
    final current = _currentSectionFor(section) ?? section;
    final updatedSections = _sections.toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    final index = updatedSections.indexOf(current);
    if (index == -1) {
      _log.warning('sections',
          'Resize ignored: section "${section.label}" was not found');
      return;
    }
    var resizeAction = 'resize';
    final isLeftDrag = startMs != current.startMs;
    final isRightDrag = endMs != current.endMs;
    if (isLeftDrag && index > 0) {
      final previous = updatedSections[index - 1];
      if (startMs <= previous.startMs + 250) {
        resizeAction = 'merge-left';
        updatedSections
          ..removeAt(index)
          ..removeAt(index - 1)
          ..insert(
            index - 1,
            SongSection(
              recordingId: current.recordingId,
              startMs: previous.startMs,
              endMs: current.endMs,
              label: _mergedLabel(previous.label, current.label),
              colorIndex: current.colorIndex,
            ),
          );
      } else if (startMs < previous.endMs ||
          previous.endMs == current.startMs) {
        resizeAction = 'move-left-boundary';
        final boundary =
            startMs.clamp(previous.startMs + 250, current.endMs - 250).toInt();
        updatedSections[index - 1] = SongSection(
          recordingId: previous.recordingId,
          startMs: previous.startMs,
          endMs: boundary,
          label: previous.label,
          colorIndex: previous.colorIndex,
        );
        updatedSections[index] = SongSection(
          recordingId: current.recordingId,
          startMs: boundary,
          endMs: current.endMs,
          label: current.label,
          colorIndex: current.colorIndex,
        );
      } else {
        resizeAction = 'resize-left';
        final clamped = _clampedSectionRange(current, startMs, current.endMs);
        if (clamped == null) {
          _log.warning('sections', 'Resize-left rejected by clamp');
          return;
        }
        updatedSections[index] = SongSection(
          recordingId: current.recordingId,
          startMs: clamped.$1,
          endMs: clamped.$2,
          label: current.label,
          colorIndex: current.colorIndex,
        );
      }
    } else if (isRightDrag && index < updatedSections.length - 1) {
      final next = updatedSections[index + 1];
      if (endMs >= next.endMs - 250) {
        resizeAction = 'merge-right';
        updatedSections
          ..removeAt(index + 1)
          ..removeAt(index)
          ..insert(
            index,
            SongSection(
              recordingId: current.recordingId,
              startMs: current.startMs,
              endMs: next.endMs,
              label: _mergedLabel(current.label, next.label),
              colorIndex: current.colorIndex,
            ),
          );
      } else if (endMs > next.startMs || current.endMs == next.startMs) {
        resizeAction = 'move-right-boundary';
        final boundary =
            endMs.clamp(current.startMs + 250, next.endMs - 250).toInt();
        updatedSections[index] = SongSection(
          recordingId: current.recordingId,
          startMs: current.startMs,
          endMs: boundary,
          label: current.label,
          colorIndex: current.colorIndex,
        );
        updatedSections[index + 1] = SongSection(
          recordingId: next.recordingId,
          startMs: boundary,
          endMs: next.endMs,
          label: next.label,
          colorIndex: next.colorIndex,
        );
      } else {
        resizeAction = 'resize-right';
        final clamped = _clampedSectionRange(current, current.startMs, endMs);
        if (clamped == null) {
          _log.warning('sections', 'Resize-right rejected by clamp');
          return;
        }
        updatedSections[index] = SongSection(
          recordingId: current.recordingId,
          startMs: clamped.$1,
          endMs: clamped.$2,
          label: current.label,
          colorIndex: current.colorIndex,
        );
      }
    } else {
      final clamped = _clampedSectionRange(current, startMs, endMs);
      if (clamped == null) {
        _log.warning('sections', 'Resize rejected by clamp');
        return;
      }
      updatedSections[index] = SongSection(
        recordingId: current.recordingId,
        startMs: clamped.$1,
        endMs: clamped.$2,
        label: current.label,
        colorIndex: current.colorIndex,
      );
    }
    if (resizeAction.startsWith('merge') || _shouldLogSectionResize()) {
      _log.info('sections',
          '$resizeAction "${current.label}" to ${_formatMilliseconds(startMs)}-${_formatMilliseconds(endMs)}');
    }
    if (!_sectionResizeGestureActive) {
      _rememberSectionUndo();
    }
    if (mounted) {
      setState(() => _sections = List<SongSection>.of(updatedSections)
        ..sort((a, b) => a.startMs.compareTo(b.startMs)));
    }
    await _sectionsRepository.saveAll(
        practice.directory.path, recording.id, updatedSections);
  }

  void _startSectionResizeGesture() {
    if (_sectionResizeGestureActive) return;
    _sectionResizeGestureActive = true;
    _rememberSectionUndo();
  }

  void _endSectionResizeGesture() {
    _sectionResizeGestureActive = false;
  }

  Future<void> _mergeSections(SongSection first, SongSection second) async {
    final practice = _selected;
    final recording = _selectedRecording;
    if (practice == null || recording == null) return;
    final currentFirst = _currentSectionFor(first) ?? first;
    final currentSecond = _currentSectionFor(second) ?? second;
    final sorted = _sections.toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    final firstIndex = sorted.indexOf(currentFirst);
    final secondIndex = sorted.indexOf(currentSecond);
    if (firstIndex == -1 ||
        secondIndex == -1 ||
        (firstIndex - secondIndex).abs() != 1) {
      _log.warning('sections',
          'Merge ignored: "${first.label}" and "${second.label}" are not adjacent');
      return;
    }
    final left = firstIndex < secondIndex ? currentFirst : currentSecond;
    final right = firstIndex < secondIndex ? currentSecond : currentFirst;
    final merged = SongSection(
      recordingId: left.recordingId,
      startMs: left.startMs,
      endMs: right.endMs,
      label: _mergedLabel(left.label, right.label),
      colorIndex: left.colorIndex,
    );
    final updated = sorted
      ..remove(left)
      ..remove(right)
      ..add(merged)
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    _rememberSectionUndo();
    _log.info('sections',
        'Merged "${left.label}" + "${right.label}" into "${merged.label}"');
    await _sectionsRepository.saveAll(
        practice.directory.path, recording.id, updated);
    await _refreshSections(recording);
  }

  Future<void> _editSection(SongSection section) async {
    final practice = _selected;
    final recording = _selectedRecording;
    if (practice == null || recording == null) return;
    section = _currentSectionFor(section) ?? section;
    _log.info('sections',
        'Opening edit dialog for "${section.label}" ${_formatMilliseconds(section.startMs)}-${_formatMilliseconds(section.endMs)}');
    final label = TextEditingController(text: section.label);
    final start =
        TextEditingController(text: _formatTimestampForEdit(section.startMs));
    final end =
        TextEditingController(text: _formatTimestampForEdit(section.endMs));
    var selectedColor = section.colorIndex;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
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
                decoration: const InputDecoration(labelText: 'Start mm:ss.mmm'),
              ),
              TextField(
                controller: end,
                decoration: const InputDecoration(labelText: 'End mm:ss.mmm'),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Color',
                    style: Theme.of(context).textTheme.labelLarge),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var index = 0; index < sectionPalette.length; index += 1)
                    InkWell(
                      onTap: () => setDialogState(() => selectedColor = index),
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: sectionPalette[index],
                          border: Border.all(
                            color: selectedColor == index
                                ? Colors.white
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                      ),
                    ),
                ],
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
      ),
    );
    if (accepted == true && label.text.trim().isNotEmpty) {
      final startMs = _parseTimestamp(start.text.trim()) ?? section.startMs;
      final endMs = _parseTimestamp(end.text.trim()) ?? section.endMs;
      final clamped = _clampedSectionRange(section, startMs, endMs);
      if (clamped == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Section end must be after the start.')));
        }
      } else {
        _rememberSectionUndo();
        _log.info('sections',
            'Saving edit as "${label.text.trim()}" ${_formatMilliseconds(clamped.$1)}-${_formatMilliseconds(clamped.$2)}');
        await _sectionsRepository.replace(
          practice.directory.path,
          section,
          SongSection(
            recordingId: section.recordingId,
            startMs: clamped.$1,
            endMs: clamped.$2,
            label: label.text.trim(),
            colorIndex: selectedColor,
          ),
        );
        await _refreshSections(recording);
      }
    }
    label.dispose();
    start.dispose();
    end.dispose();
  }

  Future<void> _adjustSection(SongSection section) async {
    final practice = _selected;
    final recording = _selectedRecording;
    final durationMs = _audio.duration?.inMilliseconds;
    if (practice == null || recording == null || durationMs == null) return;
    section = _currentSectionFor(section) ?? section;
    final startAdjust = TextEditingController(text: '0');
    final endAdjust = TextEditingController(text: '0');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Adjust ${section.label}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'Enter seconds to move each edge. Use negative values to move earlier.'),
            const SizedBox(height: 12),
            TextField(
              controller: startAdjust,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  const InputDecoration(labelText: 'Start adjustment seconds'),
            ),
            TextField(
              controller: endAdjust,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  const InputDecoration(labelText: 'End adjustment seconds'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Adjust')),
        ],
      ),
    );
    if (accepted == true) {
      final startDelta =
          ((double.tryParse(startAdjust.text.trim()) ?? 0) * 1000).round();
      final endDelta =
          ((double.tryParse(endAdjust.text.trim()) ?? 0) * 1000).round();
      final startMs =
          (section.startMs + startDelta).clamp(0, section.endMs - 250).toInt();
      final endMs =
          (section.endMs + endDelta).clamp(startMs + 250, durationMs).toInt();
      final clamped = _clampedSectionRange(section, startMs, endMs);
      if (clamped == null) return;
      final updated = SongSection(
        recordingId: section.recordingId,
        startMs: clamped.$1,
        endMs: clamped.$2,
        label: section.label,
        colorIndex: section.colorIndex,
      );
      _rememberSectionUndo();
      await _sectionsRepository.replace(
          practice.directory.path, section, updated);
      await _refreshSections(recording);
    }
    startAdjust.dispose();
    endAdjust.dispose();
  }

  Future<void> _deleteSection(SongSection section) async {
    final practice = _selected;
    final recording = _selectedRecording;
    if (practice == null || recording == null) return;
    section = _currentSectionFor(section) ?? section;
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
      _rememberSectionUndo();
      _log.info('sections',
          'Deleting "${section.label}" ${_formatMilliseconds(section.startMs)}-${_formatMilliseconds(section.endMs)}');
      await _sectionsRepository.delete(practice.directory.path, section);
      await _refreshSections(recording);
    }
  }

  void _rememberSectionUndo() {
    setState(() {
      _sectionUndoStack.add(List<SongSection>.of(_sections));
      if (_sectionUndoStack.length > 20) {
        _sectionUndoStack.removeAt(0);
      }
    });
  }

  Future<void> _autoAssignSectionColors() async {
    final practice = _selected;
    final recording = _selectedRecording;
    if (practice == null || recording == null || _sections.isEmpty) return;
    final updated = _sections
        .map(
          (section) => SongSection(
            recordingId: section.recordingId,
            startMs: section.startMs,
            endMs: section.endMs,
            label: section.label,
            colorIndex: _sectionColorIndexForLabel(section.label),
          ),
        )
        .toList(growable: false)
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    _rememberSectionUndo();
    await _sectionsRepository.saveAll(
        practice.directory.path, recording.id, updated);
    await _refreshSections(recording);
  }

  bool _shouldLogSectionResize() {
    final now = DateTime.now();
    final last = _lastSectionResizeLogAt;
    if (last != null && now.difference(last).inMilliseconds < 250) {
      return false;
    }
    _lastSectionResizeLogAt = now;
    return true;
  }

  Future<void> _undoLastSectionEdit() async {
    final practice = _selected;
    final recording = _selectedRecording;
    if (practice == null || recording == null || _sectionUndoStack.isEmpty) {
      _log.warning('sections', 'Undo ignored: no previous section state');
      return;
    }
    final previous = _sectionUndoStack.removeLast();
    _log.info('sections', 'Undo restored ${previous.length} sections');
    await _sectionsRepository.saveAll(
      practice.directory.path,
      recording.id,
      previous,
    );
    if (mounted) setState(() {});
    await _refreshSections(recording);
  }

  String _formatTimestampForEdit(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    final millis = duration.inMilliseconds.remainder(1000);
    final secondsPart = '${seconds.toString().padLeft(2, '0')}.'
        '${millis.toString().padLeft(3, '0')}';
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:$secondsPart';
    }
    return '${minutes.toString().padLeft(2, '0')}:$secondsPart';
  }

  (int, int)? _normalizedNewSectionRange(int startMs, int endMs) {
    final durationMs = _audio.duration?.inMilliseconds;
    if (durationMs == null || durationMs <= 0) return null;
    final start =
        (startMs < endMs ? startMs : endMs).clamp(0, durationMs).toInt();
    final end =
        (startMs < endMs ? endMs : startMs).clamp(0, durationMs).toInt();
    if (end - start < 250) return null;
    final overlaps = _sections.any(
      (section) => start < section.endMs && end > section.startMs,
    );
    return overlaps ? null : (start, end);
  }

  (int, int)? _clampedSectionRange(
    SongSection section,
    int requestedStartMs,
    int requestedEndMs,
  ) {
    final durationMs = _audio.duration?.inMilliseconds;
    if (durationMs == null || durationMs <= 0) return null;
    final others = _sections.where((item) => item != section).toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    final previousEnd = others
        .where((item) => item.endMs <= section.startMs)
        .fold<int>(
            0, (latest, item) => item.endMs > latest ? item.endMs : latest);
    final nextStart = others
        .where((item) => item.startMs >= section.endMs)
        .fold<int>(
            durationMs,
            (earliest, item) =>
                item.startMs < earliest ? item.startMs : earliest);
    final start = requestedStartMs.clamp(previousEnd, nextStart - 250).toInt();
    final end = requestedEndMs.clamp(start + 250, nextStart).toInt();
    if (end - start < 250) return null;
    return (start, end);
  }

  SongSection? _currentSectionFor(SongSection section) {
    return _sections.where((item) => item == section).firstOrNull ??
        _sections
            .where((item) =>
                item.recordingId == section.recordingId &&
                item.label == section.label)
            .firstOrNull;
  }

  String _splitLabel(String label) {
    final trimmed = label.trim();
    return trimmed.isEmpty ? 'Section' : '$trimmed 2';
  }

  String _normalizedSectionPrefix(String label) {
    final cleaned =
        label.trim().toLowerCase().replaceAll(RegExp(r'[^a-z]+'), '');
    if (cleaned.isEmpty) return '';
    for (final prefix in const <String>[
      'intro',
      'prechorus',
      'chorus',
      'verse',
      'bridge',
      'outro',
    ]) {
      if (cleaned.startsWith(prefix)) return prefix;
    }
    return cleaned;
  }

  int _sectionColorIndexForLabel(String label) {
    switch (_normalizedSectionPrefix(label)) {
      case 'intro':
      case 'outro':
        return 0;
      case 'verse':
        return 5;
      case 'prechorus':
        return 3;
      case 'chorus':
        return 6;
      case 'bridge':
        return 1;
      case '':
        return 2;
      default:
        return 2;
    }
  }

  String _mergedLabel(String left, String right) {
    if (left == right) return left;
    if (left.trim().isEmpty) return right;
    if (right.trim().isEmpty) return left;
    return '$left / $right';
  }

  String _nextSectionLabel(List<SongSection> existing, {int offset = 0}) {
    return 'Section ${existing.length + offset + 1}';
  }

  int _suggestSectionColor(String label) {
    final normalized =
        label.toLowerCase().replaceAll(RegExp(r'\s+[a-z0-9]+$'), '').trim();
    if (normalized.isEmpty) return 0;
    final match = _sections.where((section) {
      final existing = section.label
          .toLowerCase()
          .replaceAll(RegExp(r'\s+[a-z0-9]+$'), '')
          .trim();
      return existing == normalized;
    }).firstOrNull;
    return match?.colorIndex ?? 0;
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

  int? _parseTimestamp(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final parts = trimmed.split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    final secondsPart = parts.removeLast();
    final minutesPart = parts.removeLast();
    final hours = parts.isEmpty ? 0 : int.tryParse(parts.single);
    final minutes = int.tryParse(minutesPart);
    if (hours == null || minutes == null) return null;
    final secondsPieces = secondsPart.split('.');
    final seconds = int.tryParse(secondsPieces.first);
    if (seconds == null) return null;
    var millis = 0;
    if (secondsPieces.length > 1) {
      final fraction = (secondsPieces.sublist(1).join()).padRight(3, '0');
      final parsedMillis = int.tryParse(fraction.substring(0, 3));
      if (parsedMillis == null) return null;
      millis = parsedMillis;
    }
    return (((hours * 60 + minutes) * 60 + seconds) * 1000) + millis;
  }

  String _formatMilliseconds(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    return '${duration.inMinutes.remainder(60).toString().padLeft(2, '0')}:${duration.inSeconds.remainder(60).toString().padLeft(2, '0')}';
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
        _replaceSelectedPractice(updatedPractice);
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

  bool _isJamRecording(Recording recording) =>
      recording.title?.trim().toLowerCase() == 'jam';

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
          _replaceSelectedPractice(updatedPractice);
          _selectedRecording = null;
          _sections = const [];
          _sectionUndoStack.clear();
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

  Future<void> _showLogs() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AnimatedBuilder(
        animation: _log,
        builder: (context, _) => AlertDialog(
          title: const Text('RiffNotes logs'),
          content: SizedBox(
            width: 820,
            height: 520,
            child: _log.entries.isEmpty
                ? const Center(child: Text('No log entries yet.'))
                : ListView.builder(
                    itemCount: _log.entries.length,
                    itemBuilder: (context, index) {
                      final entry = _log.entries[index];
                      final color = switch (entry.level) {
                        AppLogLevel.info =>
                          Theme.of(context).colorScheme.onSurface,
                        AppLogLevel.warning =>
                          Theme.of(context).colorScheme.tertiary,
                        AppLogLevel.error =>
                          Theme.of(context).colorScheme.error,
                      };
                      return SelectableText(
                        entry.line,
                        style: TextStyle(
                          color: color,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton.icon(
              onPressed: _log.entries.isEmpty ? null : _log.clear,
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('Clear'),
            ),
            TextButton.icon(
              onPressed: _log.entries.isEmpty
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(
                        text:
                            _log.entries.map((entry) => entry.line).join('\n'),
                      ));
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                      if (mounted) {
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          const SnackBar(content: Text('Logs copied')),
                        );
                      }
                    },
              icon: const Icon(Icons.copy),
              label: const Text('Copy'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _activity,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('RiffNotes'),
                Text(
                  _appVersionLabel(),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            actions: [
              TextButton.icon(
                  onPressed: _chooseBandFolder,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Band Folder')),
              IconButton(
                  tooltip: 'Upload selected practice to sync folder',
                  onPressed: _selected == null || _selectedIsMasters
                      ? null
                      : _uploadSelectedPractice,
                  icon: const Icon(Icons.cloud_upload_outlined)),
              IconButton(
                  tooltip: 'Download selected practice from sync folder',
                  onPressed: _selected == null || _selectedIsMasters
                      ? null
                      : _downloadSelectedPractice,
                  icon: const Icon(Icons.cloud_download_outlined)),
              IconButton(
                  tooltip: 'Match selected practice against Masters',
                  onPressed: _selected == null || _selectedIsMasters
                      ? null
                      : _matchSelectedPracticeFingerprints,
                  icon: const Icon(Icons.fingerprint)),
              IconButton(
                  tooltip: 'View logs',
                  onPressed: _showLogs,
                  icon: const Icon(Icons.article_outlined)),
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
                      masters: _mastersPractice,
                      selected: _selected,
                      selectedIsMasters: _selectedIsMasters,
                      onSelectMasters: _selectMastersLibrary,
                      onSelect: _selectPractice)),
              const VerticalDivider(width: 1),
              Expanded(
                child: _RecordingList(
                  practice: _selected,
                  bandFolder: _bandFolder,
                  isMasters: _selectedIsMasters,
                  selected: _selectedRecording,
                  quickSongTitles: _selected == null
                      ? const <String>[]
                      : _quickSongTitlesForPractice(_selected!),
                  onSelect: (recording) => _selectRecording(
                    recording,
                    autoPlay: _preferences.autoPlayOnTakeSelection,
                  ),
                  onEditTitle: _editTitle,
                  onQuickSetTitle: _quickSetRecordingTitle,
                  onTypeCustomTitle: _editTitle,
                  onDeleteTake: _deleteTake,
                  onToggleBest: (recording, isBestTake) => _updateRecording(
                    recording,
                    title: recording.title,
                    isBestTake: isBestTake,
                  ),
                  onBatchRename: _previewAndApplyRename,
                  onAddAnnotation: _addAnnotation,
                  onStartRangeNote: _startRangeNote,
                  onStartSection: _startSection,
                  onSplitSectionAt: _splitSectionAt,
                  onCreateSectionFromGap: (startMs, endMs) {
                    final recording = _selectedRecording;
                    if (recording == null) return;
                    unawaited(
                        _addSectionRangeFromLane(recording, startMs, endMs));
                  },
                  onAutoAssignSectionColors: _autoAssignSectionColors,
                  onResizeSection: _resizeSection,
                  onResizeSectionStart: _startSectionResizeGesture,
                  onResizeSectionEnd: _endSectionResizeGesture,
                  onMergeSections: _mergeSections,
                  onEditSection: _editSection,
                  onAdjustSection: _adjustSection,
                  onDeleteSection: _deleteSection,
                  onSectionLog: (message) => _log.info('section-ui', message),
                  canUndoSectionEdit: _sectionUndoStack.isNotEmpty,
                  onUndoSectionEdit: _undoLastSectionEdit,
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
                  fingerprintRawMatches: _fingerprintRawMatches,
                  fingerprintMatches: _fingerprintMatches,
                  onAcceptFingerprintGuess:
                      _acceptBestFingerprintGuessForRecording,
                  onDontKnowFingerprintGuess: _dontKnowFingerprintForRecording,
                  onShowFingerprintInfo: _showFingerprintInfoForRecording,
                  onTeachFingerprintCorrection:
                      _teachFingerprintCorrectionForRecording,
                  onPlayReviewNote: _playReviewNote,
                  audio: _audio,
                  waveform: _waveform,
                  playerPanelCollapsed: _playerPanelCollapsed,
                  onPlayerPanelCollapsedChanged: _setPlayerPanelCollapsed,
                ),
              ),
            ])),
          ]),
        ),
      );
}

class _PracticeList extends StatelessWidget {
  const _PracticeList({
    required this.practices,
    required this.masters,
    required this.selected,
    required this.selectedIsMasters,
    required this.onSelectMasters,
    required this.onSelect,
  });
  final List<PracticeFolder> practices;
  final PracticeFolder? masters;
  final PracticeFolder? selected;
  final bool selectedIsMasters;
  final VoidCallback onSelectMasters;
  final ValueChanged<PracticeFolder> onSelect;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text('PRACTICES', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          if (masters != null) ...[
            ListTile(
              selected: selectedIsMasters,
              leading: const Icon(Icons.library_music_outlined),
              title: const Text('Masters'),
              subtitle:
                  Text('${masters!.recordings.length} reference recordings'),
              onTap: onSelectMasters,
            ),
            const Divider(),
          ],
          if (practices.isEmpty && masters == null)
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
    required this.isMasters,
    required this.selected,
    required this.quickSongTitles,
    required this.onSelect,
    required this.onEditTitle,
    required this.onQuickSetTitle,
    required this.onTypeCustomTitle,
    required this.onDeleteTake,
    required this.onToggleBest,
    required this.onBatchRename,
    required this.onAddAnnotation,
    required this.onStartRangeNote,
    required this.onStartSection,
    required this.onSplitSectionAt,
    required this.onCreateSectionFromGap,
    required this.onAutoAssignSectionColors,
    required this.onResizeSection,
    required this.onResizeSectionStart,
    required this.onResizeSectionEnd,
    required this.onMergeSections,
    required this.onEditSection,
    required this.onAdjustSection,
    required this.onDeleteSection,
    required this.onSectionLog,
    required this.canUndoSectionEdit,
    required this.onUndoSectionEdit,
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
    required this.fingerprintRawMatches,
    required this.fingerprintMatches,
    required this.onAcceptFingerprintGuess,
    required this.onDontKnowFingerprintGuess,
    required this.onShowFingerprintInfo,
    required this.onTeachFingerprintCorrection,
    required this.onPlayReviewNote,
    required this.audio,
    required this.waveform,
    required this.playerPanelCollapsed,
    required this.onPlayerPanelCollapsedChanged,
  });
  final PracticeFolder? practice;
  final String? bandFolder;
  final bool isMasters;
  final Recording? selected;
  final List<String> quickSongTitles;
  final ValueChanged<Recording> onSelect;
  final ValueChanged<Recording> onEditTitle;
  final Future<void> Function(Recording recording, String title)
      onQuickSetTitle;
  final ValueChanged<Recording> onTypeCustomTitle;
  final ValueChanged<Recording> onDeleteTake;
  final Future<void> Function(Recording recording, bool isBestTake)
      onToggleBest;
  final Future<void> Function() onBatchRename;
  final ValueChanged<Recording> onAddAnnotation;
  final ValueChanged<Recording> onStartRangeNote;
  final ValueChanged<Recording> onStartSection;
  final ValueChanged<int> onSplitSectionAt;
  final void Function(int startMs, int endMs) onCreateSectionFromGap;
  final Future<void> Function() onAutoAssignSectionColors;
  final void Function(SongSection section, int startMs, int endMs)
      onResizeSection;
  final VoidCallback onResizeSectionStart;
  final VoidCallback onResizeSectionEnd;
  final void Function(SongSection first, SongSection second) onMergeSections;
  final ValueChanged<SongSection> onEditSection;
  final ValueChanged<SongSection> onAdjustSection;
  final ValueChanged<SongSection> onDeleteSection;
  final ValueChanged<String> onSectionLog;
  final bool canUndoSectionEdit;
  final Future<void> Function() onUndoSectionEdit;
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
  final List<FingerprintMatch> fingerprintRawMatches;
  final List<FingerprintMatch> fingerprintMatches;
  final Future<void> Function(Recording recording) onAcceptFingerprintGuess;
  final Future<void> Function(Recording recording) onDontKnowFingerprintGuess;
  final ValueChanged<Recording> onShowFingerprintInfo;
  final ValueChanged<Recording> onTeachFingerprintCorrection;
  final ValueChanged<UserAnnotation> onPlayReviewNote;
  final AudioController audio;
  final WaveformController waveform;
  final bool playerPanelCollapsed;
  final ValueChanged<bool> onPlayerPanelCollapsedChanged;

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
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(isMasters ? 'Masters' : practice!.name,
                        style: Theme.of(context).textTheme.headlineMedium),
                    if (isMasters)
                      Text(
                        'Reference recordings for song and section matching',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                  ],
                )),
                if (!isMasters)
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
              if (!isMasters && showPracticeReview) ...[
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
                  Expanded(
                      child: Text(isMasters
                          ? 'Select a master to play it and mark song sections.'
                          : 'Select a take to load it into the player.')),
                  if (!isMasters)
                    FilledButton.icon(
                      onPressed: onBatchRename,
                      icon: const Icon(Icons.drive_file_rename_outline),
                      label: const Text('Batch rename'),
                    ),
                ]),
                const SizedBox(height: 18),
                if (isMasters && practice!.recordings.isEmpty)
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.library_music_outlined),
                      title: Text('No master recordings yet.'),
                      subtitle: Text(
                          'Copy songs into the Masters folder, or save a practice take as a master.'),
                    ),
                  ),
                for (final recording in practice!.recordings)
                  Card(
                      child: ListTile(
                    selected: selected?.id == recording.id,
                    leading: Icon(
                        isMasters
                            ? Icons.library_music_outlined
                            : recording.isBestTake
                                ? Icons.star
                                : Icons.audiotrack,
                        color: !isMasters && recording.isBestTake
                            ? Colors.amber
                            : null),
                    title: Text(recording.title ?? recording.filename),
                    subtitle: _recordingSubtitleWidget(context, recording),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!isMasters)
                          PopupMenuButton<String>(
                            tooltip: 'Fingerprint info and guess actions',
                            onSelected: (action) async {
                              switch (action) {
                                case 'info':
                                  onShowFingerprintInfo(recording);
                                case 'teach':
                                  onTeachFingerprintCorrection(recording);
                                case 'accept':
                                  await onAcceptFingerprintGuess(recording);
                                case 'dontknow':
                                  await onDontKnowFingerprintGuess(recording);
                              }
                            },
                            itemBuilder: (context) {
                              final hasMatch =
                                  _bestFingerprintMatch(recording) != null;
                              return [
                                const PopupMenuItem<String>(
                                  value: 'info',
                                  child: Text('Fingerprint info'),
                                ),
                                const PopupMenuItem<String>(
                                  value: 'teach',
                                  child: Text('Teach correct match'),
                                ),
                                if (hasMatch) ...const [
                                  PopupMenuDivider(),
                                  PopupMenuItem<String>(
                                    value: 'accept',
                                    child: Text('Accept guessed title'),
                                  ),
                                  PopupMenuItem<String>(
                                    value: 'dontknow',
                                    child: Text("Don't know"),
                                  ),
                                ],
                              ];
                            },
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 4),
                              child: Icon(
                                Icons.fingerprint,
                                color: _bestFingerprintMatch(recording) == null
                                    ? Theme.of(context)
                                        .colorScheme
                                        .outline
                                        .withValues(alpha: .72)
                                    : null,
                              ),
                            ),
                          ),
                        if (!isMasters)
                          PopupMenuButton<String>(
                            tooltip: 'Quick set song title',
                            onSelected: (value) async {
                              if (value == '__type__') {
                                onTypeCustomTitle(recording);
                                return;
                              }
                              await onQuickSetTitle(recording, value);
                            },
                            itemBuilder: (context) => [
                              for (final title in quickSongTitles.take(14))
                                PopupMenuItem<String>(
                                  value: title,
                                  child: Text(title),
                                ),
                              if (quickSongTitles.isNotEmpty)
                                const PopupMenuDivider(),
                              const PopupMenuItem<String>(
                                value: '__type__',
                                child: Text('Type custom title...'),
                              ),
                            ],
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 4),
                              child: Icon(
                                  Icons.playlist_add_check_circle_outlined),
                            ),
                          ),
                        if (!isMasters)
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
                          tooltip: isMasters
                              ? 'Title this master'
                              : 'Title this take',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => onEditTitle(recording),
                        ),
                        if (!isMasters)
                          IconButton(
                            tooltip: 'Delete take',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => onDeleteTake(recording),
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
          onSplitSectionAt: onSplitSectionAt,
          onCreateSectionFromGap: onCreateSectionFromGap,
          onAutoAssignSectionColors: onAutoAssignSectionColors,
          onResizeSection: onResizeSection,
          onResizeSectionStart: onResizeSectionStart,
          onResizeSectionEnd: onResizeSectionEnd,
          onMergeSections: onMergeSections,
          onEditSection: onEditSection,
          onAdjustSection: onAdjustSection,
          onDeleteSection: onDeleteSection,
          onSectionLog: onSectionLog,
          canUndoSectionEdit: canUndoSectionEdit,
          onUndoSectionEdit: onUndoSectionEdit,
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
          collapsed: playerPanelCollapsed,
          onCollapsedChanged: onPlayerPanelCollapsedChanged,
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

  Widget _recordingSubtitleWidget(BuildContext context, Recording recording) {
    final baseStyle = Theme.of(context).textTheme.bodyMedium;
    final match = _bestFingerprintMatch(recording);
    final pieces = <TextSpan>[
      if (recording.title != null) TextSpan(text: recording.filename),
      TextSpan(text: _fileDetails(recording)),
      if (_isJamRecording(recording))
        const TextSpan(text: 'Fingerprinting skipped: Jam'),
      if (match != null)
        TextSpan(
          text: 'Match: ${match.displayName} (${match.scoreDetails})',
          style: baseStyle?.copyWith(
            color: _fingerprintConfidenceColor(context, match.confidence),
            fontWeight: FontWeight.w600,
          ),
        ),
    ];
    final spans = <InlineSpan>[];
    for (var index = 0; index < pieces.length; index += 1) {
      if (index > 0) spans.add(TextSpan(text: ' • ', style: baseStyle));
      spans.add(pieces[index]);
    }
    return Text.rich(
      TextSpan(style: baseStyle, children: spans),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  Color _fingerprintConfidenceColor(BuildContext context, double confidence) {
    final colors = Theme.of(context).colorScheme;
    if (confidence >= .90) return colors.primary;
    if (confidence >= .80) return colors.tertiary;
    if (confidence >= .70) return colors.secondary;
    return colors.error;
  }

  bool _isJamRecording(Recording recording) =>
      recording.title?.trim().toLowerCase() == 'jam';

  FingerprintMatch? _bestFingerprintMatch(Recording recording) {
    final matches = fingerprintRawMatches
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
    required this.onSplitSectionAt,
    required this.onCreateSectionFromGap,
    required this.onAutoAssignSectionColors,
    required this.onResizeSection,
    required this.onResizeSectionStart,
    required this.onResizeSectionEnd,
    required this.onMergeSections,
    required this.onEditSection,
    required this.onAdjustSection,
    required this.onDeleteSection,
    required this.onSectionLog,
    required this.canUndoSectionEdit,
    required this.onUndoSectionEdit,
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
    required this.collapsed,
    required this.onCollapsedChanged,
  });
  final AudioController controller;
  final WaveformController waveform;
  final ValueChanged<Recording> onAddAnnotation;
  final ValueChanged<Recording> onStartRangeNote;
  final ValueChanged<Recording> onStartSection;
  final ValueChanged<int> onSplitSectionAt;
  final void Function(int startMs, int endMs) onCreateSectionFromGap;
  final Future<void> Function() onAutoAssignSectionColors;
  final void Function(SongSection section, int startMs, int endMs)
      onResizeSection;
  final VoidCallback onResizeSectionStart;
  final VoidCallback onResizeSectionEnd;
  final void Function(SongSection first, SongSection second) onMergeSections;
  final ValueChanged<SongSection> onEditSection;
  final ValueChanged<SongSection> onAdjustSection;
  final ValueChanged<SongSection> onDeleteSection;
  final ValueChanged<String> onSectionLog;
  final bool canUndoSectionEdit;
  final Future<void> Function() onUndoSectionEdit;
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
  final bool collapsed;
  final ValueChanged<bool> onCollapsedChanged;

  @override
  State<_PlayerPanel> createState() => _PlayerPanelState();
}

class _ExportChoice {
  const _ExportChoice(this.extension, this.sectionOnly);

  final String extension;
  final bool sectionOnly;
}

class _PlayerPanelState extends State<_PlayerPanel> {
  final FocusNode _waveformFocus = FocusNode(debugLabel: 'Waveform controls');
  final ScrollController _waveformScrollController = ScrollController();
  double? _hoverProgress;
  int? _sectionResizePreviewMs;
  PracticeAnnotation? _hoveredNote;
  SongSection? _selectedSection;
  double _waveformZoom = 1;

  @override
  void dispose() {
    _waveformFocus.dispose();
    _waveformScrollController.dispose();
    super.dispose();
  }

  void _followWaveformProgress(
    double progress,
    double viewportWidth,
    double contentWidth,
  ) {
    if (!_waveformScrollController.hasClients ||
        contentWidth <= viewportWidth) {
      return;
    }
    final position = _waveformScrollController.position;
    const lead = 140.0;
    final targetX = progress * contentWidth;
    final currentLeft = position.pixels + lead;
    final currentRight = position.pixels + viewportWidth - lead;
    var targetOffset = position.pixels;
    if (targetX < currentLeft) {
      targetOffset = targetX - lead;
    } else if (targetX > currentRight) {
      targetOffset = targetX - viewportWidth + lead;
    }
    targetOffset = targetOffset.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((targetOffset - position.pixels).abs() >= 1) {
      position.jumpTo(targetOffset);
    }
  }

  KeyEventResult _handleWaveformKey(
      KeyEvent event, AudioController controller) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final isCtrl = pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight);
    if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (!widget.canUndoSectionEdit) return KeyEventResult.ignored;
      unawaited(widget.onUndoSectionEdit());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.space) {
      unawaited(controller.togglePlayback());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      final section = _selectedSection;
      if (section == null) return KeyEventResult.ignored;
      setState(() => _selectedSection = null);
      widget.onDeleteSection(section);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      unawaited(
          controller.seek(controller.position - const Duration(seconds: 5)));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      unawaited(
          controller.seek(controller.position + const Duration(seconds: 5)));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final waveform = widget.waveform;
    final onAddAnnotation = widget.onAddAnnotation;
    final onStartRangeNote = widget.onStartRangeNote;
    final onSplitSectionAt = widget.onSplitSectionAt;
    final onCreateSectionFromGap = widget.onCreateSectionFromGap;
    final onAutoAssignSectionColors = widget.onAutoAssignSectionColors;
    final onResizeSection = widget.onResizeSection;
    final onResizeSectionStart = widget.onResizeSectionStart;
    final onResizeSectionEnd = widget.onResizeSectionEnd;
    final onMergeSections = widget.onMergeSections;
    final onEditSection = widget.onEditSection;
    final onAdjustSection = widget.onAdjustSection;
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
    final collapsed = widget.collapsed;
    final onCollapsedChanged = widget.onCollapsedChanged;
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
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => onCollapsedChanged(!collapsed),
                    icon: Icon(collapsed
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down),
                    label: Text(collapsed ? 'Show player' : 'Collapse player'),
                  ),
                ),
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
                if (controller.recording != null && !collapsed) ...[
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
                    Focus(
                      focusNode: _waveformFocus,
                      onKeyEvent: (node, event) =>
                          _handleWaveformKey(event, controller),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          children: [
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final contentWidth =
                                    constraints.maxWidth * _waveformZoom;
                                return Scrollbar(
                                  controller: _waveformScrollController,
                                  thumbVisibility: _waveformZoom > 1,
                                  trackVisibility: _waveformZoom > 1,
                                  child: SingleChildScrollView(
                                    controller: _waveformScrollController,
                                    scrollDirection: Axis.horizontal,
                                    child: SizedBox(
                                      width: contentWidth,
                                      child: Column(
                                        children: [
                                          SectionTimeline(
                                            sections: sections,
                                            duration: duration,
                                            selectedSection: _selectedSection,
                                            onSectionTap: (section) {
                                              setState(() =>
                                                  _selectedSection = section);
                                              unawaited(controller.seek(
                                                  Duration(
                                                      milliseconds:
                                                          section.startMs)));
                                            },
                                            onSplitAt: onSplitSectionAt,
                                            onCreateSectionInGap:
                                                onCreateSectionFromGap,
                                            onAutoAssignSectionColors:
                                                onAutoAssignSectionColors,
                                            onGapTapMs: (milliseconds) {
                                              if (duration == Duration.zero) {
                                                return;
                                              }
                                              _waveformFocus.requestFocus();
                                              onWaveformSeek(
                                                (milliseconds /
                                                        duration.inMilliseconds)
                                                    .clamp(0, 1)
                                                    .toDouble(),
                                              );
                                            },
                                            onSectionResizeStart: () {
                                              onResizeSectionStart();
                                            },
                                            onSectionResizeEnd: () {
                                              onResizeSectionEnd();
                                              if (_sectionResizePreviewMs !=
                                                  null) {
                                                setState(() =>
                                                    _sectionResizePreviewMs =
                                                        null);
                                              }
                                            },
                                            onSectionResizePreviewMs:
                                                (milliseconds) {
                                              if (_sectionResizePreviewMs !=
                                                  milliseconds) {
                                                setState(() =>
                                                    _sectionResizePreviewMs =
                                                        milliseconds);
                                              }
                                              if (milliseconds != null) {
                                                _followWaveformProgress(
                                                  milliseconds /
                                                      duration.inMilliseconds,
                                                  constraints.maxWidth,
                                                  contentWidth,
                                                );
                                              }
                                            },
                                            onHoverProgress: (progress) {
                                              if (_hoverProgress != progress) {
                                                setState(() =>
                                                    _hoverProgress = progress);
                                              }
                                              if (progress != null) {
                                                _followWaveformProgress(
                                                  progress,
                                                  constraints.maxWidth,
                                                  contentWidth,
                                                );
                                              }
                                            },
                                            onSectionResize: onResizeSection,
                                            onMergeSections: onMergeSections,
                                            onSectionEdit: (section) {
                                              setState(() =>
                                                  _selectedSection = section);
                                              onEditSection(section);
                                            },
                                            onSectionAdjust: (section) {
                                              setState(() =>
                                                  _selectedSection = section);
                                              onAdjustSection(section);
                                            },
                                            onSectionDelete: (section) {
                                              setState(() {
                                                if (_selectedSection ==
                                                    section) {
                                                  _selectedSection = null;
                                                }
                                              });
                                              onDeleteSection(section);
                                            },
                                            onDebugLog: widget.onSectionLog,
                                          ),
                                          WaveformView(
                                            peaks: data.peaks,
                                            progress: duration == Duration.zero
                                                ? 0
                                                : position.inMilliseconds /
                                                    duration.inMilliseconds,
                                            rangeStartProgress: (rangeStartMs ??
                                                            sectionStartMs) ==
                                                        null ||
                                                    duration == Duration.zero
                                                ? null
                                                : (rangeStartMs ??
                                                        sectionStartMs!) /
                                                    duration.inMilliseconds,
                                            hoverProgress: _hoverProgress,
                                            hoverTimeLabel: _hoverProgress ==
                                                        null ||
                                                    duration == Duration.zero
                                                ? null
                                                : _format(Duration(
                                                    milliseconds: (_hoverProgress! *
                                                            duration
                                                                .inMilliseconds)
                                                        .round())),
                                            dragProgress:
                                                _sectionResizePreviewMs ==
                                                            null ||
                                                        duration ==
                                                            Duration.zero
                                                    ? null
                                                    : _sectionResizePreviewMs! /
                                                        duration.inMilliseconds,
                                            dragTimeLabel:
                                                _sectionResizePreviewMs == null
                                                    ? null
                                                    : _format(Duration(
                                                        milliseconds:
                                                            _sectionResizePreviewMs!)),
                                            highlightStartProgress:
                                                _hoveredNote == null ||
                                                        duration ==
                                                            Duration.zero
                                                    ? null
                                                    : _hoveredNote!.startMs /
                                                        duration.inMilliseconds,
                                            highlightEndProgress:
                                                _hoveredNote == null ||
                                                        duration ==
                                                            Duration.zero
                                                    ? null
                                                    : (_hoveredNote!.endMs ??
                                                            _hoveredNote!
                                                                .startMs) /
                                                        duration.inMilliseconds,
                                            onSeekProgress: (progress) {
                                              _waveformFocus.requestFocus();
                                              onWaveformSeek(progress);
                                            },
                                            onHoverProgress: (progress) {
                                              if (_hoverProgress != progress) {
                                                setState(() =>
                                                    _hoverProgress = progress);
                                              }
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                              child: Row(children: [
                                IconButton(
                                  tooltip:
                                      controller.isPlaying ? 'Pause' : 'Play',
                                  iconSize: 32,
                                  onPressed: canPlay
                                      ? controller.togglePlayback
                                      : null,
                                  icon: Icon(controller.isPlaying
                                      ? Icons.pause_circle
                                      : Icons.play_circle),
                                ),
                                IconButton(
                                  tooltip: 'Stop',
                                  onPressed: canPlay ? controller.stop : null,
                                  icon: const Icon(Icons.stop_circle_outlined),
                                ),
                                PopupMenuButton<double>(
                                  tooltip:
                                      'Waveform zoom (${_zoomLabel(_waveformZoom)})',
                                  onSelected: (value) =>
                                      setState(() => _waveformZoom = value),
                                  itemBuilder: (context) => const [
                                    PopupMenuItem(
                                        value: 1, child: Text('Zoom 1x')),
                                    PopupMenuItem(
                                        value: 1.5, child: Text('Zoom 1.5x')),
                                    PopupMenuItem(
                                        value: 2, child: Text('Zoom 2x')),
                                    PopupMenuItem(
                                        value: 2.5, child: Text('Zoom 2.5x')),
                                    PopupMenuItem(
                                        value: 3, child: Text('Zoom 3x')),
                                    PopupMenuItem(
                                        value: 3.5, child: Text('Zoom 3.5x')),
                                    PopupMenuItem(
                                        value: 4, child: Text('Zoom 4x')),
                                  ],
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 8),
                                    child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.zoom_in_outlined),
                                          const SizedBox(width: 4),
                                          Text(_zoomLabel(_waveformZoom)),
                                        ]),
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: widget.canUndoSectionEdit
                                      ? widget.onUndoSectionEdit
                                      : null,
                                  icon: const Icon(Icons.undo_outlined),
                                  label: const Text('Undo section'),
                                ),
                                TextButton.icon(
                                  onPressed: sections.isEmpty
                                      ? null
                                      : () => unawaited(
                                          onAutoAssignSectionColors()),
                                  icon: const Icon(Icons.palette_outlined),
                                  label: const Text('Auto colors'),
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
                                    tooltip:
                                        'Delete ${_selectedSection!.label}',
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
                                    icon:
                                        const Icon(Icons.library_add_outlined),
                                  ),
                                const SizedBox(width: 8),
                                Text(
                                    '${_format(position)} / ${_format(duration)}'),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(_waveformFocus.hasFocus
                                      ? '←/→ seek • Space play/pause'
                                      : 'Click waveform to seek'),
                                ),
                              ]),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (controller.recording != null)
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      children: [
                        TextButton.icon(
                          onPressed: () =>
                              onAddAnnotation(controller.recording!),
                          icon: const Icon(Icons.add_comment_outlined),
                          label: const Text('Add point note'),
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
                            PopupMenuItem(
                                value: 12, child: Text('Boost +12 dB')),
                            PopupMenuItem(
                                value: 15, child: Text('Boost +15 dB')),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 8),
                            child:
                                Row(mainAxisSize: MainAxisSize.min, children: [
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
                            child:
                                Row(mainAxisSize: MainAxisSize.min, children: [
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
                                  child:
                                      Text('Export selected section as WAV')),
                              PopupMenuItem(
                                  value: _ExportChoice('mp3', true),
                                  child:
                                      Text('Export selected section as MP3')),
                            ],
                          ],
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 8, vertical: 8),
                            child:
                                Row(mainAxisSize: MainAxisSize.min, children: [
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

  String _zoomLabel(double zoom) =>
      '${zoom == zoom.roundToDouble() ? zoom.toStringAsFixed(0) : zoom.toStringAsFixed(1)}x';
}

class _FingerprintFeatureChartData {
  const _FingerprintFeatureChartData({
    required this.recordingLabel,
    required this.masterRows,
    required this.recordingId,
    required this.generatedAt,
  });

  final String recordingLabel;
  final List<_MasterDeltaRow> masterRows;
  final String recordingId;
  final DateTime generatedAt;
}

class _TuningPracticeInput {
  const _TuningPracticeInput({
    required this.practicePath,
    required this.practiceName,
    required this.acceptedDecisions,
    required this.correctionCount,
  });

  final String practicePath;
  final String practiceName;
  final List<FingerprintDecision> acceptedDecisions;
  final int correctionCount;
}

class _NamedWeightProfile {
  const _NamedWeightProfile({required this.label, required this.profile});

  final String label;
  final Map<String, double> profile;
}

class _ProfileEvaluationSummary {
  const _ProfileEvaluationSummary({
    required this.profile,
    required this.reportsByPractice,
    required this.total,
    required this.exact,
    required this.songCorrect,
    required this.wrong,
    required this.notSuggested,
    required this.missed,
    required this.falsePositiveActionable,
    required this.falsePositiveNonActionable,
    required this.songAccuracy,
    required this.exactAccuracy,
    required this.score,
  });

  final _NamedWeightProfile profile;
  final Map<String, FingerprintEvaluationReport> reportsByPractice;
  final int total;
  final int exact;
  final int songCorrect;
  final int wrong;
  final int notSuggested;
  final int missed;
  final int falsePositiveActionable;
  final int falsePositiveNonActionable;
  final double songAccuracy;
  final double exactAccuracy;
  final double score;

  String logLine() =>
      '${profile.label}: score=${score.toStringAsFixed(2)}, total=$total, exact=$exact, songCorrect=$songCorrect, wrong=$wrong, notSuggested=$notSuggested, missed=$missed, fpA=$falsePositiveActionable, fpN=$falsePositiveNonActionable, songAcc=${(songAccuracy * 100).toStringAsFixed(1)}%, exactAcc=${(exactAccuracy * 100).toStringAsFixed(1)}%';
}

class _FingerprintTuningOutcome {
  const _FingerprintTuningOutcome({
    required this.generatedAt,
    required this.baseline,
    required this.recommended,
    required this.allSummaries,
    required this.noRegressionCount,
  });

  final DateTime generatedAt;
  final _ProfileEvaluationSummary baseline;
  final _ProfileEvaluationSummary recommended;
  final List<_ProfileEvaluationSummary> allSummaries;
  final int noRegressionCount;
}

class _MasterDeltaRow {
  const _MasterDeltaRow({
    required this.masterLabel,
    required this.masterFilename,
    required this.featureDeltasByGroup,
    this.featureDeltas = const <double>[],
    this.totalWeightedDelta = 0,
    this.confidence = 0,
  });

  final String masterLabel;
  final String masterFilename;
  final Map<String, double> featureDeltasByGroup;
  final List<double> featureDeltas;
  final double totalWeightedDelta;
  final double confidence;

  _MasterDeltaRow withComputedValues({
    required List<String> columns,
    required Map<String, double> weightProfile,
  }) {
    final deltas =
        columns.map((column) => featureDeltasByGroup[column] ?? 0).toList();
    var total = 0.0;
    for (final entry in featureDeltasByGroup.entries) {
      total += entry.value * (weightProfile[entry.key] ?? 0);
    }
    final totalWeight = featureDeltasByGroup.keys
        .map((key) => weightProfile[key] ?? 0)
        .fold(0.0, (sum, item) => sum + item);
    final normalizedDelta = totalWeight <= 0
        ? 1.0
        : (total / totalWeight).clamp(0.0, 1.0).toDouble();
    return _MasterDeltaRow(
      masterLabel: masterLabel,
      masterFilename: masterFilename,
      featureDeltasByGroup: featureDeltasByGroup,
      featureDeltas: deltas,
      totalWeightedDelta: total,
      confidence: (1.0 - normalizedDelta).clamp(0.0, 1.0).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'masterLabel': masterLabel,
        'masterFilename': masterFilename,
        'featureDeltas': featureDeltas,
        'confidence': confidence,
        'totalWeightedDelta': totalWeightedDelta,
      };
}

class _MasterFeatureSnapshot {
  const _MasterFeatureSnapshot({
    required this.recording,
    required this.fingerprint,
  });

  final Recording recording;
  final AudioFingerprint fingerprint;
}

class _GoogleDriveFolderBrowser extends StatefulWidget {
  const _GoogleDriveFolderBrowser({required this.connection});

  final GoogleDriveConnection connection;

  @override
  State<_GoogleDriveFolderBrowser> createState() =>
      _GoogleDriveFolderBrowserState();
}

class _GoogleDriveFolderBrowserState extends State<_GoogleDriveFolderBrowser> {
  GoogleDriveFolder _current =
      const GoogleDriveFolder(id: 'root', name: 'My Drive');
  final List<GoogleDriveFolder> _backStack = [];
  List<GoogleDriveFolder> _folders = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCurrentFolder();
  }

  Future<void> _loadCurrentFolder() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final folders =
          await widget.connection.listFolders(parentId: _current.id);
      if (!mounted) return;
      setState(() {
        _folders = folders;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _folders = const [];
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _openFolder(GoogleDriveFolder folder) async {
    _backStack.add(_current);
    _current = folder;
    await _loadCurrentFolder();
  }

  Future<void> _goBack() async {
    if (_backStack.isEmpty) return;
    _current = _backStack.removeLast();
    await _loadCurrentFolder();
  }

  Future<void> _createRiffNotesFolder() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final created = await widget.connection.createFolder(
        name: 'RiffNotes',
        parentId: _current.id,
      );
      if (!mounted) return;
      Navigator.pop(context, created);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Choose Google Drive folder'),
        content: SizedBox(
          width: 640,
          height: 480,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                IconButton(
                  tooltip: 'Back',
                  onPressed: _backStack.isEmpty || _loading ? null : _goBack,
                  icon: const Icon(Icons.arrow_back),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.folder_open_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _current.name,
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
              const Divider(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _CopyableErrorMessage(message: _error!),
                ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _folders.isEmpty
                        ? const Center(
                            child: Text('No folders inside this folder.'))
                        : ListView.builder(
                            itemCount: _folders.length,
                            itemBuilder: (context, index) {
                              final folder = _folders[index];
                              return ListTile(
                                leading: const Icon(Icons.folder_outlined),
                                title: Text(folder.name),
                                subtitle: Text(folder.id),
                                onTap: () => _openFolder(folder),
                                trailing: const Icon(Icons.chevron_right),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: _loading ? null : () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton.icon(
            onPressed: _loading ? null : _createRiffNotesFolder,
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('Create RiffNotes here'),
          ),
          FilledButton.icon(
            onPressed: _loading ? null : () => Navigator.pop(context, _current),
            icon: const Icon(Icons.check),
            label: const Text('Use this folder'),
          ),
        ],
      );
}

class _CopyableErrorMessage extends StatelessWidget {
  const _CopyableErrorMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer.withOpacity(.18),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: Theme.of(context).colorScheme.error.withOpacity(.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline,
                size: 18, color: Theme.of(context).colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Copy error',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: message));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Error copied to clipboard')),
                  );
                }
              },
              icon: const Icon(Icons.copy_outlined),
            ),
          ],
        ),
      );
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
                width: 160,
                child: LinearProgressIndicator(value: item.progress)),
            const SizedBox(width: 8),
            IconButton(
              tooltip: item.detail.trim().isEmpty
                  ? 'Nothing to copy yet'
                  : 'Copy message',
              onPressed: item.detail.trim().isEmpty
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: item.detail));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Message copied to clipboard')),
                        );
                      }
                    },
              icon: const Icon(Icons.copy_outlined),
            ),
          ],
        ),
      ),
    );
  }
}
