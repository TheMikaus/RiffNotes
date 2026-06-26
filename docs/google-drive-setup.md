# Google Drive setup

RiffNotes can connect directly to Google Drive through Google's OAuth flow. This is separate from the older local-folder sync path that points at a mounted Google Drive folder.

RiffNotes should not ask every bandmate to create a Google Cloud OAuth client. The intended distribution model is:

1. The app maintainer creates one OAuth client for RiffNotes.
2. The app build bundles that client configuration.
3. Each user only clicks `Connect` and signs into Google in the system browser.

Google does not allow the OAuth consent flow to run inside a normal embedded webview/user-agent. Desktop apps should open the system browser and receive the result through a local loopback redirect.

## Current status

Implemented in the app:

- Load a bundled Google OAuth desktop client from `assets/google_oauth.json`.
- Keep a manual OAuth override in Preferences for development/testing builds.
- Open the browser for Google sign-in.
- Store refresh credentials locally for later sessions.
- Browse top-level Google Drive folders.
- Create a `RiffNotes` folder in My Drive.
- Remember the selected remote Drive root folder.

Still to build:

- Upload/download selected practice folders through the Drive API.
- Conflict preview and overwrite protection for remote sync.
- Move stored credentials into OS-protected credential storage.

## Create the app OAuth client

This is a maintainer/release step, not something each user should do.

1. Go to the Google Cloud Console.
2. Create or choose a project.
3. Enable the Google Drive API.
4. Configure the OAuth consent screen for the project.
5. Create an OAuth 2.0 Client ID.
6. Choose `Desktop app` as the application type.
7. Copy the generated client ID and client secret.
8. Put them in `assets/google_oauth.json` before building the release:

```json
{
  "client_id": "YOUR_CLIENT_ID.apps.googleusercontent.com",
  "client_secret": "YOUR_CLIENT_SECRET"
}
```

Installed desktop apps cannot truly keep a client secret secret, so the app still treats this as public app configuration rather than a user password.

## Connect in RiffNotes

1. Open RiffNotes.
2. Open Preferences.
3. Under `Google Drive account`, click `Connect`.
4. Complete Google sign-in in the browser.
5. Under `Google Drive remote root`, click `Browse`.
6. Choose an existing folder or click `Create RiffNotes`.

For development builds without a bundled OAuth client, use `Add OAuth` in Preferences to paste a temporary desktop client ID/secret.

If the browser ends on a raw `localhost` or `127.0.0.1` URL instead of a friendly RiffNotes success page, the local callback was not captured. Return to RiffNotes and click `Connect` again; authorization codes in those URLs are short-lived and should not be shared.

## Security note

This development slice stores OAuth settings and refresh credentials in app preferences. That is acceptable for early testing, but V1 should move refresh credentials into OS-protected credential storage.
