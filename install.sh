#!/bin/bash
# install.sh
# Installs all prerequisites for the SNI spoof tunnel.
# Works on macOS and Linux (Ubuntu/Debian/Fedora).
#
# Usage:
#   curl -sSL <raw-url>/install.sh | bash
#   # or
#   ./install.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[*]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }

OS="$(uname -s)"

echo ""
echo "=================================="
echo "  SNI Spoof Tunnel - Installer"
echo "  OS: $OS"
echo "=================================="
echo ""

# ---------- Python ----------
if command -v python3 &>/dev/null; then
    PY_VERSION=$(python3 --version 2>&1 | awk '{print $2}')
    log "Python $PY_VERSION is already installed"
else
    log "Installing Python..."
    if [ "$OS" = "Darwin" ]; then
        if command -v brew &>/dev/null; then
            brew install python@3.13
        else
            err "Homebrew is not installed. Install it first:"
            echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
            echo "  Then run this script again."
            exit 1
        fi
    elif [ -f /etc/debian_version ]; then
        sudo apt update
        sudo apt install -y python3 python3-pip python3-venv
    elif [ -f /etc/fedora-release ]; then
        sudo dnf install -y python3 python3-pip
    else
        err "Could not detect your Linux distribution."
        echo "  Install Python 3.12+ manually and run this script again."
        exit 1
    fi
    log "Python installed: $(python3 --version)"
fi

# ---------- Azure CLI ----------
if command -v az &>/dev/null; then
    AZ_VERSION=$(az version --query '"azure-cli"' -o tsv 2>/dev/null)
    log "Azure CLI $AZ_VERSION is already installed"
else
    log "Installing Azure CLI..."
    if [ "$OS" = "Darwin" ]; then
        brew install azure-cli
    elif [ -f /etc/debian_version ]; then
        curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    elif [ -f /etc/fedora-release ]; then
        sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
        sudo dnf install -y azure-cli
    fi
    log "Azure CLI installed: $(az version --query '"azure-cli"' -o tsv 2>/dev/null)"
fi

# ---------- uv (Python package manager) ----------
if command -v uv &>/dev/null; then
    log "uv is already installed: $(uv --version)"
else
    log "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    log "uv installed: $(uv --version)"
fi

# ---------- Project dependencies ----------
if [ -f "pyproject.toml" ]; then
    log "Installing project dependencies..."
    uv sync 2>&1 | tail -1
    log "Dependencies installed"
else
    warn "pyproject.toml not found. Run this script from the project directory."
fi

# ---------- Azure login check ----------
echo ""
if az account show &>/dev/null; then
    ACCOUNT=$(az account show --query name -o tsv)
    log "Already logged in to Azure: $ACCOUNT"
else
    warn "Not logged in to Azure."
    echo "  Run 'az login' to authenticate before using start.sh"
fi

echo ""
log "All prerequisites are installed."
log "Next steps:"
echo "  1. Run 'az login' if you have not already"
echo "  2. Run './start.sh' to start the tunnel"
echo ""
