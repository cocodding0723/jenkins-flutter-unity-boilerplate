#!/usr/bin/env bash
# ============================================================
# setup.sh — Interactive boilerplate setup script
#
# Usage:  bash scripts/setup.sh
#
# What it does:
#   1. Prompts for FLUTTER_REPO_URL, UNITY_REPO_URL, APP_NAME,
#      and UNITY_EXE_PATH
#   2. Substitutes placeholders in both Jenkinsfiles
#   3. Creates docker/.env for docker-compose
#   4. Prints a Jenkins setup checklist
#   5. Optionally starts the Jenkins controller via docker-compose
# ============================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }

# ── Locate script and repo root ───────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

header "Jenkins + Flutter + Unity CI/CD Boilerplate — Setup"
echo "Repo root: ${REPO_ROOT}"

# ── Dependency checks ─────────────────────────────────────────────────────────
header "Checking dependencies"

check_cmd() {
    local cmd="$1"
    local hint="$2"
    if command -v "${cmd}" &>/dev/null; then
        success "${cmd} found: $(command -v "${cmd}")"
    else
        warn "${cmd} not found — ${hint}"
    fi
}

check_cmd docker         "Install from https://docs.docker.com/get-docker/"
check_cmd docker-compose "Install from https://docs.docker.com/compose/install/"
check_cmd git            "Install from https://git-scm.com/"
check_cmd sed            "Usually pre-installed on Linux/macOS"

# ── Collect user input ────────────────────────────────────────────────────────
header "Configuration"

prompt_required() {
    local var_name="$1"
    local prompt_text="$2"
    local value=""
    while [ -z "${value}" ]; do
        echo -e -n "${BOLD}${prompt_text}${RESET}: "
        read -r value
        if [ -z "${value}" ]; then
            error "This field is required."
        fi
    done
    eval "${var_name}='${value}'"
}

prompt_with_default() {
    local var_name="$1"
    local prompt_text="$2"
    local default_val="$3"
    echo -e -n "${BOLD}${prompt_text}${RESET} [${default_val}]: "
    read -r input
    if [ -z "${input}" ]; then
        eval "${var_name}='${default_val}'"
    else
        eval "${var_name}='${input}'"
    fi
}

prompt_required     FLUTTER_REPO_URL "Flutter repo URL (HTTPS, e.g. https://github.com/org/my-flutter-app)"
prompt_required     UNITY_REPO_URL   "Unity repo URL   (HTTPS, e.g. https://github.com/org/my-unity-project)"
prompt_with_default APP_NAME         "App name (no spaces, used as Jenkins job name)" "my-app"
prompt_with_default UNITY_EXE_PATH \
    "Unity.exe absolute path on the Windows unity agent" \
    "C:\\Program Files\\Unity\\Hub\\Editor\\2022.3.61f1\\Editor\\Unity.exe"

echo ""
info "Configuration summary:"
echo "  FLUTTER_REPO_URL : ${FLUTTER_REPO_URL}"
echo "  UNITY_REPO_URL   : ${UNITY_REPO_URL}"
echo "  APP_NAME         : ${APP_NAME}"
echo "  UNITY_EXE_PATH   : ${UNITY_EXE_PATH}"
echo ""
echo -e -n "${BOLD}Proceed? [y/N]: ${RESET}"
read -r confirm
if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# ── Substitute placeholders in Jenkinsfiles ────────────────────────────────────
header "Patching Jenkinsfiles"

# Escape forward slashes and backslashes for sed delimited with |
escape_sed() {
    printf '%s' "$1" | sed 's|[|&\]|\\&|g'
}

FLUTTER_URL_ESC="$(escape_sed "${FLUTTER_REPO_URL}")"
UNITY_URL_ESC="$(escape_sed "${UNITY_REPO_URL}")"
APP_NAME_ESC="$(escape_sed "${APP_NAME}")"
UNITY_EXE_ESC="$(escape_sed "${UNITY_EXE_PATH}")"

patch_file() {
    local file="$1"
    if [ ! -f "${file}" ]; then
        warn "File not found, skipping: ${file}"
        return
    fi
    # Backup before patching
    cp "${file}" "${file}.bak"
    sed -i \
        -e "s|YOUR_FLUTTER_REPO_URL|${FLUTTER_URL_ESC}|g" \
        -e "s|YOUR_UNITY_REPO_URL|${UNITY_URL_ESC}|g" \
        -e "s|YOUR_APP_NAME|${APP_NAME_ESC}|g" \
        -e "s|YOUR_UNITY_EXE_PATH|${UNITY_EXE_ESC}|g" \
        "${file}"
    success "Patched: ${file}  (backup: ${file}.bak)"
}

patch_file "${REPO_ROOT}/Jenkinsfile"
patch_file "${REPO_ROOT}/Jenkinsfile.unity-export"

# ── Create docker/.env ────────────────────────────────────────────────────────
header "Creating docker/.env"

ENV_FILE="${REPO_ROOT}/docker/.env"

if [ -f "${ENV_FILE}" ]; then
    warn ".env already exists — skipping creation (delete it to regenerate)"
else
    cat > "${ENV_FILE}" <<EOF
# docker-compose environment variables
# DO NOT commit this file to git (it is in .gitignore)
#
# After creating the 'flutter-agent-01' node in Jenkins, copy the
# displayed agent secret here:
#   Manage Jenkins > Nodes > flutter-agent-01 > (agent secret)
FLUTTER_AGENT_SECRET=REPLACE_WITH_JENKINS_AGENT_SECRET
EOF
    success ".env created: ${ENV_FILE}"
    warn "Set FLUTTER_AGENT_SECRET in ${ENV_FILE} after Step 4 of the checklist below."
fi

# Add .env to .gitignore if it exists
GITIGNORE="${REPO_ROOT}/.gitignore"
if [ -f "${GITIGNORE}" ]; then
    if ! grep -q "docker/.env" "${GITIGNORE}"; then
        echo "docker/.env" >> "${GITIGNORE}"
        success "Added docker/.env to .gitignore"
    fi
else
    printf "docker/.env\n*.bak\n" > "${GITIGNORE}"
    success "Created .gitignore with docker/.env and *.bak entries"
fi

# ── Print Jenkins setup checklist ─────────────────────────────────────────────
header "Jenkins Setup Checklist"

cat <<CHECKLIST

${BOLD}Step 1 — Start Jenkins Controller${RESET}
  cd ${REPO_ROOT}/docker
  docker-compose up -d jenkins
  Open: http://localhost:8080
  Initial password: docker exec jenkins-controller cat /var/jenkins_home/secrets/initialAdminPassword

${BOLD}Step 2 — Install Jenkins Plugins${RESET}
  Manage Jenkins > Plugins > Available plugins
  Required: Pipeline, Pipeline Multibranch, Git, GitHub Branch Source,
            Copy Artifact, AnsiColor, Workspace Cleanup, Credentials Binding,
            Timestamper, Build Discarder

${BOLD}Step 3 — Add Credentials${RESET}
  Manage Jenkins > Credentials > System > Global credentials

  Credential ID               | Kind                  | Value
  ────────────────────────────────────────────────────────────────────
  github-token                | Username + Password    | GitHub username + PAT
  android-keystore-base64     | Secret text            | base64 -w0 release.jks
  android-keystore-password   | Secret text            | Keystore password
  android-key-alias           | Secret text            | Key alias name
  android-key-password        | Secret text            | Key password
  firebase-app-id             | Secret text            | 1:123456789:android:abc123
  firebase-ci-token           | Secret text            | firebase login:ci output
  discord-webhook-url         | Secret text            | https://discord.com/api/webhooks/...

${BOLD}Step 4 — Register Flutter Linux Agent Node${RESET}
  Manage Jenkins > Nodes > New Node
    Name: flutter-agent-01   Labels: flutter
    Remote root: /home/jenkins/agent
    Launch: "Launch agent by connecting to the controller"
  Copy the displayed SECRET into docker/.env as FLUTTER_AGENT_SECRET

${BOLD}Step 5 — Start Flutter Agent${RESET}
  cd ${REPO_ROOT}/docker
  docker-compose up -d flutter-agent

${BOLD}Step 6 — Register Windows Unity Agent (physical machine)${RESET}
  Manage Jenkins > Nodes > New Node
    Name: unity-agent-01   Labels: unity
    Remote root: C:\\jenkins\\workspace
    Launch: "Launch agent by connecting to the controller"
  On the Windows machine:
    java -jar agent.jar -url http://YOUR_JENKINS_URL -secret <SECRET> ^
         -name unity-agent-01 -workDir C:\\jenkins\\workspace

${BOLD}Step 7 — Create Unity Export Pipeline Job${RESET}
  New Item > Pipeline
    Name: unity-export
    Pipeline script from SCM > Git
    Repository: ${FLUTTER_REPO_URL}
    Script Path: Jenkinsfile.unity-export

${BOLD}Step 8 — Create Flutter Multibranch Pipeline${RESET}
  New Item > Multibranch Pipeline
    Name: ${APP_NAME}
    Branch Sources: Git / GitHub
    Repository: ${FLUTTER_REPO_URL}
    Build Configuration: Jenkinsfile (auto-detected)

${BOLD}Step 9 — Install HeadlessExporter in Unity project${RESET}
  Copy ${REPO_ROOT}/unity/HeadlessExporter.cs
  into <YOUR_UNITY_PROJECT>/Assets/Editor/HeadlessExporter.cs
  Commit and push to: ${UNITY_REPO_URL}

${BOLD}Step 10 — Add flutter_embed_unity to Flutter project${RESET}
  pubspec.yaml:
    flutter_embed_unity: ^2.1.0
  Run: flutter pub get
  Follow the flutter_embed_unity README for android/ Gradle integration.

CHECKLIST

# ── Optionally start docker-compose ───────────────────────────────────────────
header "Start Docker Services"

echo -e -n "${BOLD}Start Jenkins controller now via docker-compose? [Y/n]: ${RESET}"
read -r start_docker

if [[ ! "${start_docker}" =~ ^[Nn]$ ]]; then
    if command -v docker-compose &>/dev/null; then
        info "Starting Jenkins controller..."
        (cd "${REPO_ROOT}/docker" && docker-compose up -d jenkins)
        success "Jenkins controller starting — open http://localhost:8080"
        info "Tail logs: docker-compose -f ${REPO_ROOT}/docker/docker-compose.yml logs -f jenkins"
        warn "Complete Steps 2-5 of the checklist above before starting the flutter-agent."
    else
        warn "docker-compose not found. Start manually:"
        echo "  cd ${REPO_ROOT}/docker && docker-compose up -d jenkins"
    fi
else
    info "Skipped. Start manually when ready:"
    echo "  cd ${REPO_ROOT}/docker && docker-compose up -d jenkins"
fi

echo ""
success "setup.sh complete. Follow the checklist above to finish Jenkins configuration."
