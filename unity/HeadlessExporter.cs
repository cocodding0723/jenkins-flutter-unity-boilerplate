// ============================================================
// HeadlessExporter.cs — placed in Assets/Editor/
//
// Called by Jenkins batch mode:
//   Unity.exe -batchmode -nographics -quit
//             -projectPath <path>
//             -executeMethod HeadlessExporter.ExportAndroid
//             -logFile <log>
//             -buildTarget Android
//
// The export destination is read from the environment variable
// UNITY_EXPORT_PATH set by Jenkinsfile.unity-export before
// launching Unity.exe.
//
// The project is exported as an Android Gradle project
// (ExportAsGoogleAndroidProject = true) so that Flutter can
// embed it as the 'unityLibrary' module via flutter_embed_unity.
// ============================================================

#if UNITY_EDITOR

using System;
using System.IO;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEngine;

public static class HeadlessExporter
{
    // ── Configuration ────────────────────────────────────────────────────────

    // Environment variable that Jenkins sets to the destination path.
    private const string ExportPathEnvVar = "UNITY_EXPORT_PATH";

    // Default relative export path from the Unity project root when the
    // env var is not set (useful for local testing).
    private const string DefaultExportRelativePath = "android/unityLibrary";

    // ── Entry point ──────────────────────────────────────────────────────────

    /// <summary>
    /// Called by Jenkins via -executeMethod HeadlessExporter.ExportAndroid
    /// Configures PlayerSettings, runs the Android Gradle export, then exits.
    /// Any unhandled exception causes exit code 1, which fails the Jenkins stage.
    /// </summary>
    public static void ExportAndroid()
    {
        Debug.Log("[HeadlessExporter] ===== Android export started =====");

        try
        {
            string exportPath = ResolveExportPath();
            Debug.Log($"[HeadlessExporter] Export destination: {exportPath}");

            ConfigurePlayerSettings();
            ConfigureBuildSettings();
            RunBuildPipeline(exportPath);

            Debug.Log("[HeadlessExporter] ===== Android export SUCCEEDED =====");
            EditorApplication.Exit(0);
        }
        catch (Exception ex)
        {
            Debug.LogError($"[HeadlessExporter] EXPORT FAILED:\n{ex}");
            EditorApplication.Exit(1);
        }
    }

    // ── Step 1: Resolve export path ──────────────────────────────────────────

    private static string ResolveExportPath()
    {
        string envPath = Environment.GetEnvironmentVariable(ExportPathEnvVar);

        string exportPath;
        if (!string.IsNullOrWhiteSpace(envPath))
        {
            exportPath = envPath.Trim();
            Debug.Log($"[HeadlessExporter] Using {ExportPathEnvVar} = {exportPath}");
        }
        else
        {
            string projectRoot = Path.GetDirectoryName(Application.dataPath);
            exportPath = Path.GetFullPath(
                Path.Combine(projectRoot, DefaultExportRelativePath));
            Debug.Log($"[HeadlessExporter] {ExportPathEnvVar} not set — using default: {exportPath}");
        }

        // Clean the destination directory before exporting
        if (Directory.Exists(exportPath))
        {
            Debug.Log($"[HeadlessExporter] Removing existing export dir: {exportPath}");
            Directory.Delete(exportPath, recursive: true);
        }

        Directory.CreateDirectory(exportPath);
        return exportPath;
    }

    // ── Step 2: Configure PlayerSettings ────────────────────────────────────

    private static void ConfigurePlayerSettings()
    {
        Debug.Log("[HeadlessExporter] Configuring PlayerSettings...");

        // Allow CI to override the bundle identifier
        string bundleId = Environment.GetEnvironmentVariable("UNITY_BUNDLE_ID");
        if (!string.IsNullOrWhiteSpace(bundleId))
        {
            PlayerSettings.SetApplicationIdentifier(
                BuildTargetGroup.Android, bundleId.Trim());
            Debug.Log($"[HeadlessExporter] Application identifier: {bundleId.Trim()}");
        }

        // IL2CPP backend is required for 64-bit Android (Google Play requirement)
        PlayerSettings.SetScriptingBackend(
            BuildTargetGroup.Android, ScriptingImplementation.IL2CPP);
        Debug.Log("[HeadlessExporter] Scripting backend: IL2CPP");

        // ARMv7 + ARM64 covers all modern Android devices
        PlayerSettings.Android.targetArchitectures =
            AndroidArchitecture.ARMv7 | AndroidArchitecture.ARM64;
        Debug.Log("[HeadlessExporter] Target architectures: ARMv7 | ARM64");

        // Minimum SDK level — Android 5.1 (API 22)
        PlayerSettings.Android.minSdkVersion = AndroidSdkVersions.AndroidApiLevel22;

        // Target SDK level — Android 14 (API 34), matches Dockerfile build-tools
        PlayerSettings.Android.targetSdkVersion = (AndroidSdkVersions)34;

        // Keep all engine code for library mode (stripping can break embedding)
        PlayerSettings.stripEngineCode = false;

        PlayerSettings.Android.optimizedFramePacing = true;

        Debug.Log("[HeadlessExporter] PlayerSettings configured.");
    }

    // ── Step 3: Configure EditorUserBuildSettings ────────────────────────────

    private static void ConfigureBuildSettings()
    {
        Debug.Log("[HeadlessExporter] Configuring build settings...");

        EditorUserBuildSettings.selectedBuildTargetGroup = BuildTargetGroup.Android;
        EditorUserBuildSettings.activeBuildTarget        = BuildTarget.Android;

        // This is the key flag: export as Gradle project (unityLibrary module)
        // instead of building a signed .apk
        EditorUserBuildSettings.exportAsGoogleAndroidProject = true;

        Debug.Log("[HeadlessExporter] ExportAsGoogleAndroidProject = true");
        Debug.Log("[HeadlessExporter] Build settings configured.");
    }

    // ── Step 4: Run BuildPipeline.BuildPlayer ────────────────────────────────

    private static void RunBuildPipeline(string exportPath)
    {
        string[] scenePaths = GetEnabledScenes();

        if (scenePaths.Length == 0)
        {
            // Fallback: use the currently open scene
            string activeScene = UnityEngine.SceneManagement.SceneManager.GetActiveScene().path;
            if (!string.IsNullOrEmpty(activeScene))
            {
                scenePaths = new[] { activeScene };
                Debug.LogWarning(
                    $"[HeadlessExporter] No scenes in Build Settings — falling back to active scene: {activeScene}");
            }
            else
            {
                throw new InvalidOperationException(
                    "No scenes found in Build Settings and no active scene. " +
                    "Add at least one scene via File > Build Settings before exporting.");
            }
        }

        Debug.Log($"[HeadlessExporter] Building {scenePaths.Length} scene(s):");
        foreach (var s in scenePaths)
            Debug.Log($"  - {s}");

        var buildPlayerOptions = new BuildPlayerOptions
        {
            target           = BuildTarget.Android,
            targetGroup      = BuildTargetGroup.Android,
            locationPathName = exportPath,
            scenes           = scenePaths,
            options          = BuildOptions.None   // Release, no dev/profiler flags
        };

        Debug.Log($"[HeadlessExporter] Calling BuildPipeline.BuildPlayer -> {exportPath}");
        BuildReport  report  = BuildPipeline.BuildPlayer(buildPlayerOptions);
        BuildSummary summary = report.summary;

        Debug.Log($"[HeadlessExporter] Result   : {summary.result}");
        Debug.Log($"[HeadlessExporter] Errors   : {summary.totalErrors}");
        Debug.Log($"[HeadlessExporter] Warnings : {summary.totalWarnings}");
        Debug.Log($"[HeadlessExporter] Size     : {summary.totalSize / 1_048_576} MB");
        Debug.Log($"[HeadlessExporter] Duration : {summary.totalTime.TotalSeconds:F1}s");

        if (summary.result != BuildResult.Succeeded)
        {
            // Emit all error-level build step messages for CI log visibility
            foreach (var step in report.steps)
            {
                foreach (var msg in step.messages)
                {
                    if (msg.type == LogType.Error || msg.type == LogType.Exception)
                        Debug.LogError($"[BUILD STEP] {step.name} >> {msg.content}");
                }
            }

            throw new Exception(
                $"BuildPipeline.BuildPlayer failed: result={summary.result}, " +
                $"errors={summary.totalErrors}");
        }

        // Post-build sanity check: confirm build.gradle was generated
        // Unity 2022+ places it at <exportPath>/unityLibrary/build.gradle
        string buildGradlePrimary   = Path.Combine(exportPath, "unityLibrary", "build.gradle");
        string buildGradleFallback  = Path.Combine(exportPath, "build.gradle");

        if (File.Exists(buildGradlePrimary))
        {
            Debug.Log($"[HeadlessExporter] Confirmed build.gradle at: {buildGradlePrimary}");
        }
        else if (File.Exists(buildGradleFallback))
        {
            Debug.Log($"[HeadlessExporter] Confirmed build.gradle at: {buildGradleFallback}");
        }
        else
        {
            throw new Exception(
                $"Export succeeded but build.gradle not found under {exportPath}. " +
                "Verify that ExportAsGoogleAndroidProject is enabled in PlayerSettings.");
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static string[] GetEnabledScenes()
    {
        var scenes = new System.Collections.Generic.List<string>();
        foreach (EditorBuildSettingsScene scene in EditorBuildSettings.scenes)
        {
            if (scene.enabled && !string.IsNullOrEmpty(scene.path))
                scenes.Add(scene.path);
        }
        return scenes.ToArray();
    }
}

#endif // UNITY_EDITOR
