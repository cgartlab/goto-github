#!/usr/bin/env bash
# =============================================================================
# GoToGitHub — One-line installer
# Downloads fetch.sh and sets up the goto-github command in ~/.local/bin.
# No sudo required.
# =============================================================================
# Usage:
#   curl -sfL https://raw.githubusercontent.com/USER/repo/main/install.sh | bash
#   ./install.sh --uninstall
#   ./install.sh --version
#   ./install.sh --update
# =============================================================================

set -euo pipefail

VERSION="1.0.0"
REPO_URL="https://raw.githubusercontent.com/USER/repo/main/fetch.sh"

INSTALL_DIR="${HOME}/.local/share/goto-github"
BIN_DIR="${HOME}/.local/bin"
SYMLINK="${BIN_DIR}/goto-github"
SCRIPT_PATH="${INSTALL_DIR}/fetch.sh"
VERSION_FILE="${INSTALL_DIR}/VERSION"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Install ──────────────────────────────────────────────────────────────────
do_install() {
    log_info "Creating directories..."
    mkdir -p "${INSTALL_DIR}"
    mkdir -p "${BIN_DIR}"

    log_info "Downloading fetch.sh from ${REPO_URL}..."
    curl -sfL "${REPO_URL}" -o "${SCRIPT_PATH}"

    log_info "Validating syntax..."
    bash -n "${SCRIPT_PATH}"

    chmod +x "${SCRIPT_PATH}"

    log_info "Creating symlink..."
    ln -sf "${SCRIPT_PATH}" "${SYMLINK}"

    printf "%s\n" "${VERSION}" > "${VERSION_FILE}"

    echo ""
    log_info "✅ Installed to ${SYMLINK}"
    echo ""
    echo "  Quick install:  curl -sfL https://raw.githubusercontent.com/USER/repo/main/install.sh | bash"
    echo "  Quick uninstall: ${SYMLINK} --uninstall"
    echo ""
    echo "  Add ${BIN_DIR} to your PATH if not already:"
    echo "    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
    echo "    source ~/.bashrc"
    echo ""
}

# ── Uninstall ────────────────────────────────────────────────────────────────
do_uninstall() {
    if [ -L "${SYMLINK}" ]; then
        rm -f "${SYMLINK}"
        log_info "Removed symlink: ${SYMLINK}"
    else
        log_info "No symlink found at ${SYMLINK}"
    fi

    if [ -d "${INSTALL_DIR}" ]; then
        rm -rf "${INSTALL_DIR}"
        log_info "Removed directory: ${INSTALL_DIR}"
    else
        log_info "No installation directory found at ${INSTALL_DIR}"
    fi

    echo ""
    log_info "✅ GoToGitHub has been uninstalled."
}

# ── Version ──────────────────────────────────────────────────────────────────
do_version() {
    if [ -f "${VERSION_FILE}" ]; then
        installed_version="$(cat "${VERSION_FILE}")"
        echo "GoToGitHub v${installed_version}"
        log_info "Installed at: ${SYMLINK}"
    else
        echo "GoToGitHub — not installed"
        log_info "Install with: curl -sfL https://raw.githubusercontent.com/USER/repo/main/install.sh | bash"
    fi
}

# ── Update ───────────────────────────────────────────────────────────────────
do_update() {
    if [ ! -f "${SCRIPT_PATH}" ]; then
        log_error "GoToGitHub is not installed. Run install.sh without flags to install."
        exit 1
    fi

    log_info "Updating from ${REPO_URL}..."

    curl -sfL "${REPO_URL}" -o "${SCRIPT_PATH}.tmp"

    bash -n "${SCRIPT_PATH}.tmp"

    mv "${SCRIPT_PATH}.tmp" "${SCRIPT_PATH}"
    chmod +x "${SCRIPT_PATH}"
    printf "%s\n" "${VERSION}" > "${VERSION_FILE}"

    log_info "✅ Updated to v${VERSION}"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in
        --uninstall)
            do_uninstall
            ;;
        --version|-v)
            do_version
            ;;
        --update)
            do_update
            ;;
        --help|-h)
            echo "Usage: $(basename "$0") [OPTION]"
            echo ""
            echo "  (no flags)    Install goto-github to ~/.local/bin"
            echo "  --uninstall   Remove goto-github and its files"
            echo "  --version,-v  Show installed version or 'not installed'"
            echo "  --update      Re-download and replace fetch.sh"
            echo "  --help,-h     Show this help"
            echo ""
            echo "Quick install:"
            echo "  curl -sfL https://raw.githubusercontent.com/USER/repo/main/install.sh | bash"
            echo ""
            echo "Or manually:"
            echo "  curl -sfL ${REPO_URL} -o ${SCRIPT_PATH}"
            echo "  chmod +x ${SCRIPT_PATH}"
            echo "  ln -sf ${SCRIPT_PATH} ${SYMLINK}"
            echo ""
            ;;
        "")
            do_install
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Usage: $(basename "$0") [--uninstall|--version|--update|--help]"
            exit 1
            ;;
    esac
}

main "$@"
