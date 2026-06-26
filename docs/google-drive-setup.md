# Google Drive setup

RiffNotes can connect directly to Google Drive through Google's OAuth flow. This is separate from the older local-folder sync path that points at a mounted Google Drive folder.

## Current status

Implemented in the app:

- Save a Google OAuth desktop client ID and client secret.
- Open the browser for Google sign-in.
- Store refresh credentials locally for later sessions.
- Browse top-level Google Drive folders.
- Create a `RiffNotes` folder in My Drive.
- Remember the selected remote Drive root folder.

Still to build:

- Upload/download selected practice folders through the Drive API.
- Conflict preview and overwrite protection for remote sync.
- Move stored credentials into OS-protected credential storage.

## Create the OAuth client

1. Go to the Google Cloud Console.
2. Create or choose a project.
3. Enable the Google Drive API.
4. Configure the OAuth consent screen for the project.
5. Create an OAuth 2.0 Client ID.
6. Choose `Desktop app` as the application type.
7. Copy the generated client ID and client secret.

## Connect in RiffNotes

1. Open RiffNotes.
2. Open Preferences.
3. Under `Google Drive account`, click `Add OAuth`.
4. Paste the desktop client ID and client secret.
5. Click `Connect`.
6. Complete Google sign-in in the browser.
7. Under `Google Drive remote root`, click `Browse`.
8. Choose an existing folder or click `Create RiffNotes`.

## Security note

This development slice stores OAuth settings and refresh credentials in app preferences. That is acceptable for early testing, but V1 should move refresh credentials and client secrets into OS-protected credential storage.
