#!/usr/bin/env bash
set -euo pipefail

#===============================================================================
# Mirror Finder - Enhanced Version
# Checks mirror availability, measures latency, and generates ready-to-use configs
#===============================================================================

VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIRROR_FILE="$SCRIPT_DIR/mirrors_list.yaml"
MIRROR_URL=""
BACKUP_DIR="$HOME/.mirror-finder/backups"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
RESULTS_DIR="$SCRIPT_DIR/results/$TIMESTAMP"

# Default values
DISTRO=""
DISTRO_VERSION=""
CODENAME=""
AUTO_APPLY=false
INTERACTIVE=true
ROLLBACK=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

#===============================================================================
# Distro Version Mappings
#===============================================================================

declare -A UBUNTU_VERSIONS=(
  ["20.04"]="focal"
  ["22.04"]="jammy"
  ["24.04"]="noble"
)

declare -A DEBIAN_VERSIONS=(
  ["10"]="buster"
  ["11"]="bullseye"
  ["12"]="bookworm"
)

declare -A CENTOS_VERSIONS=(
  ["7"]="7"
  ["8"]="8"
  ["9"]="9-stream"
)

declare -A ALPINE_VERSIONS=(
  ["3.18"]="v3.18"
  ["3.19"]="v3.19"
  ["3.20"]="v3.20"
)

#===============================================================================
# Package Path Templates (with version placeholders)
#===============================================================================

declare -A PACKAGE_PATHS=(
  ["Ubuntu"]="ubuntu/dists/{codename}/Release"
  ["Debian"]="debian/dists/{codename}/Release"
  ["Arch Linux"]="archlinux/core/os/x86_64/core.db"
  ["PyPI"]="simple/"
  ["npm"]="-/ping"
  ["CentOS"]="centos/{version}/os/x86_64/repodata/repomd.xml"
  ["Rocky"]="rocky/{version}/BaseOS/x86_64/os/repodata/repomd.xml"
  ["Alpine"]="alpine/{version}/main/x86_64/APKINDEX.tar.gz"
  ["Fedora"]="fedora/releases/{version}/Everything/x86_64/os/repodata/repomd.xml"
  ["Composer"]="packages.json"
  ["Docker Registry"]="v2/"
  ["Homebrew"]="brew"
  ["Go"]="sumdb/sum.golang.org/supported"
  ["NuGet"]="v3/index.json"
)

# Arrays to store working mirrors
declare -a WORKING_APT_MIRRORS=()
declare -a WORKING_YUM_MIRRORS=()
declare -a WORKING_PIP_MIRRORS=()
declare -a WORKING_NPM_MIRRORS=()
declare -a WORKING_DOCKER_MIRRORS=()
declare -a WORKING_COMPOSER_MIRRORS=()
declare -a WORKING_GO_MIRRORS=()

# Arrays to store mirror latencies (for ranking)
declare -A MIRROR_LATENCIES=()

#===============================================================================
# Helper Functions
#===============================================================================

print_banner() {
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║                    🪞 Mirror Finder                              ║"
  echo "║                         Version $VERSION                           ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

print_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -d, --distro DISTRO       Target distribution (ubuntu, debian, centos, alpine, rocky, fedora)
  -v, --version VERSION     Distribution version (e.g., 22.04 for Ubuntu, 12 for Debian)
  -a, --auto-apply          Apply all configurations automatically (no prompts)
  -n, --non-interactive     Run without interactive prompts (just generate configs)
  -r, --rollback            Rollback to previous configuration from backup
  -h, --help                Show this help message
  --list-versions           List supported distro versions

Examples:
  $(basename "$0")                              # Auto-detect OS and check mirrors
  $(basename "$0") -d ubuntu -v 22.04           # Check mirrors for Ubuntu 22.04
  $(basename "$0") -d debian -v 12              # Check mirrors for Debian 12
  $(basename "$0") -d centos -v 9               # Check mirrors for CentOS 9
  $(basename "$0") --auto-apply                 # Check and apply all configs automatically
  $(basename "$0") --rollback                   # Restore previous configuration

EOF
}

print_versions() {
  echo -e "${CYAN}Supported Distribution Versions:${NC}"
  echo ""
  echo -e "${GREEN}Ubuntu:${NC}"
  for ver in "${!UBUNTU_VERSIONS[@]}"; do
    echo "  $ver (${UBUNTU_VERSIONS[$ver]})"
  done | sort -V
  echo ""
  echo -e "${GREEN}Debian:${NC}"
  for ver in "${!DEBIAN_VERSIONS[@]}"; do
    echo "  $ver (${DEBIAN_VERSIONS[$ver]})"
  done | sort -V
  echo ""
  echo -e "${GREEN}CentOS/Rocky:${NC}"
  for ver in "${!CENTOS_VERSIONS[@]}"; do
    echo "  $ver"
  done | sort -V
  echo ""
  echo -e "${GREEN}Alpine:${NC}"
  for ver in "${!ALPINE_VERSIONS[@]}"; do
    echo "  $ver (${ALPINE_VERSIONS[$ver]})"
  done | sort -V
}

log_info() {
  echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
  echo -e "${GREEN}✅${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}⚠️${NC} $1"
}

log_error() {
  echo -e "${RED}❌${NC} $1"
}

#===============================================================================
# Dependency Check
#===============================================================================

install_yq() {
  local yq_local="$SCRIPT_DIR/yq_linux_amd64"
  
  log_info "yq not found. Attempting to install..."
  
  # Check if local yq binary exists
  if [[ -f "$yq_local" ]]; then
    log_info "Found local yq binary, installing..."
    if sudo cp "$yq_local" /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq; then
      log_success "yq installed successfully from local file"
      return 0
    else
      log_warning "Failed to install with sudo, trying user-local install..."
      mkdir -p "$HOME/.local/bin"
      if cp "$yq_local" "$HOME/.local/bin/yq" && chmod +x "$HOME/.local/bin/yq"; then
        export PATH="$HOME/.local/bin:$PATH"
        log_success "yq installed to ~/.local/bin/yq"
        log_warning "Add this to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\""
        return 0
      fi
    fi
  fi
  
  # Try downloading if local file not available
  log_info "Downloading yq from GitHub..."
  local yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
  
  if sudo wget -q "$yq_url" -O /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq; then
    log_success "yq downloaded and installed successfully"
    return 0
  elif sudo curl -fsSL "$yq_url" -o /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq; then
    log_success "yq downloaded and installed successfully"
    return 0
  else
    # Try user-local install
    mkdir -p "$HOME/.local/bin"
    if wget -q "$yq_url" -O "$HOME/.local/bin/yq" && chmod +x "$HOME/.local/bin/yq"; then
      export PATH="$HOME/.local/bin:$PATH"
      log_success "yq installed to ~/.local/bin/yq"
      return 0
    elif curl -fsSL "$yq_url" -o "$HOME/.local/bin/yq" && chmod +x "$HOME/.local/bin/yq"; then
      export PATH="$HOME/.local/bin:$PATH"
      log_success "yq installed to ~/.local/bin/yq"
      return 0
    fi
  fi
  
  log_error "Failed to install yq automatically"
  return 1
}

check_dependencies() {
  local missing=()
  
  if ! command -v curl &> /dev/null; then
    missing+=("curl")
  fi
  
  # Check for yq, try to install if missing
  if ! command -v yq &> /dev/null; then
    if ! install_yq; then
      missing+=("yq")
    fi
  fi
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required dependencies: ${missing[*]}"
    echo ""
    echo "Install instructions:"
    for dep in "${missing[@]}"; do
      case $dep in
        curl)
          echo "  Ubuntu/Debian: sudo apt install curl"
          echo "  CentOS/Rocky:  sudo yum install curl"
          echo "  Alpine:        sudo apk add curl"
          ;;
        yq)
          echo "  All systems:   wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq && chmod +x /usr/local/bin/yq"
          ;;
      esac
    done
    exit 1
  fi
}

#===============================================================================
# OS Detection
#===============================================================================

detect_os() {
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    
    case "$ID" in
      ubuntu)
        DISTRO="ubuntu"
        DISTRO_VERSION="${VERSION_ID}"
        if [[ -v UBUNTU_VERSIONS["$DISTRO_VERSION"] ]]; then
          CODENAME="${UBUNTU_VERSIONS[$DISTRO_VERSION]}"
        else
          CODENAME="${UBUNTU_CODENAME:-}"
        fi
        ;;
      debian)
        DISTRO="debian"
        DISTRO_VERSION="${VERSION_ID}"
        if [[ -v DEBIAN_VERSIONS["$DISTRO_VERSION"] ]]; then
          CODENAME="${DEBIAN_VERSIONS[$DISTRO_VERSION]}"
        else
          CODENAME="${VERSION_CODENAME:-}"
        fi
        ;;
      centos|rocky|almalinux)
        DISTRO="centos"
        DISTRO_VERSION="${VERSION_ID%%.*}"
        CODENAME="${DISTRO_VERSION}"
        ;;
      fedora)
        DISTRO="fedora"
        DISTRO_VERSION="${VERSION_ID}"
        CODENAME="${VERSION_ID}"
        ;;
      alpine)
        DISTRO="alpine"
        DISTRO_VERSION="${VERSION_ID%.*}"
        if [[ -v ALPINE_VERSIONS["$DISTRO_VERSION"] ]]; then
          CODENAME="${ALPINE_VERSIONS[$DISTRO_VERSION]}"
        else
          CODENAME="v${DISTRO_VERSION}"
        fi
        ;;
      *)
        log_warning "Unknown distribution: $ID"
        log_info "Using generic checks. Specify --distro and --version for better results."
        DISTRO="generic"
        DISTRO_VERSION=""
        CODENAME=""
        ;;
    esac
    
    if [[ -n "$DISTRO" && "$DISTRO" != "generic" ]]; then
      log_info "Detected OS: $DISTRO $DISTRO_VERSION ($CODENAME)"
    fi
  else
    log_warning "Cannot detect OS (no /etc/os-release found)"
    DISTRO="generic"
  fi
}

#===============================================================================
# Download Mirror List
#===============================================================================

download_mirror_list() {
  if [[ ! -f "$MIRROR_FILE" ]]; then
    log_warning "mirrors_list.yaml not found. Downloading from repository..."
    if curl -fsSL "$MIRROR_URL" -o "$MIRROR_FILE"; then
      log_success "Successfully downloaded mirrors_list.yaml"
    else
      log_error "Failed to download mirrors_list.yaml"
      exit 1
    fi
  fi
}

#===============================================================================
# URL Check with Latency
#===============================================================================

check_url_with_latency() {
  local url=$1
  local start_time end_time elapsed status
  
  start_time=$(date +%s%N)
  status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")
  end_time=$(date +%s%N)
  
  elapsed=$(( (end_time - start_time) / 1000000 )) # Convert to milliseconds
  
  echo "$status|$elapsed"
}

check_docker_registry() {
  local url=$1
  local result status latency
  
  result=$(check_url_with_latency "$url/v2/")
  status="${result%%|*}"
  latency="${result##*|}"
  
  if [[ "$status" == "200" || "$status" == "401" ]]; then
    echo "OK|$latency"
  else
    echo "FAIL|$latency"
  fi
}

#===============================================================================
# Create Results Directory Structure
#===============================================================================

create_results_dir() {
  mkdir -p "$RESULTS_DIR/configs/apt"
  mkdir -p "$RESULTS_DIR/configs/yum"
  mkdir -p "$RESULTS_DIR/configs/pip"
  mkdir -p "$RESULTS_DIR/configs/npm"
  mkdir -p "$RESULTS_DIR/configs/docker"
  mkdir -p "$RESULTS_DIR/configs/composer"
  mkdir -p "$RESULTS_DIR/configs/go"
  
  log_info "Results will be saved to: $RESULTS_DIR"
}

#===============================================================================
# Generate APT Configuration
#===============================================================================

generate_apt_config() {
  if [[ ${#WORKING_APT_MIRRORS[@]} -eq 0 ]]; then
    return
  fi
  
  local config_file="$RESULTS_DIR/configs/apt/sources.list"
  local readme_file="$RESULTS_DIR/configs/apt/README.md"
  local distro_name="${DISTRO}"
  local codename="${CODENAME}"
  
  # Generate sources.list
  cat > "$config_file" << EOF
# Mirror Finder Configuration
# Generated: $TIMESTAMP
# Distribution: $distro_name $DISTRO_VERSION ($codename)
# 
# This file contains mirrors sorted by response time (fastest first)

EOF

  local rank=1
  for mirror_entry in "${WORKING_APT_MIRRORS[@]}"; do
    local mirror_url="${mirror_entry%%|*}"
    local mirror_name="${mirror_entry##*|}"
    local latency="${MIRROR_LATENCIES[$mirror_url]:-N/A}"
    
    if [[ "$distro_name" == "ubuntu" ]]; then
      cat >> "$config_file" << EOF
# Mirror #$rank: $mirror_name (${latency}ms)
deb $mirror_url/ubuntu $codename main restricted universe multiverse
deb $mirror_url/ubuntu $codename-updates main restricted universe multiverse
deb $mirror_url/ubuntu $codename-backports main restricted universe multiverse
deb $mirror_url/ubuntu $codename-security main restricted universe multiverse

EOF
    elif [[ "$distro_name" == "debian" ]]; then
      cat >> "$config_file" << EOF
# Mirror #$rank: $mirror_name (${latency}ms)
deb $mirror_url/debian $codename main contrib non-free
deb $mirror_url/debian $codename-updates main contrib non-free
deb $mirror_url/debian-security $codename-security main contrib non-free

EOF
    fi
    ((rank++))
  done

  # Generate README
  cat > "$readme_file" << 'EOF'
# APT Mirror Configuration

## What This Does
This `sources.list` file configures your APT package manager to use fast Iranian mirrors instead of default servers.

## Manual Setup

### Step 1: Backup Current Configuration
```bash
sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup
```

### Step 2: Copy New Configuration
```bash
sudo cp sources.list /etc/apt/sources.list
```

### Step 3: Update Package Lists
```bash
sudo apt update
```

### Step 4: Verify It Works
```bash
apt policy | head -20
```

## Automatic Setup
Run the following command to apply this configuration automatically:
```bash
./check_mirrors.sh --auto-apply
```

## Rollback to Original
If you experience issues, restore the backup:
```bash
sudo cp /etc/apt/sources.list.backup /etc/apt/sources.list
sudo apt update
```

Or use the rollback feature:
```bash
./check_mirrors.sh --rollback
```

## Troubleshooting
- If `apt update` fails, try the next mirror in the list
- Comment out problematic mirror lines with `#`
- Ensure your system clock is correct (SSL certificate validation)
EOF

  log_success "Generated APT configuration: $config_file"
}

#===============================================================================
# Generate YUM/DNF Configuration
#===============================================================================

generate_yum_config() {
  if [[ ${#WORKING_YUM_MIRRORS[@]} -eq 0 ]]; then
    return
  fi
  
  local config_file="$RESULTS_DIR/configs/yum/mirrors.repo"
  local readme_file="$RESULTS_DIR/configs/yum/README.md"
  
  # Generate repo file
  cat > "$config_file" << EOF
# Mirror Finder Configuration for YUM/DNF
# Generated: $TIMESTAMP
# Distribution: $DISTRO $DISTRO_VERSION

EOF

  local rank=1
  for mirror_entry in "${WORKING_YUM_MIRRORS[@]}"; do
    local mirror_url="${mirror_entry%%|*}"
    local mirror_name="${mirror_entry##*|}"
    local latency="${MIRROR_LATENCIES[$mirror_url]:-N/A}"
    
    cat >> "$config_file" << EOF
[mirror-finder-$rank]
name=Mirror $rank - $mirror_name (${latency}ms)
baseurl=$mirror_url/centos/\$releasever/os/\$basearch/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
priority=$rank

EOF
    ((rank++))
  done

  # Generate README
  cat > "$readme_file" << 'EOF'
# YUM/DNF Mirror Configuration

## What This Does
This `.repo` file configures YUM/DNF to use fast Iranian mirrors for CentOS/Rocky/AlmaLinux packages.

## Manual Setup

### Step 1: Backup Current Repos
```bash
sudo cp -r /etc/yum.repos.d /etc/yum.repos.d.backup
```

### Step 2: Copy New Configuration
```bash
sudo cp mirrors.repo /etc/yum.repos.d/
```

### Step 3: (Optional) Disable Default Repos
```bash
sudo sed -i 's/enabled=1/enabled=0/g' /etc/yum.repos.d/CentOS-*.repo
```

### Step 4: Clean and Update Cache
```bash
sudo yum clean all
sudo yum makecache
```

### Step 5: Verify It Works
```bash
yum repolist
```

## Automatic Setup
```bash
./check_mirrors.sh --auto-apply
```

## Rollback
```bash
sudo rm /etc/yum.repos.d/mirrors.repo
sudo cp -r /etc/yum.repos.d.backup/* /etc/yum.repos.d/
sudo yum clean all
```
EOF

  log_success "Generated YUM configuration: $config_file"
}

#===============================================================================
# Generate pip Configuration
#===============================================================================

generate_pip_config() {
  if [[ ${#WORKING_PIP_MIRRORS[@]} -eq 0 ]]; then
    return
  fi
  
  local config_file="$RESULTS_DIR/configs/pip/pip.conf"
  local readme_file="$RESULTS_DIR/configs/pip/README.md"
  
  # Use fastest mirror
  local fastest_mirror="${WORKING_PIP_MIRRORS[0]}"
  local mirror_url="${fastest_mirror%%|*}"
  local mirror_name="${fastest_mirror##*|}"
  
  # Generate pip.conf
  cat > "$config_file" << EOF
# Mirror Finder pip Configuration
# Generated: $TIMESTAMP
# Primary Mirror: $mirror_name

[global]
index-url = $mirror_url/simple/
trusted-host = $(echo "$mirror_url" | sed 's|https\?://||' | cut -d'/' -f1)
timeout = 60

[install]
trusted-host = $(echo "$mirror_url" | sed 's|https\?://||' | cut -d'/' -f1)

# Alternative mirrors (uncomment to use):
EOF

  local rank=2
  for mirror_entry in "${WORKING_PIP_MIRRORS[@]:1}"; do
    local alt_url="${mirror_entry%%|*}"
    local alt_name="${mirror_entry##*|}"
    echo "# Mirror $rank: $alt_name" >> "$config_file"
    echo "# index-url = $alt_url/simple/" >> "$config_file"
    ((rank++))
  done

  # Generate README
  cat > "$readme_file" << 'EOF'
# pip Mirror Configuration

## What This Does
This `pip.conf` file configures Python's pip package manager to use a fast Iranian PyPI mirror.

## Manual Setup

### For Current User Only
```bash
mkdir -p ~/.config/pip
cp pip.conf ~/.config/pip/pip.conf
```

### For All Users (System-wide)
```bash
sudo mkdir -p /etc/pip
sudo cp pip.conf /etc/pip/pip.conf
```

### Verify Configuration
```bash
pip config list
pip install --dry-run requests
```

## Quick One-liner (Temporary)
```bash
pip install -i https://MIRROR_URL/simple/ package_name
```

## Environment Variable (Temporary)
```bash
export PIP_INDEX_URL=https://MIRROR_URL/simple/
pip install package_name
```

## Automatic Setup
```bash
./check_mirrors.sh --auto-apply
```

## Rollback
```bash
rm ~/.config/pip/pip.conf
# or for system-wide:
sudo rm /etc/pip/pip.conf
```

## Troubleshooting
- If SSL errors occur, ensure the mirror supports HTTPS
- Try adding `--trusted-host MIRROR_HOST` to pip commands
- Check if the mirror has the package: `curl MIRROR_URL/simple/PACKAGE_NAME/`
EOF

  log_success "Generated pip configuration: $config_file"
}

#===============================================================================
# Generate npm Configuration
#===============================================================================

generate_npm_config() {
  if [[ ${#WORKING_NPM_MIRRORS[@]} -eq 0 ]]; then
    return
  fi
  
  local config_file="$RESULTS_DIR/configs/npm/.npmrc"
  local readme_file="$RESULTS_DIR/configs/npm/README.md"
  
  # Use fastest mirror
  local fastest_mirror="${WORKING_NPM_MIRRORS[0]}"
  local mirror_url="${fastest_mirror%%|*}"
  local mirror_name="${fastest_mirror##*|}"
  
  # Generate .npmrc
  cat > "$config_file" << EOF
# Mirror Finder npm Configuration
# Generated: $TIMESTAMP
# Mirror: $mirror_name

registry=$mirror_url/
strict-ssl=true
fetch-retries=3
fetch-retry-mintimeout=10000
fetch-retry-maxtimeout=60000
EOF

  # Generate README
  cat > "$readme_file" << 'EOF'
# npm Mirror Configuration

## What This Does
This `.npmrc` file configures npm to use a fast Iranian registry mirror.

## Manual Setup

### For Current User
```bash
cp .npmrc ~/.npmrc
```

### For a Specific Project
```bash
cp .npmrc /path/to/project/.npmrc
```

### Verify Configuration
```bash
npm config list
npm config get registry
```

## Quick One-liner (Temporary)
```bash
npm install --registry=https://MIRROR_URL/ package_name
```

## Using npm config command
```bash
npm config set registry https://MIRROR_URL/
```

## Automatic Setup
```bash
./check_mirrors.sh --auto-apply
```

## Rollback
```bash
npm config delete registry
# or
rm ~/.npmrc
```

## For Yarn Users
```bash
yarn config set registry https://MIRROR_URL/
```
EOF

  log_success "Generated npm configuration: $config_file"
}

#===============================================================================
# Generate Docker Configuration
#===============================================================================

generate_docker_config() {
  if [[ ${#WORKING_DOCKER_MIRRORS[@]} -eq 0 ]]; then
    return
  fi
  
  local config_file="$RESULTS_DIR/configs/docker/daemon.json"
  local readme_file="$RESULTS_DIR/configs/docker/README.md"
  
  # Build mirror list for daemon.json
  local mirrors_json="["
  local first=true
  for mirror_entry in "${WORKING_DOCKER_MIRRORS[@]}"; do
    local mirror_url="${mirror_entry%%|*}"
    if [[ "$first" == true ]]; then
      mirrors_json+="\"$mirror_url\""
      first=false
    else
      mirrors_json+=",\"$mirror_url\""
    fi
  done
  mirrors_json+="]"
  
  # Generate daemon.json
  cat > "$config_file" << EOF
{
  "registry-mirrors": $mirrors_json,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

  # Generate README
  cat > "$readme_file" << 'EOF'
# Docker Registry Mirror Configuration

## What This Does
This `daemon.json` configures Docker to use Iranian registry mirrors for pulling images.

## Manual Setup

### Step 1: Backup Existing Configuration
```bash
sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.backup 2>/dev/null || true
```

### Step 2: Copy New Configuration
```bash
sudo mkdir -p /etc/docker
sudo cp daemon.json /etc/docker/daemon.json
```

### Step 3: Restart Docker
```bash
sudo systemctl restart docker
```

### Step 4: Verify Configuration
```bash
docker info | grep -A 5 "Registry Mirrors"
```

### Step 5: Test Pull
```bash
docker pull hello-world
```

## Automatic Setup
```bash
./check_mirrors.sh --auto-apply
```

## Rollback
```bash
sudo cp /etc/docker/daemon.json.backup /etc/docker/daemon.json
sudo systemctl restart docker
```

## Alternative: Per-pull Mirror
```bash
docker pull MIRROR_URL/library/nginx:latest
```

## Troubleshooting
- Ensure Docker daemon is running: `sudo systemctl status docker`
- Check daemon.json syntax: `cat /etc/docker/daemon.json | python3 -m json.tool`
- View Docker logs: `sudo journalctl -u docker -f`
EOF

  log_success "Generated Docker configuration: $config_file"
}

#===============================================================================
# Generate Composer Configuration
#===============================================================================

generate_composer_config() {
  if [[ ${#WORKING_COMPOSER_MIRRORS[@]} -eq 0 ]]; then
    return
  fi
  
  local config_file="$RESULTS_DIR/configs/composer/config.json"
  local readme_file="$RESULTS_DIR/configs/composer/README.md"
  
  # Use fastest mirror
  local fastest_mirror="${WORKING_COMPOSER_MIRRORS[0]}"
  local mirror_url="${fastest_mirror%%|*}"
  local mirror_name="${fastest_mirror##*|}"
  
  # Generate composer config
  cat > "$config_file" << EOF
{
    "repositories": [
        {
            "type": "composer",
            "url": "$mirror_url",
            "canonical": true
        },
        {
            "packagist.org": false
        }
    ],
    "config": {
        "secure-http": true,
        "preferred-install": "dist"
    }
}
EOF

  # Generate README
  cat > "$readme_file" << 'EOF'
# Composer Mirror Configuration

## What This Does
This configuration makes Composer use a fast Iranian Packagist mirror.

## Manual Setup

### Global Configuration
```bash
mkdir -p ~/.config/composer
cp config.json ~/.config/composer/config.json
```

### Or Use Composer Command
```bash
composer config -g repos.packagist composer https://MIRROR_URL
```

### Per-Project Configuration
Add to your project's `composer.json`:
```json
{
    "repositories": [
        {
            "type": "composer",
            "url": "https://MIRROR_URL"
        },
        {
            "packagist.org": false
        }
    ]
}
```

### Verify Configuration
```bash
composer config -g --list | grep repositories
```

## Automatic Setup
```bash
./check_mirrors.sh --auto-apply
```

## Rollback
```bash
composer config -g --unset repos.packagist
rm ~/.config/composer/config.json
```
EOF

  log_success "Generated Composer configuration: $config_file"
}

#===============================================================================
# Generate Go Proxy Configuration
#===============================================================================

generate_go_config() {
  if [[ ${#WORKING_GO_MIRRORS[@]} -eq 0 ]]; then
    return
  fi
  
  local config_file="$RESULTS_DIR/configs/go/go_proxy.sh"
  local readme_file="$RESULTS_DIR/configs/go/README.md"
  
  # Use fastest mirror
  local fastest_mirror="${WORKING_GO_MIRRORS[0]}"
  local mirror_url="${fastest_mirror%%|*}"
  local mirror_name="${fastest_mirror##*|}"
  
  # Generate shell script
  cat > "$config_file" << EOF
#!/usr/bin/env bash
# Mirror Finder Go Proxy Configuration
# Generated: $TIMESTAMP
# Mirror: $mirror_name

# Set Go proxy environment variables
export GOPROXY="$mirror_url,https://proxy.golang.org,direct"
export GOSUMDB="sum.golang.org"
export GOPRIVATE=""

echo "Go proxy configured to use: $mirror_url"
echo "Run 'go env' to verify settings"
EOF

  chmod +x "$config_file"

  # Generate README
  cat > "$readme_file" << 'EOF'
# Go Proxy Configuration

## What This Does
This configures Go modules to use a fast Iranian proxy mirror.

## Manual Setup

### Temporary (Current Session)
```bash
source go_proxy.sh
```

### Permanent (Add to Shell Profile)
Add these lines to `~/.bashrc` or `~/.zshrc`:
```bash
export GOPROXY="https://MIRROR_URL,https://proxy.golang.org,direct"
export GOSUMDB="sum.golang.org"
```

Then reload:
```bash
source ~/.bashrc
```

### Using go env Command
```bash
go env -w GOPROXY="https://MIRROR_URL,https://proxy.golang.org,direct"
```

### Verify Configuration
```bash
go env | grep PROXY
```

## Automatic Setup
```bash
./check_mirrors.sh --auto-apply
```

## Rollback
```bash
go env -w GOPROXY="https://proxy.golang.org,direct"
# or
unset GOPROXY
```

## Test
```bash
go get -v golang.org/x/tools/gopls@latest
```
EOF

  log_success "Generated Go configuration: $config_file"
}

#===============================================================================
# Generate Summary Report
#===============================================================================

generate_report() {
  local report_file="$RESULTS_DIR/report.txt"
  local json_file="$RESULTS_DIR/report.json"
  local working_file="$RESULTS_DIR/working_mirrors.txt"
  
  # Generate text report
  cat > "$report_file" << EOF
================================================================================
                        MIRROR FINDER CHECK REPORT
================================================================================
Generated: $TIMESTAMP
Distribution: $DISTRO $DISTRO_VERSION ($CODENAME)
================================================================================

SUMMARY
-------
APT Mirrors (Debian/Ubuntu):  ${#WORKING_APT_MIRRORS[@]} working
YUM Mirrors (CentOS/Rocky):   ${#WORKING_YUM_MIRRORS[@]} working
PyPI Mirrors:                 ${#WORKING_PIP_MIRRORS[@]} working
npm Mirrors:                  ${#WORKING_NPM_MIRRORS[@]} working
Docker Registries:            ${#WORKING_DOCKER_MIRRORS[@]} working
Composer Mirrors:             ${#WORKING_COMPOSER_MIRRORS[@]} working
Go Proxy Mirrors:             ${#WORKING_GO_MIRRORS[@]} working

================================================================================
DETAILED RESULTS (Sorted by Latency)
================================================================================

EOF

  # Add detailed results for each category
  if [[ ${#WORKING_APT_MIRRORS[@]} -gt 0 ]]; then
    echo "APT MIRRORS:" >> "$report_file"
    echo "------------" >> "$report_file"
    local rank=1
    for mirror_entry in "${WORKING_APT_MIRRORS[@]}"; do
      local url="${mirror_entry%%|*}"
      local name="${mirror_entry##*|}"
      local latency="${MIRROR_LATENCIES[$url]:-N/A}"
      printf "  %d. %-40s %s (%sms)\n" "$rank" "$name" "$url" "$latency" >> "$report_file"
      ((rank++))
    done
    echo "" >> "$report_file"
  fi

  if [[ ${#WORKING_PIP_MIRRORS[@]} -gt 0 ]]; then
    echo "PYPI MIRRORS:" >> "$report_file"
    echo "-------------" >> "$report_file"
    local rank=1
    for mirror_entry in "${WORKING_PIP_MIRRORS[@]}"; do
      local url="${mirror_entry%%|*}"
      local name="${mirror_entry##*|}"
      local latency="${MIRROR_LATENCIES[$url]:-N/A}"
      printf "  %d. %-40s %s (%sms)\n" "$rank" "$name" "$url" "$latency" >> "$report_file"
      ((rank++))
    done
    echo "" >> "$report_file"
  fi

  if [[ ${#WORKING_DOCKER_MIRRORS[@]} -gt 0 ]]; then
    echo "DOCKER REGISTRIES:" >> "$report_file"
    echo "------------------" >> "$report_file"
    local rank=1
    for mirror_entry in "${WORKING_DOCKER_MIRRORS[@]}"; do
      local url="${mirror_entry%%|*}"
      local name="${mirror_entry##*|}"
      local latency="${MIRROR_LATENCIES[$url]:-N/A}"
      printf "  %d. %-40s %s (%sms)\n" "$rank" "$name" "$url" "$latency" >> "$report_file"
      ((rank++))
    done
    echo "" >> "$report_file"
  fi

  echo "================================================================================" >> "$report_file"
  echo "Configuration files generated in: $RESULTS_DIR/configs/" >> "$report_file"
  echo "================================================================================" >> "$report_file"

  # Generate working mirrors list
  {
    echo "# Working Mirrors - $TIMESTAMP"
    echo "# Format: TYPE|URL|NAME|LATENCY_MS"
    for mirror_entry in "${WORKING_APT_MIRRORS[@]}"; do
      local url="${mirror_entry%%|*}"
      local name="${mirror_entry##*|}"
      echo "APT|$url|$name|${MIRROR_LATENCIES[$url]:-0}"
    done
    for mirror_entry in "${WORKING_PIP_MIRRORS[@]}"; do
      local url="${mirror_entry%%|*}"
      local name="${mirror_entry##*|}"
      echo "PIP|$url|$name|${MIRROR_LATENCIES[$url]:-0}"
    done
    for mirror_entry in "${WORKING_NPM_MIRRORS[@]}"; do
      local url="${mirror_entry%%|*}"
      local name="${mirror_entry##*|}"
      echo "NPM|$url|$name|${MIRROR_LATENCIES[$url]:-0}"
    done
    for mirror_entry in "${WORKING_DOCKER_MIRRORS[@]}"; do
      local url="${mirror_entry%%|*}"
      local name="${mirror_entry##*|}"
      echo "DOCKER|$url|$name|${MIRROR_LATENCIES[$url]:-0}"
    done
  } > "$working_file"

  # Generate JSON report
  cat > "$json_file" << EOF
{
  "timestamp": "$TIMESTAMP",
  "distro": "$DISTRO",
  "version": "$DISTRO_VERSION",
  "codename": "$CODENAME",
  "results": {
    "apt": [
EOF

  local first=true
  for mirror_entry in "${WORKING_APT_MIRRORS[@]}"; do
    local url="${mirror_entry%%|*}"
    local name="${mirror_entry##*|}"
    local latency="${MIRROR_LATENCIES[$url]:-0}"
    if [[ "$first" == true ]]; then
      first=false
    else
      echo "," >> "$json_file"
    fi
    printf '      {"name": "%s", "url": "%s", "latency_ms": %s}' "$name" "$url" "$latency" >> "$json_file"
  done

  cat >> "$json_file" << EOF

    ],
    "pip": [
EOF

  first=true
  for mirror_entry in "${WORKING_PIP_MIRRORS[@]}"; do
    local url="${mirror_entry%%|*}"
    local name="${mirror_entry##*|}"
    local latency="${MIRROR_LATENCIES[$url]:-0}"
    if [[ "$first" == true ]]; then
      first=false
    else
      echo "," >> "$json_file"
    fi
    printf '      {"name": "%s", "url": "%s", "latency_ms": %s}' "$name" "$url" "$latency" >> "$json_file"
  done

  cat >> "$json_file" << EOF

    ],
    "docker": [
EOF

  first=true
  for mirror_entry in "${WORKING_DOCKER_MIRRORS[@]}"; do
    local url="${mirror_entry%%|*}"
    local name="${mirror_entry##*|}"
    local latency="${MIRROR_LATENCIES[$url]:-0}"
    if [[ "$first" == true ]]; then
      first=false
    else
      echo "," >> "$json_file"
    fi
    printf '      {"name": "%s", "url": "%s", "latency_ms": %s}' "$name" "$url" "$latency" >> "$json_file"
  done

  cat >> "$json_file" << EOF

    ]
  }
}
EOF

  log_success "Generated report: $report_file"
  log_success "Generated JSON: $json_file"
}

#===============================================================================
# Apply Configuration Functions
#===============================================================================

backup_config() {
  local config_path=$1
  local backup_name=$2
  
  mkdir -p "$BACKUP_DIR/$TIMESTAMP"
  
  if [[ -f "$config_path" ]]; then
    cp "$config_path" "$BACKUP_DIR/$TIMESTAMP/$backup_name"
    log_info "Backed up $config_path to $BACKUP_DIR/$TIMESTAMP/$backup_name"
  fi
}

apply_apt_config() {
  if [[ ${#WORKING_APT_MIRRORS[@]} -eq 0 ]]; then
    log_warning "No working APT mirrors found"
    return 1
  fi
  
  backup_config "/etc/apt/sources.list" "sources.list"
  
  if sudo cp "$RESULTS_DIR/configs/apt/sources.list" /etc/apt/sources.list; then
    log_success "Applied APT configuration"
    log_info "Running apt update..."
    if sudo apt update; then
      log_success "APT update successful"
    else
      log_error "APT update failed - you may want to rollback"
    fi
  else
    log_error "Failed to apply APT configuration"
    return 1
  fi
}

apply_pip_config() {
  if [[ ${#WORKING_PIP_MIRRORS[@]} -eq 0 ]]; then
    log_warning "No working pip mirrors found"
    return 1
  fi
  
  local pip_dir="$HOME/.config/pip"
  mkdir -p "$pip_dir"
  
  backup_config "$pip_dir/pip.conf" "pip.conf"
  
  if cp "$RESULTS_DIR/configs/pip/pip.conf" "$pip_dir/pip.conf"; then
    log_success "Applied pip configuration"
  else
    log_error "Failed to apply pip configuration"
    return 1
  fi
}

apply_npm_config() {
  if [[ ${#WORKING_NPM_MIRRORS[@]} -eq 0 ]]; then
    log_warning "No working npm mirrors found"
    return 1
  fi
  
  backup_config "$HOME/.npmrc" ".npmrc"
  
  if cp "$RESULTS_DIR/configs/npm/.npmrc" "$HOME/.npmrc"; then
    log_success "Applied npm configuration"
  else
    log_error "Failed to apply npm configuration"
    return 1
  fi
}

apply_docker_config() {
  if [[ ${#WORKING_DOCKER_MIRRORS[@]} -eq 0 ]]; then
    log_warning "No working Docker mirrors found"
    return 1
  fi
  
  backup_config "/etc/docker/daemon.json" "daemon.json"
  
  sudo mkdir -p /etc/docker
  if sudo cp "$RESULTS_DIR/configs/docker/daemon.json" /etc/docker/daemon.json; then
    log_success "Applied Docker configuration"
    log_info "Restarting Docker daemon..."
    if sudo systemctl restart docker 2>/dev/null; then
      log_success "Docker daemon restarted"
    else
      log_warning "Could not restart Docker - please restart manually"
    fi
  else
    log_error "Failed to apply Docker configuration"
    return 1
  fi
}

apply_composer_config() {
  if [[ ${#WORKING_COMPOSER_MIRRORS[@]} -eq 0 ]]; then
    log_warning "No working Composer mirrors found"
    return 1
  fi
  
  local composer_dir="$HOME/.config/composer"
  mkdir -p "$composer_dir"
  
  backup_config "$composer_dir/config.json" "composer_config.json"
  
  if cp "$RESULTS_DIR/configs/composer/config.json" "$composer_dir/config.json"; then
    log_success "Applied Composer configuration"
  else
    log_error "Failed to apply Composer configuration"
    return 1
  fi
}

apply_go_config() {
  if [[ ${#WORKING_GO_MIRRORS[@]} -eq 0 ]]; then
    log_warning "No working Go mirrors found"
    return 1
  fi
  
  # Apply using go env if available
  if command -v go &> /dev/null; then
    local fastest_mirror="${WORKING_GO_MIRRORS[0]}"
    local mirror_url="${fastest_mirror%%|*}"
    
    if go env -w GOPROXY="$mirror_url,https://proxy.golang.org,direct"; then
      log_success "Applied Go proxy configuration"
    else
      log_error "Failed to apply Go configuration"
      return 1
    fi
  else
    log_warning "Go is not installed - configuration saved but not applied"
    log_info "Source the script manually: source $RESULTS_DIR/configs/go/go_proxy.sh"
  fi
}

#===============================================================================
# Interactive Menu
#===============================================================================

show_apply_menu() {
  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}                    📦 Configuration Options                        ${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo ""
  
  local options=()
  local option_num=1
  
  if [[ ${#WORKING_APT_MIRRORS[@]} -gt 0 ]]; then
    echo -e "  ${GREEN}[$option_num]${NC} APT (Debian/Ubuntu) - ${#WORKING_APT_MIRRORS[@]} mirrors found"
    options+=("apt")
    ((option_num++))
  fi
  
  if [[ ${#WORKING_YUM_MIRRORS[@]} -gt 0 ]]; then
    echo -e "  ${GREEN}[$option_num]${NC} YUM/DNF (CentOS/Rocky) - ${#WORKING_YUM_MIRRORS[@]} mirrors found"
    options+=("yum")
    ((option_num++))
  fi
  
  if [[ ${#WORKING_PIP_MIRRORS[@]} -gt 0 ]]; then
    echo -e "  ${GREEN}[$option_num]${NC} pip (Python) - ${#WORKING_PIP_MIRRORS[@]} mirrors found"
    options+=("pip")
    ((option_num++))
  fi
  
  if [[ ${#WORKING_NPM_MIRRORS[@]} -gt 0 ]]; then
    echo -e "  ${GREEN}[$option_num]${NC} npm (Node.js) - ${#WORKING_NPM_MIRRORS[@]} mirrors found"
    options+=("npm")
    ((option_num++))
  fi
  
  if [[ ${#WORKING_DOCKER_MIRRORS[@]} -gt 0 ]]; then
    echo -e "  ${GREEN}[$option_num]${NC} Docker Registry - ${#WORKING_DOCKER_MIRRORS[@]} mirrors found"
    options+=("docker")
    ((option_num++))
  fi
  
  if [[ ${#WORKING_COMPOSER_MIRRORS[@]} -gt 0 ]]; then
    echo -e "  ${GREEN}[$option_num]${NC} Composer (PHP) - ${#WORKING_COMPOSER_MIRRORS[@]} mirrors found"
    options+=("composer")
    ((option_num++))
  fi
  
  if [[ ${#WORKING_GO_MIRRORS[@]} -gt 0 ]]; then
    echo -e "  ${GREEN}[$option_num]${NC} Go Proxy - ${#WORKING_GO_MIRRORS[@]} mirrors found"
    options+=("go")
    ((option_num++))
  fi
  
  echo ""
  echo -e "  ${YELLOW}[A]${NC} Apply ALL configurations"
  echo -e "  ${BLUE}[S]${NC} Skip (just save configs to results folder)"
  echo -e "  ${RED}[Q]${NC} Quit"
  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo ""
  
  while true; do
    read -rp "Enter your choice: " choice
    
    case "${choice,,}" in
      a|all)
        echo ""
        log_info "Applying all configurations..."
        [[ ${#WORKING_APT_MIRRORS[@]} -gt 0 ]] && apply_apt_config
        [[ ${#WORKING_PIP_MIRRORS[@]} -gt 0 ]] && apply_pip_config
        [[ ${#WORKING_NPM_MIRRORS[@]} -gt 0 ]] && apply_npm_config
        [[ ${#WORKING_DOCKER_MIRRORS[@]} -gt 0 ]] && apply_docker_config
        [[ ${#WORKING_COMPOSER_MIRRORS[@]} -gt 0 ]] && apply_composer_config
        [[ ${#WORKING_GO_MIRRORS[@]} -gt 0 ]] && apply_go_config
        break
        ;;
      s|skip)
        log_info "Configurations saved to: $RESULTS_DIR/configs/"
        log_info "Read the README.md files in each folder for manual setup instructions."
        break
        ;;
      q|quit)
        log_info "Exiting..."
        exit 0
        ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#options[@]} ]]; then
          local selected="${options[$((choice-1))]}"
          case "$selected" in
            apt) apply_apt_config ;;
            yum) apply_yum_config ;;
            pip) apply_pip_config ;;
            npm) apply_npm_config ;;
            docker) apply_docker_config ;;
            composer) apply_composer_config ;;
            go) apply_go_config ;;
          esac
        else
          log_warning "Invalid choice. Please try again."
        fi
        ;;
    esac
  done
}

#===============================================================================
# Rollback Function
#===============================================================================

do_rollback() {
  echo -e "${CYAN}Available backups:${NC}"
  echo ""
  
  if [[ ! -d "$BACKUP_DIR" ]]; then
    log_error "No backups found in $BACKUP_DIR"
    exit 1
  fi
  
  local backups=($(ls -1 "$BACKUP_DIR" 2>/dev/null | sort -r))
  
  if [[ ${#backups[@]} -eq 0 ]]; then
    log_error "No backups found"
    exit 1
  fi
  
  local idx=1
  for backup in "${backups[@]}"; do
    echo "  [$idx] $backup"
    ((idx++))
  done
  
  echo ""
  read -rp "Select backup to restore (1-${#backups[@]}): " choice
  
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#backups[@]} ]]; then
    log_error "Invalid selection"
    exit 1
  fi
  
  local selected_backup="${backups[$((choice-1))]}"
  local backup_path="$BACKUP_DIR/$selected_backup"
  
  log_info "Restoring from $backup_path..."
  
  [[ -f "$backup_path/sources.list" ]] && sudo cp "$backup_path/sources.list" /etc/apt/sources.list && log_success "Restored sources.list"
  [[ -f "$backup_path/pip.conf" ]] && cp "$backup_path/pip.conf" "$HOME/.config/pip/pip.conf" && log_success "Restored pip.conf"
  [[ -f "$backup_path/.npmrc" ]] && cp "$backup_path/.npmrc" "$HOME/.npmrc" && log_success "Restored .npmrc"
  [[ -f "$backup_path/daemon.json" ]] && sudo cp "$backup_path/daemon.json" /etc/docker/daemon.json && sudo systemctl restart docker && log_success "Restored daemon.json"
  
  log_success "Rollback complete"
}

#===============================================================================
# Main Mirror Check Logic
#===============================================================================

check_mirrors() {
  local mirror_count=$(yq e '.mirrors | length' "$MIRROR_FILE")
  
  echo ""
  log_info "Checking $mirror_count mirrors..."
  echo ""
  
  for idx in $(seq 0 $((mirror_count - 1))); do
    local name=$(yq e ".mirrors[$idx].name" "$MIRROR_FILE")
    local base_url=$(yq e ".mirrors[$idx].url" "$MIRROR_FILE")
    
    echo -e "${BLUE}🔍 Checking:${NC} $name"
    echo -e "   ${CYAN}URL:${NC} $base_url"
    
    local package_count=$(yq e ".mirrors[$idx].packages | length" "$MIRROR_FILE")
    
    for j in $(seq 0 $((package_count - 1))); do
      local package=$(yq e ".mirrors[$idx].packages[$j]" "$MIRROR_FILE")
      
      case "$package" in
        Ubuntu)
          if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "generic" ]]; then
            local test_path="ubuntu/dists/${CODENAME:-jammy}/Release"
            local result=$(check_url_with_latency "$base_url/$test_path")
            local status="${result%%|*}"
            local latency="${result##*|}"
            
            if [[ "$status" == "200" || "$status" == "301" || "$status" == "302" ]]; then
              echo -e "   ${GREEN}✅${NC} Ubuntu ($CODENAME) - ${latency}ms"
              WORKING_APT_MIRRORS+=("$base_url|$name")
              MIRROR_LATENCIES["$base_url"]="$latency"
            else
              echo -e "   ${RED}❌${NC} Ubuntu ($status)"
            fi
          fi
          ;;
        Debian)
          if [[ "$DISTRO" == "debian" || "$DISTRO" == "generic" ]]; then
            local test_path="debian/dists/${CODENAME:-bookworm}/Release"
            local result=$(check_url_with_latency "$base_url/$test_path")
            local status="${result%%|*}"
            local latency="${result##*|}"
            
            if [[ "$status" == "200" || "$status" == "301" || "$status" == "302" ]]; then
              echo -e "   ${GREEN}✅${NC} Debian ($CODENAME) - ${latency}ms"
              WORKING_APT_MIRRORS+=("$base_url|$name")
              MIRROR_LATENCIES["$base_url"]="$latency"
            else
              echo -e "   ${RED}❌${NC} Debian ($status)"
            fi
          fi
          ;;
        CentOS|Rocky|"YUM/DNF (CentOS, Fedora, Rocky)")
          if [[ "$DISTRO" == "centos" || "$DISTRO" == "rocky" || "$DISTRO" == "generic" ]]; then
            local ver="${CODENAME:-8}"
            local test_path="centos/$ver/os/x86_64/repodata/repomd.xml"
            local result=$(check_url_with_latency "$base_url/$test_path")
            local status="${result%%|*}"
            local latency="${result##*|}"
            
            if [[ "$status" == "200" || "$status" == "301" || "$status" == "302" ]]; then
              echo -e "   ${GREEN}✅${NC} CentOS/Rocky ($ver) - ${latency}ms"
              WORKING_YUM_MIRRORS+=("$base_url|$name")
              MIRROR_LATENCIES["$base_url"]="$latency"
            else
              echo -e "   ${RED}❌${NC} CentOS/Rocky ($status)"
            fi
          fi
          ;;
        PyPI|pip|Python)
          local test_path="simple/"
          local result=$(check_url_with_latency "$base_url/$test_path")
          local status="${result%%|*}"
          local latency="${result##*|}"
          
          if [[ "$status" == "200" || "$status" == "301" || "$status" == "302" ]]; then
            echo -e "   ${GREEN}✅${NC} PyPI - ${latency}ms"
            WORKING_PIP_MIRRORS+=("$base_url|$name")
            MIRROR_LATENCIES["$base_url"]="$latency"
          else
            echo -e "   ${RED}❌${NC} PyPI ($status)"
          fi
          ;;
        npm|"Node.js")
          local result=$(check_url_with_latency "$base_url/-/ping")
          local status="${result%%|*}"
          local latency="${result##*|}"
          
          if [[ "$status" == "200" || "$status" == "301" || "$status" == "302" ]]; then
            echo -e "   ${GREEN}✅${NC} npm - ${latency}ms"
            WORKING_NPM_MIRRORS+=("$base_url|$name")
            MIRROR_LATENCIES["$base_url"]="$latency"
          else
            echo -e "   ${RED}❌${NC} npm ($status)"
          fi
          ;;
        "Docker Registry"|Docker)
          local result=$(check_docker_registry "$base_url")
          local status="${result%%|*}"
          local latency="${result##*|}"
          
          if [[ "$status" == "OK" ]]; then
            echo -e "   ${GREEN}✅${NC} Docker Registry - ${latency}ms"
            WORKING_DOCKER_MIRRORS+=("$base_url|$name")
            MIRROR_LATENCIES["$base_url"]="$latency"
          else
            echo -e "   ${RED}❌${NC} Docker Registry"
          fi
          ;;
        Composer|"Composer/Packagist")
          local test_path="packages.json"
          local result=$(check_url_with_latency "$base_url/$test_path")
          local status="${result%%|*}"
          local latency="${result##*|}"
          
          if [[ "$status" == "200" || "$status" == "301" || "$status" == "302" ]]; then
            echo -e "   ${GREEN}✅${NC} Composer - ${latency}ms"
            WORKING_COMPOSER_MIRRORS+=("$base_url|$name")
            MIRROR_LATENCIES["$base_url"]="$latency"
          else
            echo -e "   ${RED}❌${NC} Composer ($status)"
          fi
          ;;
        Go)
          local test_path="sumdb/sum.golang.org/supported"
          local result=$(check_url_with_latency "$base_url/$test_path")
          local status="${result%%|*}"
          local latency="${result##*|}"
          
          if [[ "$status" == "200" || "$status" == "301" || "$status" == "302" || "$status" == "404" ]]; then
            # Some Go proxies return 404 for /supported but still work
            echo -e "   ${GREEN}✅${NC} Go Proxy - ${latency}ms"
            WORKING_GO_MIRRORS+=("$base_url|$name")
            MIRROR_LATENCIES["$base_url"]="$latency"
          else
            echo -e "   ${RED}❌${NC} Go Proxy ($status)"
          fi
          ;;
        *)
          echo -e "   ${YELLOW}⚠️${NC} Skipping: $package (not configured)"
          ;;
      esac
    done
    
    echo "   ────────────────────────────────"
  done
  
  # Sort mirrors by latency
  sort_mirrors_by_latency
}

sort_mirrors_by_latency() {
  # Sort APT mirrors
  if [[ ${#WORKING_APT_MIRRORS[@]} -gt 1 ]]; then
    IFS=$'\n' WORKING_APT_MIRRORS=($(for m in "${WORKING_APT_MIRRORS[@]}"; do
      url="${m%%|*}"
      echo "${MIRROR_LATENCIES[$url]:-99999}|$m"
    done | sort -t'|' -k1 -n | cut -d'|' -f2-))
    unset IFS
  fi
  
  # Sort pip mirrors
  if [[ ${#WORKING_PIP_MIRRORS[@]} -gt 1 ]]; then
    IFS=$'\n' WORKING_PIP_MIRRORS=($(for m in "${WORKING_PIP_MIRRORS[@]}"; do
      url="${m%%|*}"
      echo "${MIRROR_LATENCIES[$url]:-99999}|$m"
    done | sort -t'|' -k1 -n | cut -d'|' -f2-))
    unset IFS
  fi
  
  # Sort Docker mirrors
  if [[ ${#WORKING_DOCKER_MIRRORS[@]} -gt 1 ]]; then
    IFS=$'\n' WORKING_DOCKER_MIRRORS=($(for m in "${WORKING_DOCKER_MIRRORS[@]}"; do
      url="${m%%|*}"
      echo "${MIRROR_LATENCIES[$url]:-99999}|$m"
    done | sort -t'|' -k1 -n | cut -d'|' -f2-))
    unset IFS
  fi
}

#===============================================================================
# Parse Arguments
#===============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -d|--distro)
        DISTRO="${2,,}"
        shift 2
        ;;
      -v|--version)
        DISTRO_VERSION="$2"
        shift 2
        ;;
      -a|--auto-apply)
        AUTO_APPLY=true
        INTERACTIVE=false
        shift
        ;;
      -n|--non-interactive)
        INTERACTIVE=false
        shift
        ;;
      -r|--rollback)
        ROLLBACK=true
        shift
        ;;
      -h|--help)
        print_help
        exit 0
        ;;
      --list-versions)
        print_versions
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        print_help
        exit 1
        ;;
    esac
  done
  
  # Set codename based on distro and version
  if [[ -n "$DISTRO" && -n "$DISTRO_VERSION" ]]; then
    case "$DISTRO" in
      ubuntu)
        if [[ -v UBUNTU_VERSIONS["$DISTRO_VERSION"] ]]; then
          CODENAME="${UBUNTU_VERSIONS[$DISTRO_VERSION]}"
        else
          log_error "Unsupported Ubuntu version: $DISTRO_VERSION"
          log_info "Supported versions: ${!UBUNTU_VERSIONS[*]}"
          exit 1
        fi
        ;;
      debian)
        if [[ -v DEBIAN_VERSIONS["$DISTRO_VERSION"] ]]; then
          CODENAME="${DEBIAN_VERSIONS[$DISTRO_VERSION]}"
        else
          log_error "Unsupported Debian version: $DISTRO_VERSION"
          log_info "Supported versions: ${!DEBIAN_VERSIONS[*]}"
          exit 1
        fi
        ;;
      centos|rocky)
        if [[ -v CENTOS_VERSIONS["$DISTRO_VERSION"] ]]; then
          CODENAME="${CENTOS_VERSIONS[$DISTRO_VERSION]}"
        else
          log_error "Unsupported CentOS version: $DISTRO_VERSION"
          log_info "Supported versions: ${!CENTOS_VERSIONS[*]}"
          exit 1
        fi
        ;;
      alpine)
        if [[ -v ALPINE_VERSIONS["$DISTRO_VERSION"] ]]; then
          CODENAME="${ALPINE_VERSIONS[$DISTRO_VERSION]}"
        else
          log_error "Unsupported Alpine version: $DISTRO_VERSION"
          log_info "Supported versions: ${!ALPINE_VERSIONS[*]}"
          exit 1
        fi
        ;;
    esac
  fi
}

#===============================================================================
# Main
#===============================================================================

main() {
  parse_args "$@"
  
  print_banner
  
  # Handle rollback
  if [[ "$ROLLBACK" == true ]]; then
    do_rollback
    exit 0
  fi
  
  check_dependencies
  download_mirror_list
  
  # Detect OS if not specified
  if [[ -z "$DISTRO" ]]; then
    detect_os
  else
    log_info "Using specified distro: $DISTRO $DISTRO_VERSION ($CODENAME)"
  fi
  
  create_results_dir
  check_mirrors
  
  # Generate configurations
  echo ""
  log_info "Generating configuration files..."
  generate_apt_config
  generate_yum_config
  generate_pip_config
  generate_npm_config
  generate_docker_config
  generate_composer_config
  generate_go_config
  generate_report
  
  # Summary
  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}                         📊 Summary                                 ${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  APT mirrors:      ${GREEN}${#WORKING_APT_MIRRORS[@]}${NC} working"
  echo -e "  YUM mirrors:      ${GREEN}${#WORKING_YUM_MIRRORS[@]}${NC} working"
  echo -e "  PyPI mirrors:     ${GREEN}${#WORKING_PIP_MIRRORS[@]}${NC} working"
  echo -e "  npm mirrors:      ${GREEN}${#WORKING_NPM_MIRRORS[@]}${NC} working"
  echo -e "  Docker mirrors:   ${GREEN}${#WORKING_DOCKER_MIRRORS[@]}${NC} working"
  echo -e "  Composer mirrors: ${GREEN}${#WORKING_COMPOSER_MIRRORS[@]}${NC} working"
  echo -e "  Go mirrors:       ${GREEN}${#WORKING_GO_MIRRORS[@]}${NC} working"
  echo ""
  echo -e "  📁 Results saved to: ${BLUE}$RESULTS_DIR${NC}"
  echo ""
  
  # Apply configurations
  if [[ "$AUTO_APPLY" == true ]]; then
    log_info "Auto-applying all configurations..."
    [[ ${#WORKING_APT_MIRRORS[@]} -gt 0 ]] && apply_apt_config
    [[ ${#WORKING_PIP_MIRRORS[@]} -gt 0 ]] && apply_pip_config
    [[ ${#WORKING_NPM_MIRRORS[@]} -gt 0 ]] && apply_npm_config
    [[ ${#WORKING_DOCKER_MIRRORS[@]} -gt 0 ]] && apply_docker_config
    [[ ${#WORKING_COMPOSER_MIRRORS[@]} -gt 0 ]] && apply_composer_config
    [[ ${#WORKING_GO_MIRRORS[@]} -gt 0 ]] && apply_go_config
  elif [[ "$INTERACTIVE" == true ]]; then
    show_apply_menu
  else
    log_info "Configuration files saved. Check $RESULTS_DIR/configs/ for details."
    log_info "Each folder contains a README.md with setup instructions."
  fi
  
  echo ""
  log_success "Done! 🎉"
}

main "$@"
