#!/usr/bin/env bash

# ═══════════════════════════════════════════════════════════════════════════════
#  Flow — macOS Installer
#  Downloads the latest release, installs Homebrew + dependencies, and copies
#  Flow.app into /Applications.
# ═══════════════════════════════════════════════════════════════════════════════

set -e

# ── Configuration ─────────────────────────────────────────────────────────────
APP_NAME="Flow"
DOWNLOAD_LINK_URL="https://visual.cs.brown.edu/flow/downloadlink.txt"
INSTALL_DIR="/Applications"
TMP_DIR="$(mktemp -d)"

# ── Helpers ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info() { echo -e "${CYAN}${BOLD}==>${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}  ✓${RESET} $*"; }
warn() { echo -e "${YELLOW}${BOLD}  !${RESET} $*"; }
die() {
    echo -e "${RED}${BOLD}  ✗ ERROR:${RESET} $*" >&2
    exit 1
}

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ── 0. Platform check ─────────────────────────────────────────────────────────
info "Checking system..."

[[ "$(uname)" == "Darwin" ]] || die "This installer is for macOS only."

# Require macOS 12+
OS_VER="$(sw_vers -productVersion)"
MAJOR="$(echo "$OS_VER" | cut -d. -f1)"
MINOR="$(echo "$OS_VER" | cut -d. -f2)"
if ((MAJOR < 12)); then
    die "Flow requires macOS 12.0 or later (you have ${OS_VER})."
fi
success "macOS ${OS_VER} detected."

# ── 1. Homebrew ───────────────────────────────────────────────────────────────
info "Checking for Homebrew..."

if command -v brew &>/dev/null; then
    success "Homebrew already installed ($(brew --version | head -1))."
else
    warn "Homebrew not found — installing now."
    warn "You may be prompted for your password."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add Homebrew to PATH for the rest of this script (Apple Silicon vs Intel)
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -f /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    command -v brew &>/dev/null || die "Homebrew installation failed."
    success "Homebrew installed successfully."
fi

# ── 2. Dependencies ───────────────────────────────────────────────────────────
DEPS=(
    shaderc        # GLSL/HLSL → SPIR-V compiler
    molten-vk      # Vulkan-on-Metal translation layer
    vulkan-loader  # Vulkan ICD loader
    vulkan-headers # Vulkan API headers
    glfw           # Window / input
    raylib         # Game/graphics library
    spirv-cross    # SPIR-V → Metal shader cross-compilation
)

info "Installing / verifying runtime dependencies..."

MISSING=()
for dep in "${DEPS[@]}"; do
    if brew list --formula "$dep" &>/dev/null; then
        success "${dep} already installed."
    else
        MISSING+=("$dep")
    fi
done

if ((${#MISSING[@]} > 0)); then
    info "Installing missing packages: ${MISSING[*]}"
    brew install "${MISSING[@]}"
    success "All dependencies installed."
else
    success "All dependencies already present."
fi

# ── 3. Download Flow.zip ──────────────────────────────────────────────────────
info "Fetching download URL..."

command -v curl &>/dev/null || die "curl is required but was not found."

GITHUB_DOWNLOAD_URL="$(curl -fsSL "$DOWNLOAD_LINK_URL" | tr -d '[:space:]')"
[[ -n "$GITHUB_DOWNLOAD_URL" ]] || die "Could not retrieve download URL from ${DOWNLOAD_LINK_URL}"
success "Download URL: ${GITHUB_DOWNLOAD_URL}"

info "Downloading ${APP_NAME}..."
ZIP_PATH="${TMP_DIR}/Flow.zip"
curl -fL --progress-bar "$GITHUB_DOWNLOAD_URL" -o "$ZIP_PATH" ||
    die "Download failed. Check your internet connection or the release URL:\n  ${GITHUB_DOWNLOAD_URL}"

success "Download complete."

# ── 4. Unzip ──────────────────────────────────────────────────────────────────
info "Extracting archive..."
unzip -q "$ZIP_PATH" -d "$TMP_DIR"

APP_BUNDLE="${TMP_DIR}/${APP_NAME}.app"
[[ -d "$APP_BUNDLE" ]] || die "${APP_NAME}.app not found inside the zip. The archive may be malformed."
success "Extraction complete."

# ── 5. Back up .ffsession files ───────────────────────────────────────────────
DEST="${INSTALL_DIR}/${APP_NAME}.app"
SESSION_BACKUP_DIR="${HOME}/Desktop/Flow_Sessions_Backup"
SESSION_FILES=()

# Determine the working directory of the installed executable, if it exists.
# The executable is expected at Contents/MacOS/Flow inside the app bundle.
EXISTING_EXEC="${DEST}/Contents/MacOS/${APP_NAME}"
if [[ -f "$EXISTING_EXEC" ]]; then
    EXEC_WORKDIR="${DEST}/Contents/Resources"
    # Collect any .ffsession files in that directory
    while IFS= read -r -d '' f; do
        SESSION_FILES+=("$f")
    done < <(find "$EXEC_WORKDIR" -maxdepth 1 -name "*.ffsession" -print0 2>/dev/null)
fi

if ((${#SESSION_FILES[@]} > 0)); then
    info "Backing up ${#SESSION_FILES[@]} .ffsession file(s) to Desktop..."
    mkdir -p "$SESSION_BACKUP_DIR"
    for f in "${SESSION_FILES[@]}"; do
        cp "$f" "$SESSION_BACKUP_DIR/"
        success "Backed up: $(basename "$f")"
    done
    success "Session files backed up to ${SESSION_BACKUP_DIR}."
else
    info "No .ffsession files found — skipping backup."
fi

# ── 6. Install into /Applications ────────────────────────────────────────────
info "Installing ${APP_NAME}.app to ${INSTALL_DIR}..."

# Remove previous installation if present
if [[ -d "$DEST" ]]; then
    warn "Existing installation found — replacing it."
    rm -rf "$DEST"
fi

# Try a direct move first; fall back to sudo if needed
if mv "$APP_BUNDLE" "$DEST" 2>/dev/null; then
    :
else
    warn "Moving to ${INSTALL_DIR} requires administrator privileges."
    sudo mv "$APP_BUNDLE" "$DEST"
fi

success "${APP_NAME}.app installed to ${DEST}."

# ── 7. Restore .ffsession files ───────────────────────────────────────────────
NEW_EXEC_WORKDIR="${DEST}/Contents/Resources"
if ((${#SESSION_FILES[@]} > 0)); then
    info "Restoring .ffsession files to new installation..."
    for f in "${SESSION_FILES[@]}"; do
        FNAME="$(basename "$f")"
        if cp "${SESSION_BACKUP_DIR}/${FNAME}" "${NEW_EXEC_WORKDIR}/"; then
            success "Restored: ${FNAME}"
        else
            warn "Could not restore ${FNAME} — it remains on your Desktop in ${SESSION_BACKUP_DIR}."
        fi
    done
    success "Session files restored to ${NEW_EXEC_WORKDIR}."
fi

# ── 8. Clear Gatekeeper quarantine ───────────────────────────────────────────
info "Removing Gatekeeper quarantine flag..."
# xattr -dr is safe to run even if the attribute is absent
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
success "Quarantine flag cleared."

# ── 9. Permissions ─────────────────────────────────────────────────────────────
xattr -cr /Applications/Flow.app

# ── 10. Done ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}✓ ${APP_NAME} has been installed successfully!${RESET}"
echo ""
echo -e "  Launch it from ${BOLD}Launchpad${RESET} or ${BOLD}Finder → Applications${RESET},"
echo -e "  or run:  ${CYAN}open '${DEST}'${RESET}"
echo ""
echo -e "${YELLOW}Note:${RESET} Because this app is not notarized by Apple, on first launch"
echo -e "macOS may still show a warning. If it does, right-click the app,"
echo -e "choose ${BOLD}Open${RESET}, then confirm in the dialog."
echo ""
