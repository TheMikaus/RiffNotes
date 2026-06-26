import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class GoogleDriveSyncRepository {
  static const scopes = [drive.DriveApi.driveScope];

  GoogleDriveSyncRepository({http.Client? baseClient})
      : _baseClient = baseClient ?? http.Client();

  final http.Client _baseClient;

  Future<GoogleDriveConnection> connect({
    required String clientId,
    String? clientSecret,
    String? savedCredentialsJson,
  }) async {
    final googleClientId = ClientId(clientId, clientSecret);
    AutoRefreshingAuthClient authClient;
    if (savedCredentialsJson != null) {
      final credentials =
          AccessCredentials.fromJson(jsonDecode(savedCredentialsJson));
      authClient = autoRefreshingClient(
        googleClientId,
        credentials,
        _baseClient,
      );
    } else {
      authClient = await clientViaUserConsent(
        googleClientId,
        scopes,
        (url) async {
          final uri = Uri.parse(url);
          if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
            throw StateError('Could not open Google sign-in in a browser.');
          }
        },
        baseClient: _baseClient,
        customPostAuthPage:
            '<html><body><h1>RiffNotes is connected.</h1><p>You can close this tab and return to the app.</p></body></html>',
      );
    }
    return GoogleDriveConnection(authClient);
  }
}

class GoogleDriveOAuthConfig {
  const GoogleDriveOAuthConfig({required this.clientId, this.clientSecret});

  final String clientId;
  final String? clientSecret;

  bool get isConfigured => clientId.trim().isNotEmpty;

  static Future<GoogleDriveOAuthConfig?> loadBundled() async {
    try {
      final content = await rootBundle.loadString('assets/google_oauth.json');
      final json = jsonDecode(content) as Map<String, dynamic>;
      final clientId = (json['client_id'] as String? ?? '').trim();
      final clientSecret = (json['client_secret'] as String? ?? '').trim();
      if (clientId.isEmpty) return null;
      return GoogleDriveOAuthConfig(
        clientId: clientId,
        clientSecret: clientSecret.isEmpty ? null : clientSecret,
      );
    } catch (_) {
      return null;
    }
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

  void close() => _client.close();
}

class GoogleDriveFolder {
  const GoogleDriveFolder({required this.id, required this.name});

  final String id;
  final String name;
}
