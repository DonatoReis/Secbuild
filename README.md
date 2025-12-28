# SecBuild

<p align="center">
  <img src="https://i.ibb.co/RTQDVz15/upscalemedia-transformed.png" alt="SecBuild Logo" height="200">
  <br>
  <strong>Automated Security Tools Installer for Bug Bounty & Pentesting</strong>
  <br><br>
  <a href="https://discord.gg/Z2C2CyVZFU" target="_blank">
    <img src="https://img.shields.io/badge/-Discord-7289DA?style=for-the-badge&logo=discord&logoColor=white&color=black" alt="Discord">
  </a>
</p>

## 🎯 Overview

**SecBuild** is a robust, modular automation tool designed to install and manage 100+ popular security and pentesting tools on Linux systems. It saves you up to 90% of the time typically spent setting up your security testing environment by automatically handling dependencies, configurations, and installations.

### ✨ Key Features

- 🚀 **Automated Installation**: Installs 100+ security tools with a single command
- 📦 **Profile-Based Installation**: Install tools by category (recon, web, dns, etc.)
- ⚡ **Performance Optimized**: Smart caching and parallel installation support
- 🔒 **Security First**: Integrity verification, sandboxed post-install scripts
- 📊 **Progress Tracking**: Advanced progress bar with time estimates and speed
- 🔄 **Smart Retry**: Adaptive backoff retry for network operations
- ✅ **Health Checks**: Comprehensive verification of installed tools
- 📝 **Detailed Logging**: Complete audit trail of all operations
- 🎯 **English Interface**: Clean, professional English-only interface

## 🖥️ Supported Operating Systems

| OS | Supported | Easy Install | Tested |
|----|-----------|--------------|--------|
| **Kali Linux** | ✅ Yes | ✅ Yes | Kali 2024.1+ |
| **Ubuntu** | ✅ Yes | ✅ Yes | Ubuntu 20.04+ |
| **Debian** | ⚠️ Partial | ⚠️ Partial | Debian 10+ |
| **macOS** | ⚠️ Limited | ❌ No | List mode only |

## 📋 Requirements

- **Bash 4.0+** (for associative arrays)
- **Root privileges** (for installation, not required for listing)
- **Internet connection** (for downloading tools)
- **Basic system packages**: `curl`, `wget`, `git`

## 🚀 Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/DonatoReis/Secbuild.git
cd Secbuild

# Run the installer (interactive mode)
sudo ./secbuild.sh
```

### Basic Usage

```bash
# Interactive menu mode
sudo ./secbuild.sh

# Install a specific tool
sudo ./secbuild.sh -i nmap

# Install by profile (e.g., recon tools)
sudo ./secbuild.sh --profile recon

# List all available tools
./secbuild.sh -l

# List available profiles
./secbuild.sh --list-profiles

# Parallel installation (faster)
sudo ./secbuild.sh -p 8

# Dry-run mode (simulation, no changes)
sudo ./secbuild.sh --dry-run
```

## 📖 Detailed Usage

### Command-Line Options

```
Usage: sudo ./secbuild.sh [OPTIONS]

Options:
  -h, --help              Show this help message
  -v, --verbose           Enable verbose mode (debug output)
  -f, --force             Force update of dependencies
  -s, --silent            Silent mode (non-interactive)
  -l, --list              List all available tools
  -i, --install TOOL      Install a specific tool
  -u, --update            Update all installed tools
  --dry-run               Simulation mode (no actual changes)
  -p, --parallel [N]      Parallel installation (N = number of jobs, default: 4)
  --profile NAME          Install tools from a specific profile
  --list-profiles         List all available profiles
  --no-latest-release     Disable latest release installation (use default branch)
```

### Examples

```bash
# Install all tools
sudo ./secbuild.sh

# Install specific tool
sudo ./secbuild.sh -i subfinder

# Install web security tools profile
sudo ./secbuild.sh --profile web

# Install with 8 parallel jobs
sudo ./secbuild.sh -p 8 --profile bugbounty

# List tools and check what's installed
./secbuild.sh -l

# Simulate installation (see what would happen)
sudo ./secbuild.sh --dry-run --profile recon
```

## 🎨 Available Profiles

SecBuild organizes tools into **17 predefined profiles** for easy installation:

| Profile | Description | Tools Count |
|---------|-------------|-------------|
| **recon** | Reconnaissance and information gathering | 20+ |
| **dns** | DNS analysis and enumeration | 10+ |
| **subdomains** | Subdomain discovery tools | 15+ |
| **web** | Web application security testing | 25+ |
| **fuzzing** | Fuzzing and brute force tools | 10+ |
| **ssl** | SSL/TLS certificate analysis | 5+ |
| **network** | Network scanning and analysis | 10+ |
| **osint** | Open Source Intelligence tools | 15+ |
| **wifi** | WiFi security testing | 5+ |
| **automation** | Test automation and orchestration | 8+ |
| **parameters** | Parameter discovery and analysis | 10+ |
| **takeover** | Subdomain takeover detection | 5+ |
| **cloud** | Cloud security tools | 5+ |
| **social** | Social engineering tools | 5+ |
| **utilities** | Utility and helper tools | 20+ |
| **pentest** | Complete pentesting toolkit | 30+ |
| **bugbounty** | Essential bug bounty tools | 25+ |

### Installing a Profile

```bash
# Install all web security tools
sudo ./secbuild.sh --profile web

# Install bug bounty essentials
sudo ./secbuild.sh --profile bugbounty

# Install complete pentesting toolkit
sudo ./secbuild.sh --profile pentest
```

## 🛠️ Available Tools

SecBuild supports **100+ security tools**, including:

### Reconnaissance & OSINT
- `subfinder`, `findomain`, `assetfinder`, `sublist3r`
- `theHarvester`, `infoga`, `sherlock`, `ghunt`
- `waybackurls`, `gau`, `gauplus`, `haktrails`

### Web Security
- `nuclei`, `sqlmap`, `dalfox`, `xssstrike`
- `paramspider`, `arjun`, `gxss`, `kxss`
- `dirsearch`, `gobuster`, `feroxbuster`, `ffuf`

### DNS Tools
- `dnsx`, `massdns`, `shuffledns`, `puredns`
- `dnsrecon`, `dnsvalidator`, `dnsgen`

### Network Scanning
- `naabu`, `rustscan`, `masscan`, `unimap`
- `httpx`, `httprobe`, `tlsx`

### And many more...

See the complete list with:
```bash
./secbuild.sh -l
```

## 🏗️ Architecture

SecBuild follows a **modular architecture** for maintainability and extensibility:

```
Secbuild/
├── secbuild.sh              # Main orchestrator script
├── package-dist.ini         # Tools configuration (INI format)
├── tools_config.yaml        # System packages and profiles
├── lib/                     # Modular library
│   ├── system.sh            # System detection & setup
│   ├── logging.sh           # Logging system
│   ├── cache.sh             # Caching system
│   ├── validation.sh       # Validation & security
│   ├── config.sh            # Configuration management
│   ├── install.sh           # Installation logic
│   └── ui.sh                # User interface
```

## 🔧 Advanced Features

### Performance Optimizations

- **Installation Cache**: Caches tool verification results (50-70% faster)
- **Parallel Installation**: Install multiple tools simultaneously (up to 8 jobs)
- **Smart Retry**: Adaptive backoff retry for network operations
- **Shallow Git Clones**: Faster repository cloning

### Security Features

- **Integrity Verification**: Validates Git repository integrity
- **Hash Verification**: Optional hash verification for downloads
- **Post-Install Validation**: Validates post-install scripts for security
- **Sandbox Support**: Isolated execution of post-install commands (when available)

### Health Checks

Comprehensive health checks verify:
- ✅ Command exists in PATH
- ✅ Execution permissions
- ✅ File integrity (not empty, not corrupted)
- ✅ Symbolic link validity
- ✅ Runtime execution (timeout test)
- ✅ Dynamic dependencies (for ELF binaries)

## 📊 Progress Tracking

The improved progress bar shows:
- **Percentage**: Visual progress (0-100%)
- **Progress Bar**: Color-coded visual indicator
- **Current/Total**: Items processed
- **Tool Name**: Currently processing
- **Elapsed Time**: Time since start (formatted as hh:mm:ss or mm:ss)
- **Estimated Remaining**: Based on average speed
- **Speed**: Items per minute

Example output:
```
[ 80%] [████████████████░░░░] (80/100) nmap [2m30s / 3m10s] [32/min]
```

**Note**: Verbose mode (`-v` or `--verbose`) shows additional initialization messages for better debugging.

## 📝 Logging

SecBuild maintains detailed logs:

- **Main Log**: `~/.secbuild/logs/secbuild_YYYYMMDD_HHMMSS.log`
- **Error Log**: `~/.secbuild/logs/secbuild_errors_YYYYMMDD_HHMMSS.log`
- **Audit Trail**: Complete record of all operations

View logs:
```bash
# From interactive menu
sudo ./secbuild.sh
# Select option 8: View logs

# Or directly
less ~/.secbuild/logs/secbuild_*.log
```

## 🔄 Updating Tools

Update installed tools to their latest versions:

```bash
# Update all installed tools
sudo ./secbuild.sh -u

# Update specific tool (future feature)
sudo ./secbuild.sh --update nmap
```

## 🗑️ Uninstalling Tools

Remove installed tools:

```bash
# Uninstall specific tool (future feature)
sudo ./secbuild.sh --uninstall nmap
```

## ⚙️ Configuration

Configuration is stored in `~/.secbuild/config/secbuild.conf`:

```bash
# View current configuration
cat ~/.secbuild/config/secbuild.conf

# Edit configuration (manual)
nano ~/.secbuild/config/secbuild.conf
```

### Environment Variables

```bash
# Set work directory
export WORK_DIR=/custom/path

# Disable latest release installation
export USE_LATEST_RELEASE=0

# Enable verbose mode
export VERBOSE_MODE=1
```

## 🐛 Troubleshooting

### Common Issues

**Problem**: "Bash version too old"
```bash
# Solution: Install newer Bash
# On macOS:
brew install bash
/usr/local/bin/bash ./secbuild.sh

# On Linux:
sudo apt-get install bash
```

**Problem**: "Permission denied"
```bash
# Solution: Run with sudo
sudo ./secbuild.sh
```

**Problem**: "Tool installation fails"
```bash
# Check logs
less ~/.secbuild/logs/secbuild_errors_*.log

# Enable verbose mode
sudo ./secbuild.sh -v -i toolname
```

**Problem**: "Network timeout"
```bash
# SecBuild automatically retries with adaptive backoff
# If persistent, check your internet connection
```

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Adding a New Tool

1. Edit `package-dist.ini`:
```ini
[NewTool]
url=https://github.com/user/repo
script=tool.py
profile=web,recon
post_install='go install github.com/user/repo@latest'
```

2. Test installation:
```bash
sudo ./secbuild.sh -i newtool
```

3. Submit a Pull Request

## 📄 License

This project is licensed under the terms specified in the LICENSE file.

## 🙏 Acknowledgments

- All the amazing tool developers who create and maintain these security tools
- The security community for feedback and contributions
- Contributors who help improve SecBuild

## ⚠️ Disclaimer

**This tool is for authorized security testing only. Unauthorized access to computer systems is illegal. The authors and contributors are not responsible for any misuse of this tool.**

## 📞 Support

- **Discord**: [Join our Discord server](https://discord.gg/Z2C2CyVZFU)
- **Issues**: [GitHub Issues](https://github.com/DonatoReis/Secbuild/issues)
- **Documentation**: See the codebase for detailed technical documentation

## 🗺️ Roadmap

- [ ] Tool update functionality
- [ ] Tool uninstallation
- [ ] Support for multiple package managers (yum, pacman, etc.)
- [ ] Plugin system for extensibility
- [ ] Web UI (optional)
- [ ] Docker container support
- [ ] CI/CD integration

## 📈 Statistics

- **Total Tools**: 100+
- **Profiles**: 17
- **Language**: English (100% English interface)
- **Installation Methods**: 4 (Git, Go, APT, Post-Install)
- **Lines of Code**: 5000+

---

<p align="center">
  <strong>Made with ❤️ for the security community</strong>
  <br>
  <em>Recode The Copyright Is Not Make You A Coder</em>
</p>
