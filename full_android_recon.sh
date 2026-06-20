#!/data/data/com.termux/files/usr/bin/bash
#
# full_android_recon.sh
# Production-grade, root-aware network reconnaissance script for Termux on Android.
# Supports both rooted and non-rooted environments with automatic fallback.
# Optimized for reliability, logging, and clean output structure.
#
# Usage: bash full_android_recon.sh [CIDR_TARGET]
# Example: bash full_android_recon.sh 192.168.1.0/24
#
# Features:
# - Automatic root detection (tsu / su / filesystem indicators)
# - Conditional nmap scan types: -sS -sV -O (root) vs -sT -sV (no root)
# - Bettercap installation with build fallback
# - Structured output directory with timestamp
# - Comprehensive logging
# - Resilient error handling (continues on non-fatal failures)
# - Termux-specific storage and package management
#

set -o pipefail
shopt -s extglob

# ====================== CONFIGURATION ======================
TARGET="${1:-192.168.1.0/24}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTDIR="recon_${TIMESTAMP}"
LOGFILE="${OUTDIR}/recon.log"
LIVE_HOSTS="${OUTDIR}/live_hosts.txt"
SUMMARY="${OUTDIR}/summary.txt"
BETTERCAP_BIN="${HOME}/go/bin/bettercap"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ====================== LOGGING FUNCTIONS ======================
log() {
    local msg="[$(date '+%H:%M:%S')] [+] $1"
    echo -e "${BLUE}${msg}${NC}"
    echo "$msg" >> "$LOGFILE"
}

warn() {
    local msg="[$(date '+%H:%M:%S')] [-] $1"
    echo -e "${YELLOW}${msg}${NC}"
    echo "$msg" >> "$LOGFILE"
}

error() {
    local msg="[$(date '+%H:%M:%S')] [!] $1"
    echo -e "${RED}${msg}${NC}"
    echo "$msg" >> "$LOGFILE"
}

success() {
    local msg="[$(date '+%H:%M:%S')] [✓] $1"
    echo -e "${GREEN}${msg}${NC}"
    echo "$msg" >> "$LOGFILE"
}

# ====================== ROOT DETECTION ======================
is_rooted() {
    # Check tsu (Termux superuser)
    if command -v tsu >/dev/null 2>&1; then
        if timeout 3 tsu -c 'id -u' 2>/dev/null | grep -q '^0$'; then
            return 0
        fi
    fi

    # Check native su
    if command -v su >/dev/null 2>&1; then
        if timeout 3 su -c 'id -u' 2>/dev/null | grep -q '^0$'; then
            return 0
        fi
    fi

    # Filesystem indicators (common on rooted Android)
    for su_path in /sbin/su /system/xbin/su /system/bin/su /system/xbin/daemonsu /system/bin/.ext/.su; do
        if [ -f "$su_path" ] || [ -L "$su_path" ]; then
            return 0
        fi
    done

    # Check for Magisk / KernelSU indicators (non-exhaustive)
    if [ -d /data/adb/magisk ] || [ -f /data/adb/magisk.db ] || [ -d /data/adb/ksu ]; then
        return 0
    fi

    return 1
}

# ====================== INITIALIZATION ======================
mkdir -p "$OUTDIR" || {
    echo "FATAL: Cannot create output directory $OUTDIR"
    exit 1
}

# Initialize log
: > "$LOGFILE"

log "=== full_android_recon.sh starting ==="
log "Target CIDR: $TARGET"
log "Output directory: $OUTDIR"
log "Log file: $LOGFILE"

# Termux environment check
if [ -z "${PREFIX:-}" ] || [[ "$PREFIX" != */com.termux/* ]]; then
    error "This script must be executed inside Termux on Android."
    exit 1
fi
success "Termux environment confirmed."

# Root status
if is_rooted; then
    ROOTED=true
    success "Root privileges detected. Full scan capabilities enabled."
else
    ROOTED=false
    warn "No root privileges detected. Falling back to non-privileged scan modes (TCP connect scan, limited Bettercap features)."
fi

echo "ROOTED=${ROOTED}" > "${OUTDIR}/config.env"

# ====================== TERMUX STORAGE ======================
if [ ! -d "$HOME/storage" ]; then
    log "Configuring Termux storage access..."
    if command -v termux-setup-storage >/dev/null 2>&1; then
        termux-setup-storage || warn "termux-setup-storage returned non-zero (may already be configured)."
    fi
else
    log "Termux storage already configured."
fi

# ====================== PACKAGE MANAGEMENT ======================
log "Updating package lists and upgrading existing packages..."
pkg update -y >> "$LOGFILE" 2>&1 || warn "pkg update completed with warnings."
pkg upgrade -y >> "$LOGFILE" 2>&1 || warn "pkg upgrade completed with warnings."

CORE_PACKAGES=(
    golang
    git
    libpcap
    libusb
    pkg-config
    nmap
    iw
    aircrack-ng
    tsu
    root-repo
    termux-api
    curl
    wget
)

for pkg in "${CORE_PACKAGES[@]}"; do
    if pkg list-installed 2>/dev/null | grep -q "^${pkg}/"; then
        log "Package already installed: $pkg"
    else
        log "Installing package: $pkg"
        if ! pkg install -y "$pkg" >> "$LOGFILE" 2>&1; then
            warn "Failed to install $pkg. Some functionality may be degraded."
        fi
    fi
done

# ====================== BETTERCAP INSTALLATION ======================
log "Preparing Bettercap..."

export GOPATH="${HOME}/go"
export GO111MODULE=on
export PATH="${GOPATH}/bin:${PATH}"
mkdir -p "${GOPATH}/bin"

if [ -f "$BETTERCAP_BIN" ] && [ -x "$BETTERCAP_BIN" ]; then
    success "Bettercap binary already present and executable."
else
    log "Installing Bettercap via go install (github.com/bettercap/bettercap@latest)..."
    if go install github.com/bettercap/bettercap@latest >> "$LOGFILE" 2>&1; then
        success "Bettercap installed successfully via go install."
    else
        warn "Primary go install failed. Attempting source build fallback..."
        
        BETTERCAP_SRC="${HOME}/bettercap-src"
        if [ ! -d "$BETTERCAP_SRC" ]; then
            log "Cloning Bettercap repository..."
            if ! git clone --depth 1 https://github.com/bettercap/bettercap.git "$BETTERCAP_SRC" >> "$LOGFILE" 2>&1; then
                error "Git clone failed. Bettercap will be unavailable."
            fi
        fi
        
        if [ -d "$BETTERCAP_SRC" ]; then
            cd "$BETTERCAP_SRC" || exit 1
            log "Building Bettercap from source..."
            if go build -ldflags="-s -w" -o "$BETTERCAP_BIN" . >> "$LOGFILE" 2>&1; then
                success "Bettercap built from source successfully."
            else
                error "Source build failed. Bettercap unavailable for this session."
            fi
            cd - >/dev/null || true
        fi
    fi
fi

if [ -f "$BETTERCAP_BIN" ]; then
    chmod +x "$BETTERCAP_BIN" 2>/dev/null || true
    log "Bettercap ready at: $BETTERCAP_BIN"
    echo "BETTERCAP_PATH=${BETTERCAP_BIN}" >> "${OUTDIR}/config.env"
else
    warn "Bettercap binary not found. WiFi/BLE recon will be skipped."
fi

# ====================== PHASE 1: HOST DISCOVERY ======================
log "=== Phase 1: Host Discovery ==="

# -sn works without root (uses ARP + ICMP echo where possible)
if nmap -sn -T4 --max-retries 2 "$TARGET" -oG "${OUTDIR}/discovery.grep" >> "$LOGFILE" 2>&1; then
    success "Host discovery completed."
else
    warn "Nmap discovery returned non-zero. Checking partial results..."
fi

# Extract live hosts
grep "Status: Up" "${OUTDIR}/discovery.grep" 2>/dev/null | awk '{print $2}' | sort -u > "$LIVE_HOSTS" || true

LIVE_COUNT=$(wc -l < "$LIVE_HOSTS" 2>/dev/null || echo 0)
log "Live hosts discovered: $LIVE_COUNT"

if [ "$LIVE_COUNT" -eq 0 ]; then
    warn "No live hosts found in target range. Exiting."
    echo "LIVE_HOSTS=0" >> "${OUTDIR}/config.env"
    exit 0
fi

cat "$LIVE_HOSTS" | tee -a "$LOGFILE"

# ====================== PHASE 2: PORT + SERVICE SCAN ======================
log "=== Phase 2: Port Scan + Service Enumeration ==="

if $ROOTED; then
    NMAP_SCAN_TYPE="-sS -sV -O"
    NMAP_EXTRA="--min-rate 800 --max-retries 2 -T4 -p-"
    log "Using privileged scan profile: SYN + Version + OS detection (full port range)"
else
    NMAP_SCAN_TYPE="-sT -sV"
    NMAP_EXTRA="--top-ports 4000 -T4 --max-retries 1"
    log "Using non-privileged scan profile: TCP Connect + Version detection (top 4000 ports)"
    warn "OS fingerprinting disabled (requires raw socket privileges)."
fi

while IFS= read -r host; do
    [ -z "$host" ] && continue
    log "Scanning host: $host"
    
    HOST_LOG="${OUTDIR}/nmap_${host//./_}.log"
    HOST_NMAP="${OUTDIR}/nmap_${host//./_}.txt"
    
    if nmap $NMAP_SCAN_TYPE $NMAP_EXTRA \
        --open \
        -oN "$HOST_NMAP" \
        -oG "${OUTDIR}/nmap_${host//./_}.grep" \
        "$host" >> "$HOST_LOG" 2>&1; then
        success "Nmap scan completed for $host → $HOST_NMAP"
    else
        warn "Nmap scan for $host completed with warnings (see $HOST_LOG)"
    fi
done < "$LIVE_HOSTS"

# ====================== PHASE 3: BETTERCAP RECON ======================
if [ -f "$BETTERCAP_BIN" ]; then
    log "=== Phase 3: Bettercap Recon (WiFi / BLE / Network) ==="
    
    BETTERCAP_OUT="${OUTDIR}/bettercap_recon.txt"
    
    if $ROOTED; then
        log "Running Bettercap with elevated privileges (full feature set)..."
        BETTERCAP_CMD="tsu -c '$BETTERCAP_BIN'"
    else
        log "Running Bettercap without root (limited to user-space features)..."
        BETTERCAP_CMD="$BETTERCAP_BIN"
        warn "WiFi monitor mode and raw packet features will be unavailable or limited."
    fi
    
    # Non-interactive recon session (safe timeout)
    log "Executing timed Bettercap recon session (30s)..."
    if timeout 35s bash -c "
        $BETTERCAP_CMD -eval '
            set net.recon on;
            sleep 3;
            net.show;
            wifi.recon on;
            sleep 8;
            wifi.show;
            ble.recon on;
            sleep 5;
            ble.show;
            net.probe on;
            sleep 4;
            quit
        ' 
    " > "$BETTERCAP_OUT" 2>&1; then
        success "Bettercap recon session completed. Output: $BETTERCAP_OUT"
    else
        warn "Bettercap session timed out or exited with error. Partial output may exist in $BETTERCAP_OUT"
    fi
    
    # Also provide interactive hint
    echo "Interactive Bettercap command:" > "${OUTDIR}/bettercap_interactive.txt"
    if $ROOTED; then
        echo "tsu -c '$BETTERCAP_BIN'" >> "${OUTDIR}/bettercap_interactive.txt"
    else
        echo "$BETTERCAP_BIN" >> "${OUTDIR}/bettercap_interactive.txt"
    fi
else
    warn "Skipping Bettercap phase (binary not available)."
fi

# ====================== FINAL SUMMARY ======================
log "=== Generating final summary ==="

{
    echo "=== ANDROID TERMUX RECONNAISSANCE REPORT ==="
    echo "Generated: $(date)"
    echo "Target: $TARGET"
    echo "Rooted: $ROOTED"
    echo "Live hosts: $LIVE_COUNT"
    echo ""
    echo "Output files:"
    ls -1 "$OUTDIR" | sed 's/^/  /'
    echo ""
    echo "Key artifacts:"
    echo "  - live_hosts.txt"
    echo "  - nmap_<ip>.txt (per-host detailed scans)"
    echo "  - bettercap_recon.txt (if executed)"
    echo "  - discovery.grep / nmap_*.grep (grepable formats)"
} > "$SUMMARY"

success "Reconnaissance complete."
log "All results saved under: $(pwd)/$OUTDIR"
log "Review $SUMMARY for quick overview."
log "=== Script finished successfully ==="

exit 0