#!/usr/bin/env bash
# =============================================================================
# GoToGitHub — One-line installer with mirror fallback
# Downloads fetch.sh + its lib/ modules and sets up the goto-github command in
# ~/.local/bin. Supports multiple mirror sources for regions with GitHub
# access issues.
# =============================================================================
# Usage:
#   curl -sfL https://raw.githubusercontent.com/cgartlab/goto-github/main/install.sh | bash
#   curl -sfL https://cdn.jsdelivr.net/gh/cgartlab/goto-github@main/install.sh | bash
#   ./install.sh --uninstall
#   ./install.sh --version
#   ./install.sh --update
# =============================================================================

set -euo pipefail

VERSION="1.0.0"

# Mirror base URLs (repo root, no trailing file path), tried in order.
# Override with: export GOTO_GITHUB_MIRRORS="base1 base2 ..."
# For backwards compatibility, a trailing "/fetch.sh" on an entry is stripped.
if [ -n "${GOTO_GITHUB_MIRRORS:-}" ]; then
    IFS=' ' read -r -a MIRRORS <<< "${GOTO_GITHUB_MIRRORS}"
else
    MIRRORS=(
        "https://raw.githubusercontent.com/cgartlab/goto-github/main"
        "https://cdn.jsdelivr.net/gh/cgartlab/goto-github@main"
        "https://ghproxy.com/https://raw.githubusercontent.com/cgartlab/goto-github/main"
    )
fi
# Normalise each mirror to a base URL (strip a trailing /fetch.sh if present).
_normalised=()
for _m in "${MIRRORS[@]}"; do
    _normalised+=("${_m%/fetch.sh}")
done
MIRRORS=("${_normalised[@]}")
unset _normalised _m

INSTALL_DIR="${HOME}/.local/share/goto-github"
LIB_DIR="${INSTALL_DIR}/lib"
BIN_DIR="${HOME}/.local/bin"
SYMLINK="${BIN_DIR}/goto-github"
SCRIPT_PATH="${INSTALL_DIR}/fetch.sh"
CURL_RETRY_OPTS=(--retry 3 --retry-all-errors --retry-delay 2 --retry-max-time 60)
VERSION_FILE="${INSTALL_DIR}/VERSION"

# fetch.sh sources these modules; they must ship alongside it.
LIB_MODULES=(00-constants 01-utils 02-fetch 03-validate 04-apply)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Download one repo file with mirror fallback ──────────────────────────────
# download_file <repo-relative-path> <destination>
download_file() {
    local rel="$1" dest="$2" base url tmp
    tmp="${dest}.tmp"
    for base in "${MIRRORS[@]}"; do
        url="${base}/${rel}"
        log_info "  Attempting: $url"
        if curl -sfL "${CURL_RETRY_OPTS[@]}" --connect-timeout 10 --max-time 30 "$url" -o "$tmp" 2>/dev/null; then
            if bash -n "$tmp" 2>/dev/null; then
                mv "$tmp" "$dest"
                log_info "  ✓ ${rel}"
                return 0
            fi
            log_warn "  ✗ invalid syntax: ${url}"
            rm -f "$tmp"
        else
            log_warn "  ✗ failed: ${url}"
            rm -f "$tmp"
        fi
    done
    return 1
}

# ── Install ──────────────────────────────────────────────────────────────────
do_install() {
    log_info "Creating directories..."
    mkdir -p "${INSTALL_DIR}"
    mkdir -p "${LIB_DIR}"
    mkdir -p "${BIN_DIR}"

    log_info "Downloading fetch.sh + lib/ modules..."
    log_info "Trying mirror sources..."

    if ! download_file "fetch.sh" "${SCRIPT_PATH}"; then
        log_error "Failed to download fetch.sh from all mirrors."
        echo ""
        echo "  Alternative: Download manually from GitHub:"
        echo "    mkdir -p ${INSTALL_DIR}/lib"
        echo "    curl -L https://github.com/cgartlab/goto-github/raw/main/fetch.sh -o ${SCRIPT_PATH}"
        for _mod in "${LIB_MODULES[@]}"; do
            echo "    curl -L https://github.com/cgartlab/goto-github/raw/main/lib/${_mod}.sh -o ${LIB_DIR}/${_mod}.sh"
        done
        echo "    chmod +x ${SCRIPT_PATH}"
        echo "    ln -sf ${SCRIPT_PATH} ${SYMLINK}"
        echo ""
        exit 1
    fi

    local mod
    for mod in "${LIB_MODULES[@]}"; do
        if ! download_file "lib/${mod}.sh" "${LIB_DIR}/${mod}.sh"; then
            log_error "Failed to download lib/${mod}.sh from all mirrors."
            exit 1
        fi
    done

    chmod +x "${SCRIPT_PATH}"

    log_info "Creating symlink..."
    ln -sf "${SCRIPT_PATH}" "${SYMLINK}"

    printf "%s\n" "${VERSION}" > "${VERSION_FILE}"

    echo ""
    log_info "✅ Installed to ${SYMLINK}"
    echo ""
    echo "  Quick install:  curl -sfL https://raw.githubusercontent.com/cgartlab/goto-github/main/install.sh | bash"
    echo "  Quick install (mirror): curl -sfL https://cdn.jsdelivr.net/gh/cgartlab/goto-github@main/install.sh | bash"
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
    echo ""
    log_warn "提示: 卸载不会移除 /etc/hosts 中的 goto-github 条目。"
    log_warn "如需清理，请先重新安装后运行: sudo goto-github --restore"
    echo ""
}

# ── Version ──────────────────────────────────────────────────────────────────
do_version() {
    if [ -f "${VERSION_FILE}" ]; then
        installed_version="$(cat "${VERSION_FILE}")"
        echo "GoToGitHub v${installed_version}"
        log_info "Installed at: ${SYMLINK}"
    else
        echo "GoToGitHub — not installed"
        log_info "Install with: curl -sfL https://raw.githubusercontent.com/cgartlab/goto-github/main/install.sh | bash"
    fi
}

# ── Update ───────────────────────────────────────────────────────────────────
do_update() {
    if [ ! -f "${SCRIPT_PATH}" ]; then
        log_error "GoToGitHub is not installed. Run install.sh without flags to install."
        exit 1
    fi

    log_info "Updating fetch.sh + lib/ modules..."
    log_info "Trying mirror sources..."

    mkdir -p "${LIB_DIR}"

    if ! download_file "fetch.sh" "${SCRIPT_PATH}"; then
        log_error "Failed to update fetch.sh from all mirrors. Update aborted."
        exit 1
    fi

    local mod
    for mod in "${LIB_MODULES[@]}"; do
        if ! download_file "lib/${mod}.sh" "${LIB_DIR}/${mod}.sh"; then
            log_error "Failed to update lib/${mod}.sh from all mirrors. Update aborted."
            exit 1
        fi
    done

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
            echo "  --update      Re-download and replace fetch.sh + lib/"
            echo "  --help,-h     Show this help"
            echo ""
            echo "Quick install:"
            echo "  curl -sfL https://raw.githubusercontent.com/cgartlab/goto-github/main/install.sh | bash"
            echo ""
            echo "Or manually:"
            echo "  curl -sfL https://raw.githubusercontent.com/cgartlab/goto-github/main/fetch.sh -o ${SCRIPT_PATH}"
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
