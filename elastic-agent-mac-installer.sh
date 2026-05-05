#!/bin/bash

# ── Dry Run Flag ──────────────────────────────────────────────────────────────
DRY_RUN=false
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done
 
# ── Configuration ─────────────────────────────────────────────────────────────
ELASTIC_VERSION="9.3.0"
FLEET_URL="https://c29103dc6bc0466389c4ad07f2600d26.fleet.ap-south-1.aws.elastic-cloud.com:443"
ENROLLMENT_TOKEN="Uldac3NKMEIwT3o5ZjRYVVZJcnI6RzdJeWgzc2RobDY2dGFVQUU4VHVjdw=="
INSTALL_DIR="/Library/Elastic/Agent"
TMP_DIR="/tmp/elastic_agent_install"
LOG_FILE="/var/log/elastic_agent_deploy.log"
 
# ── Logging ───────────────────────────────────────────────────────────────────
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}
 
info()    { log "INFO " "$*"; }
success() { log "OK   " "$*"; }
warn()    { log "WARN " "$*"; }
error()   { log "ERROR" "$*"; exit 1; }
 
# ── Detect Architecture ───────────────────────────────────────────────────────
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        arm64)   echo "aarch64" ;;
        x86_64)  echo "x86_64"  ;;
        *)       error "Unsupported architecture: $arch" ;;
    esac
}
 
# ── Detect macOS Version ──────────────────────────────────────────────────────
detect_macos_version() {
    local version
    version=$(sw_vers -productVersion)
    echo "$version"
}
 
get_macos_major() {
    sw_vers -productVersion | cut -d. -f1
}
 
get_macos_name() {
    local major
    major=$(get_macos_major)
    case "$major" in
        15) echo "Sequoia"  ;;
        14) echo "Sonoma"   ;;
        13) echo "Ventura"  ;;
        12) echo "Monterey" ;;
        11) echo "Big Sur"  ;;
        10) echo "Catalina or older" ;;
        *)  echo "Unknown"  ;;
    esac
}
 
# ── Check Minimum macOS Requirement ──────────────────────────────────────────
check_macos_compatibility() {
    local major
    major=$(get_macos_major)
    if [ "$major" -lt 11 ]; then
        error "macOS $(detect_macos_version) is not supported. Requires macOS 11 (Big Sur) or later."
    fi
}
 
# ── Build Download URL ────────────────────────────────────────────────────────
build_download_url() {
    local arch="$1"
    echo "https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-${ELASTIC_VERSION}-darwin-${arch}.tar.gz"
}
 
# ── Check if Already Installed ────────────────────────────────────────────────
is_already_installed() {
    if [ -f "${INSTALL_DIR}/elastic-agent" ]; then
        local installed_version
        installed_version=$("${INSTALL_DIR}/elastic-agent" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if [ "$installed_version" = "$ELASTIC_VERSION" ]; then
            return 0
        fi
    fi
    return 1
}
 
# ── Check if Running as Root ──────────────────────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root (sudo). Current user: $(whoami)"
    fi
}
 
# ── Download Agent ────────────────────────────────────────────────────────────
download_agent() {
    local url="$1"
    local dest="$2"
 
    if $DRY_RUN; then
        info "[DRY RUN] Would download from: $url"
        info "[DRY RUN] Would save to: $dest"
        return
    fi
 
    info "Downloading Elastic Agent from: $url"
 
    if command -v curl &>/dev/null; then
        curl -fsSL --retry 3 --retry-delay 5 -o "$dest" "$url" \
            || error "Download failed. Check URL or network connectivity."
    elif command -v wget &>/dev/null; then
        wget -q --tries=3 -O "$dest" "$url" \
            || error "Download failed via wget."
    else
        error "Neither curl nor wget found. Cannot download agent."
    fi
 
    success "Download complete: $dest"
}
 
# ── Extract & Install ─────────────────────────────────────────────────────────
extract_and_install() {
    local tarball="$1"
 
    if $DRY_RUN; then
        info "[DRY RUN] Would extract: $tarball"
        info "[DRY RUN] Would run: ./elastic-agent install --url=$FLEET_URL --enrollment-token=*** --non-interactive"
        return
    fi
 
    info "Extracting agent package..."
    mkdir -p "$TMP_DIR"
    tar -xzf "$tarball" -C "$TMP_DIR" \
        || error "Extraction failed for: $tarball"
 
    local extracted_dir
    extracted_dir=$(find "$TMP_DIR" -maxdepth 1 -type d -name "elastic-agent-*" | head -1)
 
    if [ -z "$extracted_dir" ]; then
        error "Could not locate extracted Elastic Agent directory in $TMP_DIR"
    fi
 
    info "Running Elastic Agent installer..."
    cd "$extracted_dir" || error "Cannot cd into $extracted_dir"
 
    ./elastic-agent install \
        --url="$FLEET_URL" \
        --enrollment-token="$ENROLLMENT_TOKEN" \
        --non-interactive \
        || error "Elastic Agent installation failed."
 
    success "Elastic Agent installed successfully."
}
 
# ── Verify Service ────────────────────────────────────────────────────────────
verify_service() {
    if $DRY_RUN; then
        info "[DRY RUN] Would verify service via: launchctl list | grep co.elastic.elastic-agent"
        return
    fi
 
    info "Verifying Elastic Agent service..."
    sleep 5
 
    if launchctl list | grep -q "co.elastic.elastic-agent"; then
        success "Elastic Agent service is running."
    else
        warn "Elastic Agent service not found in launchctl. Check logs at: /Library/Elastic/Agent/data/elastic-agent-*/logs/"
    fi
}
 
# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
    if $DRY_RUN; then
        info "[DRY RUN] Would clean up: $TMP_DIR"
        return
    fi
 
    info "Cleaning up temporary files..."
    rm -rf "$TMP_DIR"
}
 
# ── Uninstall (optional helper) ───────────────────────────────────────────────
uninstall_agent() {
    if $DRY_RUN; then
        if [ -f "${INSTALL_DIR}/elastic-agent" ]; then
            info "[DRY RUN] Would uninstall existing agent at: $INSTALL_DIR"
        else
            info "[DRY RUN] No existing agent found at: $INSTALL_DIR"
        fi
        return
    fi
 
    if [ -f "${INSTALL_DIR}/elastic-agent" ]; then
        info "Uninstalling existing Elastic Agent..."
        "${INSTALL_DIR}/elastic-agent" uninstall --non-interactive \
            && success "Previous version uninstalled." \
            || warn "Uninstall returned non-zero. Proceeding anyway."
    fi
}
 
# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
    info "========================================="
    info " Elastic Agent Deployment Script"
    $DRY_RUN && info " *** DRY RUN MODE — No changes will be made ***"
    info "========================================="
 
    check_root
 
    local arch macos_ver macos_name
    arch=$(detect_arch)
    macos_ver=$(detect_macos_version)
    macos_name=$(get_macos_name)
 
    info "Hostname     : $(hostname)"
    info "macOS Version: $macos_ver ($macos_name)"
    info "Architecture : $arch ($(uname -m))"
    info "Elastic Ver  : $ELASTIC_VERSION"
 
    check_macos_compatibility
 
    if is_already_installed; then
        success "Elastic Agent $ELASTIC_VERSION is already installed. Nothing to do."
        exit 0
    fi
 
    uninstall_agent
 
    local download_url
    download_url=$(build_download_url "$arch")
 
    local tarball="${TMP_DIR}/elastic-agent.tar.gz"
    mkdir -p "$TMP_DIR"
 
    download_agent "$download_url" "$tarball"
    extract_and_install "$tarball"
    verify_service
    cleanup
 
    info "========================================="
    $DRY_RUN && success "DRY RUN complete on $macos_name ($macos_ver) [$arch] — No changes made." \
             || success "Deployment complete on $macos_name ($macos_ver) [$arch]"
    info "========================================="
}
 
main "$@"
