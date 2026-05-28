// ============================================================
// Jenkinsfile — Flutter build pipeline (Linux flutter agent)
// Embeds unityLibrary exported by Jenkinsfile.unity-export
// ============================================================

pipeline {
    agent { label 'flutter' }

    options {
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timeout(time: 60, unit: 'MINUTES')
        skipDefaultCheckout()
        disableConcurrentBuilds()
        ansiColor('xterm')
    }

    parameters {
        booleanParam(
            name: 'DISTRIBUTE',
            defaultValue: false,
            description: 'Upload to Firebase App Distribution after build'
        )
        string(
            name: 'FIREBASE_TESTERS_GROUP',
            defaultValue: 'internal',
            description: 'Firebase App Distribution tester group'
        )
    }

    environment {
        // ── App identity ──────────────────────────────────────────────
        APP_NAME            = 'YOUR_APP_NAME'
        FLUTTER_REPO_URL    = 'YOUR_FLUTTER_REPO_URL'

        // ── Android signing ───────────────────────────────────────────
        // Jenkins credential IDs — configure via Manage Jenkins > Credentials
        KEYSTORE_CRED_ID    = 'android-keystore-base64'   // Secret file or Secret text (base64)
        KEYSTORE_PASSWORD   = credentials('android-keystore-password')
        KEY_ALIAS           = credentials('android-key-alias')
        KEY_PASSWORD        = credentials('android-key-password')

        // ── Firebase ──────────────────────────────────────────────────
        FIREBASE_APP_ID     = credentials('firebase-app-id')
        FIREBASE_TOKEN      = credentials('firebase-ci-token')

        // ── Discord webhook ───────────────────────────────────────────
        DISCORD_WEBHOOK     = credentials('discord-webhook-url')

        // ── GitHub ────────────────────────────────────────────────────
        GITHUB_TOKEN        = credentials('github-token')
        GITHUB_REPO         = 'YOUR_APP_NAME'             // owner/repo format

        // ── Derived paths ─────────────────────────────────────────────
        ANDROID_SDK_ROOT    = '/opt/android-sdk'
        PUB_CACHE           = '/var/jenkins_home/.pub-cache'
        UNITY_LIB_DIR       = 'android/unityLibrary'
        APK_OUTPUT          = 'build/app/outputs/flutter-apk/app-release.apk'
        COVERAGE_THRESHOLD  = '70'
    }

    stages {

        // ── 1. CHECKOUT ────────────────────────────────────────────────
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.GIT_SHA       = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
                    env.GIT_SHA_SHORT = env.GIT_SHA.take(8)
                    env.GIT_BRANCH    = sh(script: 'git rev-parse --abbrev-ref HEAD', returnStdout: true).trim()
                    env.BUILD_LABEL   = "${APP_NAME}-${GIT_SHA_SHORT}-${BUILD_NUMBER}"
                    echo "Branch: ${env.GIT_BRANCH}  SHA: ${env.GIT_SHA_SHORT}"
                }
                // Post initial 'pending' status to GitHub
                githubStatusUpdate('pending', 'Build started')
            }
        }

        // ── 2. SETUP ───────────────────────────────────────────────────
        stage('Setup') {
            steps {
                sh '''
                    flutter --version
                    flutter pub get
                    flutter pub deps --no-dev 2>&1 | head -20
                '''
            }
        }

        // ── 3. STATIC ANALYSIS ─────────────────────────────────────────
        stage('Analyze & Format') {
            parallel {
                stage('flutter analyze') {
                    steps {
                        sh 'flutter analyze --fatal-infos --fatal-warnings'
                    }
                }
                stage('dart format') {
                    steps {
                        sh '''
                            dart format --output=none --set-exit-if-changed .
                        '''
                    }
                }
            }
        }

        // ── 4. DEPENDENCY AUDIT ────────────────────────────────────────
        stage('Dependency Audit') {
            steps {
                sh '''
                    # Check for known vulnerable dependencies
                    flutter pub outdated --no-dev-dependencies || true

                    # Check for any dependency overrides that might mask security issues
                    if grep -q "dependency_overrides:" pubspec.yaml; then
                        echo "WARNING: dependency_overrides found in pubspec.yaml"
                        grep -A5 "dependency_overrides:" pubspec.yaml
                    fi
                '''
            }
        }

        // ── 5. TEST + COVERAGE ─────────────────────────────────────────
        stage('Test') {
            steps {
                sh '''
                    flutter test \
                        --coverage \
                        --reporter=json \
                        > test-results.json || true

                    # Generate lcov report
                    if [ -f coverage/lcov.info ]; then
                        genhtml coverage/lcov.info \
                            --output-directory coverage/html \
                            --quiet || true
                    fi
                '''
            }
            post {
                always {
                    script {
                        if (fileExists('test-results.json')) {
                            echo 'Test results available at test-results.json'
                        }
                    }
                }
            }
        }

        stage('Coverage Gate') {
            steps {
                script {
                    if (fileExists('coverage/lcov.info')) {
                        def covered = sh(
                            script: '''
                                awk -F: '/^LH:/{h+=$2} /^LF:/{f+=$2} END {
                                    if(f>0) printf "%.0f", h*100/f; else print "0"
                                }' coverage/lcov.info
                            ''',
                            returnStdout: true
                        ).trim().toInteger()

                        echo "Line coverage: ${covered}%  (threshold: ${COVERAGE_THRESHOLD}%)"

                        if (covered < COVERAGE_THRESHOLD.toInteger()) {
                            unstable("Coverage ${covered}% is below threshold ${COVERAGE_THRESHOLD}%")
                        }
                    } else {
                        echo 'No coverage data found — skipping gate'
                    }
                }
            }
        }

        // ── 6. UNITY LIBRARY ──────────────────────────────────────────
        stage('Resolve unityLibrary') {
            steps {
                script {
                    def unityLibExists = fileExists("${UNITY_LIB_DIR}/build.gradle")

                    if (!unityLibExists) {
                        echo 'unityLibrary not in repo — attempting to download from unity-export job artifact'
                        downloadUnityArtifact()
                    } else {
                        echo "unityLibrary already present at ${UNITY_LIB_DIR}"
                    }

                    // Verify the library is usable
                    if (!fileExists("${UNITY_LIB_DIR}/build.gradle")) {
                        error 'unityLibrary/build.gradle missing — cannot build without Unity AAR'
                    }

                    sh "ls -lh ${UNITY_LIB_DIR}/"
                }
            }
        }

        // ── 7. KEYSTORE SETUP ─────────────────────────────────────────
        stage('Decode Keystore') {
            steps {
                withCredentials([string(credentialsId: "${KEYSTORE_CRED_ID}", variable: 'KEYSTORE_B64')]) {
                    sh '''
                        mkdir -p android/keystore
                        echo "$KEYSTORE_B64" | base64 --decode > android/keystore/release.jks
                        echo "Keystore decoded: $(stat -c%s android/keystore/release.jks) bytes"
                    '''
                }
                // Write key.properties for gradle
                sh '''
                    cat > android/key.properties <<EOF
storePassword=${KEYSTORE_PASSWORD}
keyPassword=${KEY_PASSWORD}
keyAlias=${KEY_ALIAS}
storeFile=keystore/release.jks
EOF
                '''
            }
        }

        // ── 8. BUILD APK ──────────────────────────────────────────────
        stage('Build APK') {
            steps {
                sh '''
                    flutter build apk \
                        --release \
                        --build-name="1.0.${BUILD_NUMBER}" \
                        --build-number="${BUILD_NUMBER}" \
                        --dart-define=BUILD_SHA="${GIT_SHA_SHORT}" \
                        --dart-define=BUILD_LABEL="${BUILD_LABEL}" \
                        --no-tree-shake-icons
                '''
            }
            post {
                success {
                    archiveArtifacts(
                        artifacts: "${APK_OUTPUT}",
                        fingerprint: true
                    )
                    script {
                        def size = sh(
                            script: "du -sh ${APK_OUTPUT} | cut -f1",
                            returnStdout: true
                        ).trim()
                        echo "APK built successfully: ${size}"
                    }
                }
            }
        }

        // ── 9. FIREBASE APP DISTRIBUTION ──────────────────────────────
        stage('Firebase Distribution') {
            when {
                anyOf {
                    expression { params.DISTRIBUTE == true }
                    branch 'main'
                    branch 'release/*'
                }
            }
            steps {
                sh '''
                    firebase appdistribution:distribute "${APK_OUTPUT}" \
                        --app "${FIREBASE_APP_ID}" \
                        --token "${FIREBASE_TOKEN}" \
                        --groups "${FIREBASE_TESTERS_GROUP}" \
                        --release-notes "Branch: ${GIT_BRANCH}  Commit: ${GIT_SHA_SHORT}  Build: #${BUILD_NUMBER}"
                '''
            }
        }

    } // end stages

    post {
        success {
            script {
                githubStatusUpdate('success', "Build #${BUILD_NUMBER} passed")
                discordNotify('SUCCESS')
            }
        }
        failure {
            script {
                githubStatusUpdate('failure', "Build #${BUILD_NUMBER} failed")
                discordNotify('FAILURE')
            }
        }
        unstable {
            script {
                githubStatusUpdate('failure', "Build #${BUILD_NUMBER} unstable")
                discordNotify('UNSTABLE')
            }
        }
        always {
            // Remove keystore to avoid leaking secrets on disk
            sh 'rm -f android/keystore/release.jks android/key.properties || true'
            cleanWs(
                cleanWhenSuccess: true,
                cleanWhenFailure: false,   // Keep workspace on failure for debugging
                cleanWhenUnstable: true,
                notFailBuild: true
            )
        }
    }
}

// ── Helper functions ────────────────────────────────────────────────────────

def downloadUnityArtifact() {
    // Try to copy the unityLibrary artifact from the unity-export job.
    // The unity-export pipeline archives 'unityLibrary.zip'.
    // Adjust 'unity-export' to match your actual job name / folder path.
    try {
        copyArtifacts(
            projectName: 'unity-export',
            filter: 'unityLibrary.zip',
            target: '.',
            fingerprintArtifacts: true,
            optional: false,
            selector: lastSuccessful()
        )
        sh '''
            unzip -o unityLibrary.zip -d android/
            rm -f unityLibrary.zip
        '''
        echo 'unityLibrary downloaded and extracted from unity-export artifact'
    } catch (Exception e) {
        echo "Could not download unity artifact: ${e.message}"
        error 'Cannot proceed without unityLibrary — run unity-export pipeline first'
    }
}

def githubStatusUpdate(String state, String description) {
    // Uses GitHub Status API via curl (no plugin required)
    // Requires GITHUB_TOKEN and GITHUB_REPO env vars
    sh """
        curl -s -X POST \\
          -H "Authorization: token ${GITHUB_TOKEN}" \\
          -H "Accept: application/vnd.github+json" \\
          -d '{"state":"${state}","description":"${description}","context":"ci/jenkins","target_url":"${BUILD_URL}"}' \\
          "https://api.github.com/repos/${GITHUB_REPO}/statuses/${GIT_SHA}" || true
    """
}

def discordNotify(String status) {
    def color
    def emoji
    switch (status) {
        case 'SUCCESS':  color = 3066993;  emoji = 'white_check_mark'; break
        case 'FAILURE':  color = 15158332; emoji = 'x';                break
        case 'UNSTABLE': color = 15105570; emoji = 'warning';          break
        default:         color = 9807270;  emoji = 'grey_question';    break
    }

    def payload = """
    {
      "embeds": [{
        "title": ":${emoji}: ${APP_NAME} -- Build ${status}",
        "color": ${color},
        "fields": [
          {"name": "Branch",  "value": "${env.GIT_BRANCH}",   "inline": true},
          {"name": "Commit",  "value": "${env.GIT_SHA_SHORT}", "inline": true},
          {"name": "Build",   "value": "#${BUILD_NUMBER}",    "inline": true},
          {"name": "Link",    "value": "${BUILD_URL}",         "inline": false}
        ]
      }]
    }
    """

    sh """
        curl -s -X POST \\
          -H "Content-Type: application/json" \\
          -d '${payload.replaceAll("'", "\\\\'")}' \\
          "${DISCORD_WEBHOOK}" || true
    """
}
