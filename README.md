# Mirror Finder

A bash script to find, test, and automatically configure fast Iranian package mirrors for Linux distributions and development tools.

---

## What It Does

- **Finds working mirrors** - Tests Iranian mirrors and checks which ones are online
- **Measures speed** - Ranks mirrors by response time (fastest first)
- **Generates configs** - Creates ready-to-use configuration files for your package managers
- **Auto-applies settings** - Optionally configures your system automatically
- **Backs up everything** - Saves your old configs before making changes

---

## Supported Systems

**Linux Distributions:**

- Ubuntu 20.04, 22.04, 24.04
- Debian 10, 11, 12
- CentOS/Rocky/AlmaLinux 7, 8, 9
- Alpine 3.18, 3.19, 3.20
- Fedora (auto-detected)

**Package Managers:**

- APT (Debian/Ubuntu) → `sources.list`
- YUM/DNF (CentOS/Rocky) → `mirrors.repo`
- pip (Python) → `pip.conf`
- npm (Node.js) → `.npmrc`
- Docker → `daemon.json`
- Composer (PHP) → `config.json`
- Go Proxy → `go_proxy.sh`

---

## Installation

### Requirements

```bash
# Install curl
sudo apt install curl    # Debian/Ubuntu
sudo yum install curl    # CentOS/Rocky

# Install yq (YAML parser)
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
sudo chmod +x /usr/local/bin/yq
```

### Download & Run

```bash
git clone https://github.com/YOUR_USERNAME/mirror-finder.git
cd mirror-finder
chmod +x check_mirrors.sh
./check_mirrors.sh
```

---

## Usage

### Basic (auto-detect your OS)

```bash
./check_mirrors.sh
```

### Specific distribution

```bash
./check_mirrors.sh -d ubuntu -v 22.04
./check_mirrors.sh -d debian -v 12
./check_mirrors.sh -d centos -v 9
```

### Auto-apply all configs

```bash
./check_mirrors.sh --auto-apply
```

### Just generate configs (no prompts)

```bash
./check_mirrors.sh --non-interactive
```

### Rollback changes

```bash
./check_mirrors.sh --rollback
```

### See supported versions

```bash
./check_mirrors.sh --list-versions
```

---

## Options

| Flag | Short | What it does |
|------|-------|--------------|
| `--distro` | `-d` | Set distribution (ubuntu, debian, centos, alpine, rocky, fedora) |
| `--version` | `-v` | Set version (22.04, 12, 9, etc.) |
| `--auto-apply` | `-a` | Apply all configs automatically |
| `--non-interactive` | `-n` | Skip prompts, just save configs |
| `--rollback` | `-r` | Restore previous configuration |
| `--list-versions` | | Show supported versions |
| `--help` | `-h` | Show help |

---

## Output Structure

Results are saved in timestamped folders:

```
results/2026-04-20_14-30-00/
├── report.txt              # Summary
├── report.json             # Machine-readable
├── working_mirrors.txt     # List of working mirrors
└── configs/
    ├── apt/
    │   ├── sources.list
    │   └── README.md       # How to apply
    ├── yum/
    │   ├── mirrors.repo
    │   └── README.md
    ├── pip/
    │   ├── pip.conf
    │   └── README.md
    ├── npm/
    │   ├── .npmrc
    │   └── README.md
    ├── docker/
    │   ├── daemon.json
    │   └── README.md
    ├── composer/
    │   ├── config.json
    │   └── README.md
    └── go/
        ├── go_proxy.sh
        └── README.md
```

Each config folder has a `README.md` with step-by-step instructions.

---

## Quick Apply Commands

### APT (Ubuntu/Debian)

```bash
sudo cp results/*/configs/apt/sources.list /etc/apt/sources.list
sudo apt update
```

### pip

```bash
mkdir -p ~/.config/pip
cp results/*/configs/pip/pip.conf ~/.config/pip/
```

### npm

```bash
cp results/*/configs/npm/.npmrc ~/.npmrc
```

### Docker

```bash
sudo cp results/*/configs/docker/daemon.json /etc/docker/daemon.json
sudo systemctl restart docker
```

---

## Backup Location

When you apply configs, old files are backed up to:

```
~/.mirror-finder/backups/<timestamp>/
```

Use `--rollback` to restore them.

---

## Iranian Mirrors Tested

| Provider | What they mirror |
|----------|------------------|
| Shatel | Ubuntu, Debian |
| KubarCloud | Linux kernel, Debian, Ubuntu, Alpine, Arch |
| ITO | CentOS, Fedora, Rocky, Python, npm |
| ArvanCloud | Debian, Ubuntu, CentOS, Alpine, Docker |
| IranServer | Debian, Ubuntu, CentOS |
| Liara | Multiple distros, PyPI, npm, Docker |
| HamDocker | Docker Registry |
| Focker | Docker Registry |
| MobinHost | Multiple distros, Docker |
| Pardisco | Ubuntu, Debian, Alpine, PyPI, npm, Go |

Full list in [mirrors_list.yaml](mirrors_list.yaml).

---

## License

MIT
