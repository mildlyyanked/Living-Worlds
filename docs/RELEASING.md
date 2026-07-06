# Releasing Living Worlds to the Play Store (internal testing)

Goal: push a git tag (or click "Run workflow"), and a minute later your phone
pulls the new build from the Play Store like any app update. No cables, no
sideloading. The pipeline lives in
[`.github/workflows/release-android.yml`](../.github/workflows/release-android.yml).

The workflow works in three tiers depending on which secrets exist, so you
can use it *today* and upgrade it as you finish the Google setup:

| Secrets configured | What you get |
|---|---|
| none | Debug-signed AAB + APK attached to the workflow run (download the APK from the run page to sideload — interim option) |
| keystore secrets | Release-signed artifacts |
| keystore + Play service account | Automatic upload to the Play internal-testing track |

---

## Step 1 — Google Play Console account (one time, ~15 min + review wait)

1. Go to https://play.google.com/console/signup
2. Sign in with the Google account you want to own the app, choose
   **personal developer account**, and pay the **one-time $25 fee**.
3. Google requires identity verification (ID + sometimes a D-U-N-S for
   organizations; personal accounts just need ID). Verification usually
   clears within a couple of days.
   - Note for new personal accounts: Google requires a **closed test with
     at least 12 testers for 14 days before you can go to production**.
     This does NOT block internal testing — the internal track is exactly
     what we're using, available immediately, up to 100 testers.

## Step 2 — Create the app + first manual upload (one time)

The very first bundle must be uploaded through the Console UI (the API can
only upload to apps that already have a build).

1. Play Console → **Create app** → name "Living Worlds", type App, free.
2. Fill the minimum "App content" declarations it nags about (privacy
   policy can be a placeholder page for internal testing).
3. Get a signed AAB to upload:
   - Do Step 3 (keystore) first, add the keystore secrets, run the
     workflow, and download `app-release.aab` from the run artifacts — or
     build locally with the same `key.properties`.
4. **Testing → Internal testing → Create new release** → upload the AAB.
   - When asked, opt into **Play App Signing** (recommended): Google holds
     the app signing key; your keystore becomes the *upload key*, which is
     replaceable if lost.
5. Still in Internal testing → **Testers** tab → create an email list with
   your own Gmail → save → copy the **"Join on the web" opt-in link** and
   open it on your phone → accept. From then on the app appears in the
   Play Store app on that phone, and every new internal release lands as a
   normal update (usually within a few minutes).

## Step 3 — Upload keystore (one time, on your machine)

```bash
keytool -genkey -v -keystore upload-keystore.jks -storetype JKS \
  -keyalg RSA -keysize 2048 -validity 10950 -alias upload
```

Keep `upload-keystore.jks` and the passwords somewhere safe (password
manager). Then add these **GitHub repo secrets**
(Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 upload-keystore.jks` output |
| `ANDROID_KEYSTORE_PASSWORD` | the store password |
| `ANDROID_KEY_ALIAS` | `upload` |
| `ANDROID_KEY_PASSWORD` | the key password |

(For local release builds, put the jks at `app/android/upload-keystore.jks`
and create `app/android/key.properties` with the same four values —
both paths are gitignored.)

## Step 4 — Service account so CI can talk to Play (one time)

1. https://console.cloud.google.com → create a project (any name).
2. **APIs & Services → Enable APIs** → enable **Google Play Android
   Developer API**.
3. **IAM & Admin → Service accounts → Create** → name it
   `play-publisher`, no roles needed at the project level.
4. On the new service account → **Keys → Add key → JSON** → download it.
5. Back in **Play Console → Users and permissions → Invite new users** →
   invite the service account's email → grant it access to the Living
   Worlds app with the **"Release to testing tracks"** permissions.
6. Add the whole JSON file's contents as the repo secret
   `PLAY_SERVICE_ACCOUNT_JSON`.

## Step 5 — Ship

```bash
git tag v0.1.0 && git push origin v0.1.0
```

or Actions → "Release — Android (Play internal testing)" → Run workflow.
The workflow runs both test suites first (a failing suite blocks the
release), builds the AAB with an auto-incrementing `versionCode`
(= workflow run number), and uploads to the internal track. Your phone
updates itself.

## iOS later

TestFlight is the equivalent loop ($99/yr Apple Developer Program + a Mac
for the first archive). The Flutter project is already iOS-ready; wiring a
`release-ios.yml` with fastlane + App Store Connect API keys is a
follow-up when you want it.
