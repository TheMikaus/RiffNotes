import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'activity.dart';
import 'package:flutter/services.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/auth_io.dart';
import 'package:googleapis_auth/src/oauth2_flows/auth_code.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';

typedef DriveDebugLog = void Function(String message);

class GoogleDriveSyncRepository {
  static const scopes = [drive.DriveApi.driveScope];

  GoogleDriveSyncRepository();

  Future<GoogleDriveConnection> connect({
    required String clientId,
    String? clientSecret,
    String? savedCredentialsJson,
  }) async {
    final googleClientId = ClientId(clientId, clientSecret);
    final baseClient = http.Client();
    AutoRefreshingAuthClient authClient;
    try {
      if (savedCredentialsJson != null) {
        final credentials =
            AccessCredentials.fromJson(jsonDecode(savedCredentialsJson));
        authClient = autoRefreshingClient(
          googleClientId,
          credentials,
          baseClient,
        );
      } else {
        authClient = await _clientViaRiffNotesBrowserFlow(
          googleClientId,
          scopes: scopes,
          baseClient: baseClient,
        );
      }
    } catch (_) {
      baseClient.close();
      rethrow;
    }
    return GoogleDriveConnection(authClient);
  }

  Future<AutoRefreshingAuthClient> _clientViaRiffNotesBrowserFlow(
    ClientId clientId, {
    required List<String> scopes,
    required http.Client baseClient,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://127.0.0.1:${server.port}/';
    final state = randomState();
    final codeVerifier = createCodeVerifier();
    final authUri = createAuthenticationUri(
      redirectUri: redirectUri,
      clientId: clientId.identifier,
      scopes: scopes,
      codeVerifier: codeVerifier,
      state: state,
      offline: true,
    );
    final uri = authUri.replace(queryParameters: {
      ...authUri.queryParameters,
      'prompt': 'consent',
    });

    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await server.close(force: true);
      throw StateError('Could not open Google sign-in in a browser.');
    }

    try {
      final request = await server.first.timeout(const Duration(minutes: 5));
      try {
        final callbackUri = request.uri;
        if (request.method != 'GET') {
          throw StateError('Google sign-in returned an unexpected response.');
        }
        final returnedState = callbackUri.queryParameters['state'];
        if (returnedState != state) {
          throw StateError('Google sign-in state did not match.');
        }
        final error = callbackUri.queryParameters['error'];
        if (error != null) {
          throw StateError('Google sign-in failed: $error');
        }
        final code = callbackUri.queryParameters['code'];
        if (code == null || code.isEmpty) {
          throw StateError('Google sign-in did not return an auth code.');
        }
        final credentials = await obtainAccessCredentialsViaCodeExchange(
          baseClient,
          clientId,
          code,
          redirectUrl: redirectUri,
          codeVerifier: codeVerifier,
        );
        request.response
          ..statusCode = 200
          ..headers.set('content-type', 'text/html; charset=UTF-8')
          ..write(_successPage);
        await request.response.close();
        return autoRefreshingClient(clientId, credentials, baseClient);
      } catch (error) {
        request.response
          ..statusCode = 200
          ..headers.set('content-type', 'text/html; charset=UTF-8')
          ..write(_errorPage(error));
        await request.response.close().catchError((_) {});
        rethrow;
      }
    } on TimeoutException {
      throw StateError('Google sign-in timed out.');
    } finally {
      await server.close(force: true);
    }
  }

  static const _successPage = '''
<!DOCTYPE html>
<html>
  <head><meta charset="utf-8"><title>RiffNotes connected</title></head>
  <body style="font-family: sans-serif; margin: 3rem;">
    <h1>RiffNotes is connected.</h1>
    <p>You can close this tab and return to the app.</p>
  </body>
</html>
''';

  static String _errorPage(Object error) => '''
<!DOCTYPE html>
<html>
  <head><meta charset="utf-8"><title>RiffNotes connection failed</title></head>
  <body style="font-family: sans-serif; margin: 3rem;">
    <h1>RiffNotes could not finish Google sign-in.</h1>
    <p>$error</p>
    <p>Return to RiffNotes and try Connect again.</p>
  </body>
</html>
''';
}

class GoogleDriveOAuthConfig {
  const GoogleDriveOAuthConfig({required this.clientId, this.clientSecret});

  final String clientId;
  final String? clientSecret;

  bool get isConfigured => clientId.trim().isNotEmpty;

  static Future<GoogleDriveOAuthConfig?> loadBundled() async {
    try {
      final content = await rootBundle.loadString('assets/google_oauth.json');
      return fromJsonContent(content);
    } catch (_) {
      return null;
    }
  }

  static GoogleDriveOAuthConfig? fromJsonContent(String content) {
    final json = jsonDecode(content) as Map<String, dynamic>;
    final section = _oauthSection(json);
    final clientId = (section['client_id'] as String? ?? '').trim();
    final clientSecret = (section['client_secret'] as String? ?? '').trim();
    if (clientId.isEmpty) return null;
    return GoogleDriveOAuthConfig(
      clientId: clientId,
      clientSecret: clientSecret.isEmpty ? null : clientSecret,
    );
  }

  static Map<String, dynamic> _oauthSection(Map<String, dynamic> json) {
    final installed = json['installed'];
    if (installed is Map<String, dynamic>) return installed;
    final web = json['web'];
    if (web is Map<String, dynamic>) return web;
    return json;
  }
}

class GoogleDriveConnection {
  GoogleDriveConnection(this._client) : _api = drive.DriveApi(_client);

  final AutoRefreshingAuthClient _client;
  final drive.DriveApi _api;

  String get credentialsJson => jsonEncode(_client.credentials.toJson());

  Stream<AccessCredentials> get credentialUpdates => _client.credentialUpdates;

  Future<List<GoogleDriveFolder>> listFolders({
    String parentId = 'root',
  }) async {
    final escapedParent = parentId.replaceAll("'", r"\'");
    final response = await _api.files.list(
      q: "'$escapedParent' in parents and "
          "mimeType = 'application/vnd.google-apps.folder' and trashed = false",
      orderBy: 'folder,name_natural',
      pageSize: 100,
      spaces: 'drive',
      $fields: 'files(id,name,parents),nextPageToken',
    );
    return (response.files ?? const <drive.File>[])
        .where((item) => item.id != null && item.name != null)
        .map((item) => GoogleDriveFolder(id: item.id!, name: item.name!))
        .toList(growable: false);
  }

  Future<GoogleDriveFolder> getFolder(String folderId) async {
    final item = await _api.files.get(
      folderId,
      $fields: 'id,name',
    ) as drive.File;
    if (item.id == null || item.name == null) {
      throw StateError('Google Drive folder was not found.');
    }
    return GoogleDriveFolder(id: item.id!, name: item.name!);
  }

  Future<GoogleDriveFolder> createFolder({
    required String name,
    String parentId = 'root',
  }) async {
    final folder = await _api.files.create(
      drive.File()
        ..name = name
        ..mimeType = 'application/vnd.google-apps.folder'
        ..parents = [parentId],
      $fields: 'id,name',
    );
    if (folder.id == null || folder.name == null) {
      throw StateError('Google Drive did not return the created folder.');
    }
    return GoogleDriveFolder(id: folder.id!, name: folder.name!);
  }

  Future<GoogleDriveSyncResult> uploadLocalFolder({
    required Directory localFolder,
    required String driveRootFolderId,
    bool changedOnly = true,
    bool deleteMissingFiles = false,
    bool includeLocalRootFolder = true,
    bool Function()? shouldCancel,
    void Function(String message)? statusUpdate,
    Set<String>? allowedRelativePaths,
    DriveDebugLog? debugLog,
  }) async {
    if (!await localFolder.exists()) {
      throw StateError('Local folder was not found.');
    }

    final normalizedAllowed =
        allowedRelativePaths?.map((item) => item.replaceAll('\\', '/')).toSet();
    final practiceFolderId = includeLocalRootFolder
        ? await _ensureChildFolder(
            parentId: driveRootFolderId,
            folderName: path.basename(localFolder.path),
          )
        : driveRootFolderId;
    final folderCache = <String, String>{'': practiceFolderId};

    final remoteFiles = await _listFilesRecursive(practiceFolderId);
    final remoteByRelative = {
      for (final item in remoteFiles) item.relativePath: item,
    };

    var copied = 0;
    var skipped = 0;
    var deleted = 0;
    final expected = <String>{};
    var scannedFiles = 0;
    var skippedFiltered = 0;
    var skippedUnselected = 0;
    var skippedUnchanged = 0;
    final unchangedSamples = <String>[];
    debugLog?.call(
      'sync.drive.upload start local="${localFolder.path}" driveRootId="$driveRootFolderId" '
      'practiceFolderId="$practiceFolderId" changedOnly=$changedOnly '
      'deleteMissingFiles=$deleteMissingFiles selection=${normalizedAllowed?.length ?? 'all'} '
      'remoteFiles=${remoteFiles.length}',
    );
    statusUpdate?.call('Scanning Google Drive upload source…');

    await for (final entity in localFolder.list(recursive: true)) {
      if (shouldCancel?.call() ?? false) {
        throw const ActivityCancelledException();
      }
      if (entity is! File) continue;
      scannedFiles += 1;
      final relative = path
          .relative(entity.path, from: localFolder.path)
          .replaceAll('\\', '/');
      if (_shouldSkip(relative)) {
        skipped += 1;
        skippedFiltered += 1;
        continue;
      }
      if (normalizedAllowed != null && !normalizedAllowed.contains(relative)) {
        skippedUnselected += 1;
        continue;
      }
      expected.add(relative);

      final remote = remoteByRelative[relative];
      statusUpdate?.call('Uploading $relative…');
      if (changedOnly && remote != null && await _sameFile(remote, entity)) {
        skipped += 1;
        skippedUnchanged += 1;
        if (unchangedSamples.length < 5) {
          unchangedSamples.add(relative);
        }
        continue;
      }

      final folderRelative = path.dirname(relative).replaceAll('\\', '/');
      final parentFolderId = await _ensureDriveFolderPath(
          folderRelative, practiceFolderId, folderCache);
      final name = path.basename(relative);
      final media = drive.Media(entity.openRead(), await entity.length());
      if (remote == null) {
        await _api.files.create(
          drive.File()
            ..name = name
            ..parents = [parentFolderId],
          uploadMedia: media,
          $fields: 'id',
        );
      } else {
        await _api.files.update(
          drive.File(),
          remote.id,
          uploadMedia: media,
          $fields: 'id',
        );
      }
      copied += 1;
    }

    if (deleteMissingFiles) {
      statusUpdate?.call('Removing remote files missing locally…');
      for (final item in remoteFiles) {
        if (shouldCancel?.call() ?? false) {
          throw const ActivityCancelledException();
        }
        if (_shouldSkip(item.relativePath)) continue;
        if (expected.contains(item.relativePath)) continue;
        await _api.files.delete(item.id);
        deleted += 1;
      }
    }

    debugLog?.call(
      'sync.drive.upload done scanned=$scannedFiles copied=$copied skipped=$skipped '
      'deleted=$deleted skipFiltered=$skippedFiltered '
      'skipUnselected=$skippedUnselected skipUnchanged=$skippedUnchanged '
      'expected=${expected.length}',
    );
    if (unchangedSamples.isNotEmpty) {
      debugLog?.call(
        'sync.drive.upload unchanged samples: ${unchangedSamples.join(', ')}',
      );
    }

    return GoogleDriveSyncResult(
      copiedFiles: copied,
      skippedItems: skipped,
      deletedFiles: deleted,
    );
  }

  Future<GoogleDriveSyncResult> downloadFolderToLocal({
    required Directory localFolder,
    required String driveRootFolderId,
    bool changedOnly = true,
    bool deleteMissingFiles = false,
    bool includeLocalRootFolder = true,
    bool Function()? shouldCancel,
    void Function(String message)? statusUpdate,
    DriveDebugLog? debugLog,
  }) async {
    final practiceFolderId = includeLocalRootFolder
        ? await _findChildFolder(
            parentId: driveRootFolderId,
            name: path.basename(localFolder.path),
          )
        : driveRootFolderId;
    if (practiceFolderId == null) {
      throw StateError('No matching practice folder exists in Google Drive.');
    }

    await localFolder.create(recursive: true);
    final remoteFiles = await _listFilesRecursive(practiceFolderId);
    final expected = <String>{};
    var copied = 0;
    var skipped = 0;
    var deleted = 0;
    var skippedFiltered = 0;
    var skippedUnchanged = 0;
    final unchangedSamples = <String>[];
    debugLog?.call(
      'sync.drive.download start driveRootId="$driveRootFolderId" '
      'practiceFolderId="$practiceFolderId" local="${localFolder.path}" '
      'changedOnly=$changedOnly deleteMissingFiles=$deleteMissingFiles '
      'remoteFiles=${remoteFiles.length}',
    );
    statusUpdate?.call('Scanning Google Drive download source…');

    for (final remote in remoteFiles) {
      if (shouldCancel?.call() ?? false) {
        throw const ActivityCancelledException();
      }
      final relative = remote.relativePath;
      if (_shouldSkip(relative)) {
        skipped += 1;
        skippedFiltered += 1;
        continue;
      }
      expected.add(relative);
      final destination = File(path.join(localFolder.path, relative));
      statusUpdate?.call('Downloading $relative…');
      if (changedOnly && await _sameRemoteAsLocal(remote, destination)) {
        skipped += 1;
        skippedUnchanged += 1;
        if (unchangedSamples.length < 5) {
          unchangedSamples.add(relative);
        }
        continue;
      }
      await destination.parent.create(recursive: true);
      final media = await _api.files.get(
        remote.id,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;
      final sink = destination.openWrite();
      await sink.addStream(media.stream);
      await sink.close();
      if (remote.modifiedTime != null) {
        await destination.setLastModified(remote.modifiedTime!.toUtc());
      }
      copied += 1;
    }

    if (deleteMissingFiles) {
      statusUpdate?.call('Removing local files missing from Drive…');
      await for (final entity in localFolder.list(recursive: true)) {
        if (shouldCancel?.call() ?? false) {
          throw const ActivityCancelledException();
        }
        if (entity is! File) continue;
        final relative = path
            .relative(entity.path, from: localFolder.path)
            .replaceAll('\\', '/');
        if (_shouldSkip(relative)) continue;
        if (expected.contains(relative)) continue;
        await entity.delete();
        deleted += 1;
      }
    }

    debugLog?.call(
      'sync.drive.download done copied=$copied skipped=$skipped deleted=$deleted '
      'skipFiltered=$skippedFiltered skipUnchanged=$skippedUnchanged '
      'expected=${expected.length}',
    );
    if (unchangedSamples.isNotEmpty) {
      debugLog?.call(
        'sync.drive.download unchanged samples: ${unchangedSamples.join(', ')}',
      );
    }

    return GoogleDriveSyncResult(
      copiedFiles: copied,
      skippedItems: skipped,
      deletedFiles: deleted,
    );
  }

  Future<List<_DriveFileEntry>> _listFilesRecursive(String folderId,
      {String prefix = ''}) async {
    final entries = <_DriveFileEntry>[];
    final children = await _listChildren(folderId);
    for (final child in children) {
      final name = child.name;
      final id = child.id;
      if (name == null || id == null) continue;
      if (child.mimeType == 'application/vnd.google-apps.folder') {
        final nextPrefix = prefix.isEmpty ? name : '$prefix/$name';
        entries.addAll(await _listFilesRecursive(id, prefix: nextPrefix));
        continue;
      }
      final relative = prefix.isEmpty ? name : '$prefix/$name';
      entries.add(_DriveFileEntry(
        id: id,
        relativePath: relative,
        sizeBytes: int.tryParse(child.size ?? ''),
        modifiedTime: child.modifiedTime,
      ));
    }
    return entries;
  }

  Future<List<drive.File>> _listChildren(String parentId) async {
    final escapedParent = parentId.replaceAll("'", r"\'");
    final files = <drive.File>[];
    String? pageToken;
    do {
      final response = await _api.files.list(
        q: "'$escapedParent' in parents and trashed = false",
        orderBy: 'folder,name_natural',
        pageSize: 1000,
        spaces: 'drive',
        pageToken: pageToken,
        $fields: 'nextPageToken,files(id,name,mimeType,size,modifiedTime)',
      );
      files.addAll(response.files ?? const <drive.File>[]);
      pageToken = response.nextPageToken;
    } while (pageToken != null && pageToken.isNotEmpty);
    return files;
  }

  Future<String> _ensureDriveFolderPath(
    String folderRelative,
    String rootFolderId,
    Map<String, String> cache,
  ) async {
    if (folderRelative == '.' || folderRelative.isEmpty) {
      return rootFolderId;
    }
    final normalized = folderRelative.replaceAll('\\', '/');
    if (cache.containsKey(normalized)) return cache[normalized]!;

    final segments = normalized.split('/').where((item) => item.isNotEmpty);
    var currentId = rootFolderId;
    var currentPath = '';
    for (final segment in segments) {
      currentPath = currentPath.isEmpty ? segment : '$currentPath/$segment';
      final existing = cache[currentPath];
      if (existing != null) {
        currentId = existing;
        continue;
      }
      final folderId =
          await _ensureChildFolder(parentId: currentId, folderName: segment);
      cache[currentPath] = folderId;
      currentId = folderId;
    }
    return currentId;
  }

  Future<String?> _findChildFolder({
    required String parentId,
    required String name,
  }) async {
    final escapedParent = parentId.replaceAll("'", r"\'");
    final escapedName = name.replaceAll("'", r"\'");
    final response = await _api.files.list(
      q: "'$escapedParent' in parents and "
          "mimeType = 'application/vnd.google-apps.folder' and "
          "name = '$escapedName' and trashed = false",
      pageSize: 1,
      spaces: 'drive',
      $fields: 'files(id)',
    );
    return response.files?.firstOrNull?.id;
  }

  Future<String> _ensureChildFolder({
    required String parentId,
    required String folderName,
  }) async {
    final existingId =
        await _findChildFolder(parentId: parentId, name: folderName);
    if (existingId != null) return existingId;
    final created = await _api.files.create(
      drive.File()
        ..name = folderName
        ..mimeType = 'application/vnd.google-apps.folder'
        ..parents = [parentId],
      $fields: 'id',
    );
    final id = created.id;
    if (id == null || id.isEmpty) {
      throw StateError('Google Drive did not return a folder id.');
    }
    return id;
  }

  Future<bool> _sameFile(_DriveFileEntry remote, File local) async {
    if (!await local.exists()) return false;
    final localStat = await local.stat();
    if (remote.sizeBytes != null && localStat.size != remote.sizeBytes) {
      return false;
    }
    if (remote.modifiedTime == null) return false;
    return localStat.modified.toUtc() == remote.modifiedTime!.toUtc();
  }

  Future<bool> _sameRemoteAsLocal(_DriveFileEntry remote, File local) async {
    if (!await local.exists()) return false;
    final localStat = await local.stat();
    if (remote.sizeBytes != null && localStat.size != remote.sizeBytes) {
      return false;
    }
    if (remote.modifiedTime == null) return false;
    return localStat.modified.toUtc() == remote.modifiedTime!.toUtc();
  }

  bool _shouldSkip(String relativePath) {
    final parts = path.split(relativePath).map((item) => item.toLowerCase());
    return parts.any((part) =>
        part == '.riffnotes-cache' ||
        part == '.backup' ||
        part == 'cache' ||
        part.endsWith('.tmp'));
  }

  void close() => _client.close();
}

class GoogleDriveFolder {
  const GoogleDriveFolder({required this.id, required this.name});

  final String id;
  final String name;
}

class GoogleDriveSyncResult {
  const GoogleDriveSyncResult({
    required this.copiedFiles,
    required this.skippedItems,
    this.deletedFiles = 0,
  });

  final int copiedFiles;
  final int skippedItems;
  final int deletedFiles;
}

class _DriveFileEntry {
  const _DriveFileEntry({
    required this.id,
    required this.relativePath,
    required this.sizeBytes,
    required this.modifiedTime,
  });

  final String id;
  final String relativePath;
  final int? sizeBytes;
  final DateTime? modifiedTime;
}
