# Jenkins + Flutter + Unity CI/CD Boilerplate

A production-ready Jenkins CI/CD setup for Flutter apps that embed a Unity project
as a native Android library using `flutter_embed_unity`.

---

## Architecture

```
  Unity Repo (separate git)
       |
       | (git clone / lfs pull, incremental fetch)
       v
  +--------------------------------------------------+
  |  Jenkinsfile.unity-export                        |
  |  Agent: unity (Windows physical machine)         |
  |                                                  |
  |  1. Checkout Flutter repo (scm)                  |
  |  2. Sync Unity repo (LFS-aware, incremental)     |
  |  3. SHA check -> skip if unchanged               |
  |  4. Unity lockfile guard (stale >3600s removed)  |
  |  5. Unity.exe -batchmode HeadlessExporter        |
  |  6. Verify build.gradle + keepUnitySymbols patch |
  |  7. Archive unityLibrary.zip (robocopy)          |
  |  8. git commit android/unityLibrary -> Flutter   |
  |  9. Trigger Flutter build job (wait:false)       |
  +--------------------+-----------------------------+
                       |
                       | commit android/unityLibrary
                       | + .unity-exported-sha
                       v
  Flutter Repo (contains both Jenkinsfiles)
       |
       | (SCM webhook or explicit trigger)
       v
  +--------------------------------------------------+
  |  Jenkinsfile                                     |
  |  Agent: flutter (Linux Docker container)         |
  |                                                  |
  |  1. Checkout + GIT_SHA                           |
  |  2. flutter pub get                              |
  |  3. flutter analyze + dart format check          |
  |  4. Dependency audit                             |
  |  5. flutter test + coverage gate (70%)           |
  |  6. Resolve unityLibrary (repo or artifact)      |
  |  7. Decode keystore (base64 credential)          |
  |  8. flutter build apk --release                  |
  |  9. Firebase App Distribution                    |
  | 10. Discord notification + GitHub status         |
  +--------------------+-----------------------------+
                       |
                       v
              app-release.apk
                       |
                       v
         Firebase App Distribution
         (main / release/* or DISTRIBUTE=true)
                       |
                       v
                   Testers
```

---

## Repository Layout

```
jenkins-flutter-unity-boilerplate/
|-- Jenkinsfile                      # Flutter build pipeline (Linux flutter agent)
|-- Jenkinsfile.unity-export         # Unity export pipeline (Windows unity agent)
|-- docker/
|   |-- Dockerfile.flutter-agent     # Ubuntu 22.04 agent: Flutter + Android SDK + Java 17
|   +-- docker-compose.yml           # Jenkins controller + flutter-agent services
|-- unity/
|   +-- HeadlessExporter.cs          # Unity Editor script -- copy to Assets/Editor/
|-- scripts/
|   +-- setup.sh                     # Interactive setup script
+-- README.md                        # This file
```

---

## Prerequisites

| Component | Requirement |
|---|---|
| Jenkins controller | Docker (Linux/macOS) or bare-metal, Java 17 |
| Flutter build agent | Docker on any Linux host |
| Unity export agent | **Physical Windows machine** with Unity Hub + Editor |
| Unity version | 2022.3.x LTS or later (tested: 2022.3.61f1) |
| Flutter SDK | 3.22.x or later (stable channel) |
| Android SDK | API 34, NDK 26.1.10909125, build-tools 34.0.0 |
| Java | 17 on all agents |
| Git LFS | Required on the Windows Unity agent |

> **Why a physical Windows machine for Unity?**
> Unity Editor has no Linux support for Android Gradle export. The batch-mode
> `-nographics` flag still requires Windows GDI subsystem components. Docker
> for Windows / WSL2 introduces file I/O overhead that corrupts Unity's
> Library cache on large projects.

---

## Quick Start

### 1. Clone this boilerplate alongside your Flutter project

```bash
# From your Flutter repo root
git clone https://github.com/YOUR_ORG/jenkins-flutter-unity-boilerplate .ci-boilerplate
cp .ci-boilerplate/Jenkinsfile .
cp .ci-boilerplate/Jenkinsfile.unity-export .
cp -r .ci-boilerplate/docker ./docker
cp -r .ci-boilerplate/scripts ./scripts
# HeadlessExporter.cs must go into the Unity project (see Step 9 below)
rm -rf .ci-boilerplate
```

### 2. Run the interactive setup script

```bash
bash scripts/setup.sh
```

The script:
- Prompts for `FLUTTER_REPO_URL`, `UNITY_REPO_URL`, `APP_NAME`, `UNITY_EXE_PATH`
- Substitutes placeholders in both Jenkinsfiles (backups as `*.bak`)
- Creates `docker/.env` (gitignored, stores Jenkins agent secret)
- Prints the full Jenkins setup checklist
- Optionally starts the Jenkins controller via docker-compose

### 3. Follow the setup checklist

See the **Jenkins Setup Checklist** section below for all steps.

---

## The Two Pipelines

### `Jenkinsfile` — Flutter Build Pipeline

**Agent label:** `flutter` (Linux Docker container built from `docker/Dockerfile.flutter-agent`)

| Stage | What happens |
|---|---|
| **Checkout** | `git checkout scm`; captures `GIT_SHA`, `GIT_BRANCH`, `BUILD_LABEL` |
| **Setup** | `flutter pub get` |
| **Analyze & Format** | Parallel: `flutter analyze --fatal-warnings` + `dart format --set-exit-if-changed` |
| **Dependency Audit** | `flutter pub outdated`; warns on `dependency_overrides` |
| **Test** | `flutter test --coverage`; generates `coverage/lcov.info` and HTML report |
| **Coverage Gate** | `awk` parses `lcov.info`; marks build unstable if coverage < 70% |
| **Resolve unityLibrary** | Uses `android/unityLibrary` if committed; otherwise downloads `unityLibrary.zip` from `unity-export` job via `copyArtifacts` |
| **Decode Keystore** | Decodes base64 credential to `android/keystore/release.jks`; writes `android/key.properties` |
| **Build APK** | `flutter build apk --release --build-name=1.0.N --build-number=N` |
| **Firebase Distribution** | Runs on `main`, `release/*` branches, or when `DISTRIBUTE=true` |
| **Post** | Deletes keystore, posts GitHub commit status, sends Discord embed, `cleanWs` |

**Build parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `DISTRIBUTE` | Boolean | `false` | Upload APK to Firebase App Distribution |
| `FIREBASE_TESTERS_GROUP` | String | `internal` | Firebase tester group slug |

---

### `Jenkinsfile.unity-export` — Unity Export Pipeline

**Agent label:** `unity` (Windows physical machine, permanent agent)

| Stage | What happens |
|---|---|
| **Checkout Flutter Repo** | `checkout scm` on the Flutter repo (the same repo that contains this Jenkinsfile) |
| **Sync Unity Repo** | Incremental `git fetch + reset --hard` if workspace exists; fresh `git clone --lfs` otherwise |
| **Check If Export Needed** | Reads `.unity-exported-sha`; skips all Unity stages if current Unity `HEAD` matches |
| **Check Unity Workspace Lock** | Reads age of `Temp/UnityLockfile`; auto-removes if stale > 3600s; polls every 15s for up to 10 min if recent |
| **Unity Export Android** | `Start-Process Unity.exe -batchmode -nographics -executeMethod HeadlessExporter.ExportAndroid` |
| **Verify unityLibrary** | Checks `build.gradle` + `AndroidManifest.xml`; auto-creates `keepUnitySymbols.gradle` |
| **Archive unityLibrary.zip** | `robocopy` (excludes `build/`, `.cxx/`, `symbols/`) then `Compress-Archive`; archived as Jenkins artifact |
| **Commit to Flutter Repo** | `git add android/unityLibrary .unity-exported-sha && git commit [skip ci] && git push` |
| **Trigger Flutter Build** | `build(job: APP_NAME/main, wait:false, propagate:false)` — non-fatal if job not found |

**Build parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `FORCE_EXPORT` | Boolean | `false` | Export even when Unity SHA is unchanged |
| `UNITY_BRANCH` | String | `main` | Branch of the Unity repo to export |

**SHA-based skip optimisation:**

`.unity-exported-sha` is committed to the Flutter repo by each successful export run.
It contains the 40-character git SHA of the Unity repo at export time. On every pipeline
run, the current Unity `HEAD` SHA is compared to this file. If they match, all Unity
stages are skipped, saving 15-45 minutes of export time.

To force a fresh export: set `FORCE_EXPORT=true` when triggering the job manually.

---

## Jenkins Setup Checklist

### Step 1 — Start Jenkins Controller

```bash
cd docker/
docker-compose up -d jenkins
```

Open: http://localhost:8080

Get initial admin password:
```bash
docker exec jenkins-controller cat /var/jenkins_home/secrets/initialAdminPassword
```

### Step 2 — Install Required Plugins

Go to: **Manage Jenkins > Plugins > Available plugins**

Install these plugins:
- Pipeline
- Pipeline: Multibranch
- Git
- GitHub Branch Source
- **Copy Artifact** (required for unityLibrary artifact download)
- AnsiColor
- Workspace Cleanup
- Credentials Binding
- Timestamper
- Build Discarder

### Step 3 — Create Credentials

**Manage Jenkins > Credentials > System > Global credentials (unrestricted)**

See the **Credential IDs Reference** table below.

### Step 4 — Register Flutter Linux Agent

1. **Manage Jenkins > Nodes > New Node**
2. Node name: `flutter-agent-01`
3. Labels: `flutter`
4. Remote root directory: `/home/jenkins/agent`
5. Launch method: **"Launch agent by connecting it to the controller"**
6. Save and copy the displayed **agent secret**
7. Paste the secret into `docker/.env` as `FLUTTER_AGENT_SECRET=<secret>`

### Step 5 — Start Flutter Agent

```bash
cd docker/
docker-compose up -d flutter-agent
```

### Step 6 — Register Windows Unity Agent

1. **Manage Jenkins > Nodes > New Node**
2. Node name: `unity-agent-01`
3. Labels: `unity`
4. Remote root directory: `C:\jenkins\workspace`
5. Launch method: **"Launch agent by connecting it to the controller"**
6. Save and copy the **agent secret**

On the Windows machine, download `agent.jar` and connect:

```powershell
# Download agent.jar
Invoke-WebRequest -Uri "http://YOUR_JENKINS_URL/jnlpJars/agent.jar" -OutFile "C:\jenkins\agent.jar"

# Connect
java -jar C:\jenkins\agent.jar `
     -url http://YOUR_JENKINS_URL `
     -secret YOUR_SECRET `
     -name unity-agent-01 `
     -workDir C:\jenkins\workspace
```

To run as a Windows Service (recommended for production):

```powershell
# Download NSSM: https://nssm.cc/download
nssm install JenkinsUnityAgent java
nssm set JenkinsUnityAgent AppParameters "-jar C:\jenkins\agent.jar -url http://YOUR_JENKINS_URL -secret YOUR_SECRET -name unity-agent-01 -workDir C:\jenkins\workspace"
nssm set JenkinsUnityAgent AppDirectory C:\jenkins
nssm start JenkinsUnityAgent
```

### Step 7 — Create Unity Export Pipeline Job

1. **New Item > Pipeline**
2. Name: `unity-export`
3. Pipeline > Definition: **Pipeline script from SCM**
4. SCM: Git
5. Repository URL: `YOUR_FLUTTER_REPO_URL`
6. Credentials: `github-token`
7. Script Path: `Jenkinsfile.unity-export`

### Step 8 — Create Flutter Multibranch Pipeline

1. **New Item > Multibranch Pipeline**
2. Name: `YOUR_APP_NAME` (must match `APP_NAME` in `Jenkinsfile.unity-export`)
3. Branch Sources: GitHub or Git
4. Repository URL: `YOUR_FLUTTER_REPO_URL`
5. Credentials: `github-token`
6. Build Configuration: by Jenkinsfile (auto-detected)
7. Scan triggers: set to scan every 1 minute or configure a GitHub webhook

### Step 9 — Install HeadlessExporter in Unity Project

```bash
# From your Unity project root
cp path/to/unity/HeadlessExporter.cs Assets/Editor/HeadlessExporter.cs
git add Assets/Editor/HeadlessExporter.cs
git commit -m "Add HeadlessExporter for Jenkins CI batch export"
git push
```

### Step 10 — Add flutter_embed_unity to Flutter Project

See the **flutter_embed_unity Integration** section below.

---

## Credential IDs Reference

| Credential ID | Kind | Description |
|---|---|---|
| `github-token` | Username + Password | GitHub username + PAT (scopes: `repo`, `admin:repo_hook`) |
| `android-keystore-base64` | Secret text | `base64 -w0 release.jks` output |
| `android-keystore-password` | Secret text | Keystore password |
| `android-key-alias` | Secret text | Key alias name |
| `android-key-password` | Secret text | Key password |
| `firebase-app-id` | Secret text | Firebase app ID (`1:xxx:android:yyy`) |
| `firebase-ci-token` | Secret text | `firebase login:ci` token |
| `discord-webhook-url` | Secret text | Discord channel webhook URL |

---

## Unity HeadlessExporter Setup

### Installation

Copy `unity/HeadlessExporter.cs` into your Unity project:

```
<UnityProject>/Assets/Editor/HeadlessExporter.cs
```

The `Assets/Editor/` directory is special — Unity only compiles it in the Editor
and never includes it in builds. This is required for Editor-only scripts.

### Configuring scenes

Open **File > Build Settings** in Unity Editor:
1. Click **Add Open Scenes** for each scene you want exported
2. Ensure all scenes are ticked (enabled)
3. Set platform to **Android** and click **Switch Platform**

### How HeadlessExporter works

When called by Jenkins with `-executeMethod HeadlessExporter.ExportAndroid`:

1. Reads `UNITY_EXPORT_PATH` environment variable for the destination path
2. Configures `PlayerSettings`: IL2CPP scripting backend, ARMv7 + ARM64, API 22 min / API 34 target
3. Sets `EditorUserBuildSettings.exportAsGoogleAndroidProject = true` (exports Gradle module, not APK)
4. Calls `BuildPipeline.BuildPlayer` with `BuildTarget.Android`
5. Validates that `build.gradle` was generated under the export path
6. Calls `EditorApplication.Exit(0)` on success, `Exit(1)` on any error

The exit code is checked by `Jenkinsfile.unity-export` to determine success or failure.

### Overriding the bundle identifier

Set the `UNITY_BUNDLE_ID` environment variable before calling Unity to override the
Android bundle identifier (e.g. to use a staging vs production ID):

```groovy
// In Jenkinsfile.unity-export, add to the Unity export step:
environment {
    UNITY_BUNDLE_ID = 'com.example.myapp.staging'
}
```

---

## flutter_embed_unity Integration

### pubspec.yaml

```yaml
dependencies:
  flutter_embed_unity: ^2.1.0
```

Run `flutter pub get` after adding this dependency.

### android/settings.gradle

```groovy
include ':unityLibrary'
project(':unityLibrary').projectDir = file('./unityLibrary')
```

### android/build.gradle (project level)

```groovy
allprojects {
    repositories {
        google()
        mavenCentral()
        flatDir { dirs "${rootDir}/unityLibrary/libs" }
    }
}
```

### android/app/build.gradle (app level)

```groovy
dependencies {
    implementation project(':unityLibrary')
}

// Apply the keepUnitySymbols patch (auto-generated by unity-export pipeline)
apply from: '../unityLibrary/keepUnitySymbols.gradle'
```

The `keepUnitySymbols.gradle` file is injected by the `Verify unityLibrary` stage.
It prevents duplicate `.so` errors during the Flutter APK build by configuring
`packagingOptions.pickFirst` for `libunity.so`, `libil2cpp.so`, and `libmain.so`.

---

## Troubleshooting

### Unity workspace busy — lock file not releasing

**Symptom:** `Check Unity Workspace Lock` stage waits 10 minutes, then fails with
`"Unity lock file still present after 600s"`.

**Cause:** A previous Unity process crashed and left `Temp/UnityLockfile` with
a recent timestamp (< 3600 seconds old).

**Fix:**
1. On the Windows agent, open Task Manager and kill any `Unity.exe` or
   `UnityCrashHandler.exe` processes.
2. Manually delete: `<UNITY_WORKSPACE>\Temp\UnityLockfile`
3. Re-run the `unity-export` job.

**Prevention:** The pipeline automatically removes lock files older than
`LOCK_STALE_SECONDS` (default: 3600). If your Unity export takes > 1 hour,
increase this value in `Jenkinsfile.unity-export`.

---

### Git LFS objects not downloading

**Symptom:** Binary assets (`.fbx`, `.psd`, textures) are LFS pointer files;
Unity fails to import them with "Could not read file" errors.

**Fix:**
1. Verify LFS is installed system-wide on the Windows agent:
   ```powershell
   git lfs install --system
   ```
2. Verify the `github-token` credential has read access to LFS on the repo.
3. Check your Git hosting provider's LFS bandwidth quota.
4. Force a full re-clone: delete `UNITY_WORKSPACE` on the Windows agent
   and re-run the `unity-export` job.

---

### NDK path issues during Unity batch export

**Symptom:** Unity log contains `NDK not found` or
`"Unable to find a valid Android NDK installation"`.

**Fix options (choose one):**

**Option A — Install NDK via Unity Hub (recommended):**
- Unity Hub > Installs > (your version) > cog icon > Add Modules
- Check: Android Build Support > Android SDK & NDK Tools
- Click Install

**Option B — Set NDK path in Unity preferences:**
- Edit > Preferences > External Tools > Android NDK
- Uncheck "Installed with Unity" and browse to your NDK path

**Option C — System environment variable:**
```powershell
# Set permanently for all users (requires admin; restart Jenkins agent service after)
[System.Environment]::SetEnvironmentVariable(
    "ANDROID_NDK_HOME",
    "C:\Program Files\Unity\Hub\Editor\2022.3.61f1\Editor\Data\PlaybackEngines\AndroidPlayer\NDK",
    "Machine"
)
```

---

### copyArtifacts permission error in Flutter pipeline

**Symptom:** `Resolve unityLibrary` stage fails with:
`"Unable to find project: unity-export"` or `"Permission denied"`.

**Fix:**
1. Install the **Copy Artifact** plugin if missing.
2. In the `unity-export` job: **Configure > General > Permission to Copy Artifact**
   — add the Flutter multibranch pipeline name.
3. Verify the `unity-export` job has at least one successful build with an archived
   `unityLibrary.zip` artifact.

---

### Coverage gate failing — no coverage data

**Symptom:** `Coverage Gate` logs `"No coverage data found — skipping gate"`.

**Fix:**
1. At least one `_test.dart` file must exist under `test/`.
2. Verify `lcov` is available on the flutter agent:
   ```bash
   docker exec jenkins-flutter-agent which genhtml
   ```
   If missing, rebuild the Docker image (the Dockerfile installs `lcov`).
3. Check `flutter test --coverage` output — it should print
   `Generating coverage report in coverage/lcov.info`.

---

### Discord notifications not sending

**Symptom:** Build succeeds but no Discord message appears.

**Fix:**
1. Verify the webhook URL in the `discord-webhook-url` credential:
   ```bash
   curl -X POST -H "Content-Type: application/json" \
     -d '{"content":"Jenkins test"}' \
     "YOUR_WEBHOOK_URL"
   ```
2. Ensure the webhook has **Send Messages** permission in the Discord channel.
3. Check that `curl` is available on the flutter agent (it is installed in
   `Dockerfile.flutter-agent` via `build-essential`).

---

## Environment Variables Summary

### Jenkinsfile (Flutter build)

| Variable | Source | Description |
|---|---|---|
| `APP_NAME` | Pipeline env block | Application / job name |
| `KEYSTORE_PASSWORD` | Jenkins credential | Android keystore password |
| `KEY_ALIAS` | Jenkins credential | Android key alias |
| `KEY_PASSWORD` | Jenkins credential | Android key password |
| `FIREBASE_APP_ID` | Jenkins credential | Firebase app ID |
| `FIREBASE_TOKEN` | Jenkins credential | `firebase login:ci` token |
| `DISCORD_WEBHOOK` | Jenkins credential | Discord webhook URL |
| `GITHUB_TOKEN` | Jenkins credential | GitHub PAT for commit status |
| `COVERAGE_THRESHOLD` | Pipeline env block | Minimum line coverage % (default: 70) |

### Jenkinsfile.unity-export

| Variable | Source | Description |
|---|---|---|
| `FLUTTER_REPO_URL` | Pipeline env block | URL of the Flutter repo (for push-back) |
| `UNITY_REPO_URL` | Pipeline env block | URL of the Unity project repo |
| `UNITY_EXE` | Pipeline env block | Absolute path to Unity.exe |
| `UNITY_WORKSPACE` | Pipeline env block | Local path where Unity repo is cloned on Windows agent |
| `SHA_TRACKING_FILE` | Pipeline env block | Filename for SHA tracking (`.unity-exported-sha`) |
| `LOCK_STALE_SECONDS` | Pipeline env block | Age threshold (seconds) for stale Unity lockfile |

### HeadlessExporter.cs (read by Unity at export time)

| Variable | Set by | Description |
|---|---|---|
| `UNITY_EXPORT_PATH` | `Jenkinsfile.unity-export` PowerShell stage | Absolute destination path for the Android Gradle export |
| `UNITY_BUNDLE_ID` | Optional: add to Jenkins env block | Override Android bundle identifier |

---

## License

MIT License. Use freely in commercial and open-source projects.
