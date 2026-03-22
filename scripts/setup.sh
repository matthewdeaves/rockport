#!/bin/bash

die() { echo "ERROR: $*" >&2; exit 1; }

# Setup script for Rockport development — works on Ubuntu/Debian and macOS (Homebrew)

echo "=== Rockport Setup ==="

OS="$(uname -s)"

install_brew() {
  if ! command -v brew &>/dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      || die "Failed to install Homebrew"
  fi
}

install_aws_cli() {
  if command -v aws &>/dev/null; then
    echo "✓ AWS CLI already installed ($(aws --version 2>&1 | head -1))"
    return
  fi
  echo "Installing AWS CLI..."
  case "$OS" in
    Darwin)
      install_brew
      brew install awscli || die "Failed to install AWS CLI via Homebrew"
      ;;
    Linux)
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
        || die "Failed to download AWS CLI"
      unzip -qo /tmp/awscliv2.zip -d /tmp/aws-install || die "Failed to unzip AWS CLI"
      sudo /tmp/aws-install/aws/install --update || die "Failed to install AWS CLI"
      rm -rf /tmp/awscliv2.zip /tmp/aws-install
      ;;
  esac
}

install_session_manager_plugin() {
  if command -v session-manager-plugin &>/dev/null; then
    echo "✓ Session Manager plugin already installed"
    return
  fi
  echo "Installing Session Manager plugin..."
  case "$OS" in
    Darwin)
      install_brew
      brew install --cask session-manager-plugin || die "Failed to install Session Manager plugin via Homebrew"
      ;;
    Linux)
      curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/session-manager-plugin.deb \
        || die "Failed to download Session Manager plugin"
      sudo dpkg -i /tmp/session-manager-plugin.deb || die "Failed to install Session Manager plugin"
      rm /tmp/session-manager-plugin.deb
      ;;
  esac
}

install_terraform() {
  if command -v terraform &>/dev/null; then
    echo "✓ Terraform already installed ($(terraform version -json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || terraform --version | head -1))"
    return
  fi
  echo "Installing Terraform..."
  case "$OS" in
    Darwin)
      install_brew
      brew tap hashicorp/tap || die "Failed to tap hashicorp/tap"
      brew install hashicorp/tap/terraform || die "Failed to install Terraform via Homebrew"
      ;;
    Linux)
      local tf_version="1.14.7"
      curl -fsSL "https://releases.hashicorp.com/terraform/${tf_version}/terraform_${tf_version}_linux_amd64.zip" -o /tmp/terraform.zip \
        || die "Failed to download Terraform"
      unzip -qo /tmp/terraform.zip -d /tmp || die "Failed to unzip Terraform"
      sudo mv /tmp/terraform /usr/local/bin/ || die "Failed to install Terraform"
      rm /tmp/terraform.zip
      ;;
  esac
}

install_gh_cli() {
  if command -v gh &>/dev/null; then
    echo "✓ GitHub CLI already installed ($(gh --version | head -1))"
    return
  fi
  echo "Installing GitHub CLI..."
  case "$OS" in
    Darwin)
      install_brew
      brew install gh || die "Failed to install GitHub CLI via Homebrew"
      ;;
    Linux)
      sudo mkdir -p -m 755 /etc/apt/keyrings || die "Failed to create keyrings directory"
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /tmp/githubcli-archive-keyring.gpg \
        || die "Failed to download GitHub CLI keyring"
      sudo mv /tmp/githubcli-archive-keyring.gpg /etc/apt/keyrings/githubcli-archive-keyring.gpg \
        || die "Failed to install GitHub CLI keyring"
      sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg || die "Failed to chmod keyring"
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
        || die "Failed to add GitHub CLI apt source"
      sudo apt-get update || die "Failed to update apt"
      sudo apt-get install -y gh || die "Failed to install GitHub CLI"
      ;;
  esac
}

install_trivy() {
  if command -v trivy &>/dev/null; then
    echo "✓ Trivy already installed ($(trivy --version 2>&1 | head -1))"
    return
  fi
  echo "Installing Trivy..."
  case "$OS" in
    Darwin)
      install_brew
      brew install trivy || die "Failed to install Trivy via Homebrew"
      ;;
    Linux)
      local trivy_script
      trivy_script=$(mktemp) || die "Failed to create temp file for trivy installer"
      curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh -o "$trivy_script" \
        || { rm -f "$trivy_script"; die "Failed to download trivy install script"; }
      sudo sh "$trivy_script" -b /usr/local/bin || { rm -f "$trivy_script"; die "Failed to install trivy"; }
      rm -f "$trivy_script"
      ;;
  esac
}

install_checkov() {
  if command -v checkov &>/dev/null; then
    echo "✓ Checkov already installed ($(checkov --version 2>&1))"
    return
  fi
  echo "Installing Checkov..."
  case "$OS" in
    Darwin)
      install_brew
      brew install checkov || die "Failed to install Checkov via Homebrew"
      ;;
    Linux)
      if command -v pipx &>/dev/null; then
        pipx install checkov || die "Failed to install Checkov via pipx"
      else
        echo "Installing pipx first..."
        sudo apt-get update || die "Failed to update apt"
        sudo apt-get install -y pipx || die "Failed to install pipx"
        pipx ensurepath || die "Failed to configure pipx path"
        pipx install checkov || die "Failed to install Checkov via pipx"
      fi
      ;;
  esac
}

install_shellcheck() {
  if command -v shellcheck &>/dev/null; then
    echo "✓ ShellCheck already installed ($(shellcheck --version 2>&1 | grep '^version:'))"
    return
  fi
  echo "Installing ShellCheck..."
  case "$OS" in
    Darwin)
      install_brew
      brew install shellcheck || die "Failed to install ShellCheck via Homebrew"
      ;;
    Linux)
      sudo apt-get update || die "Failed to update apt"
      sudo apt-get install -y shellcheck || die "Failed to install ShellCheck"
      ;;
  esac
}

install_gitleaks() {
  if command -v gitleaks &>/dev/null; then
    echo "✓ Gitleaks already installed ($(gitleaks version 2>&1))"
    return
  fi
  echo "Installing Gitleaks..."
  case "$OS" in
    Darwin)
      install_brew
      brew install gitleaks || die "Failed to install Gitleaks via Homebrew"
      ;;
    Linux)
      local gl_json gl_version
      gl_json=$(curl -sL https://api.github.com/repos/gitleaks/gitleaks/releases/latest) \
        || die "Failed to fetch gitleaks release info"
      gl_version=$(echo "$gl_json" | grep -oP '"tag_name":\s*"v\K[^"]+') \
        || die "Failed to parse gitleaks version"
      curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${gl_version}/gitleaks_${gl_version}_linux_x64.tar.gz" -o /tmp/gitleaks.tar.gz \
        || die "Failed to download gitleaks"
      mkdir -p "$HOME/.local/bin" || die "Failed to create ~/.local/bin"
      tar -xzf /tmp/gitleaks.tar.gz -C "$HOME/.local/bin" gitleaks || die "Failed to extract gitleaks"
      rm /tmp/gitleaks.tar.gz
      ;;
  esac
}

setup_git_hooks() {
  local repo_root
  repo_root="$(cd "$(dirname "$0")/.." && pwd)"
  if [[ -d "$repo_root/.githooks" ]]; then
    git -C "$repo_root" config core.hooksPath .githooks || die "Failed to configure git hooks"
    echo "✓ Git hooks configured (.githooks/pre-commit)"
  fi
}

install_aws_cli
install_session_manager_plugin
install_terraform
install_gh_cli
install_trivy
install_checkov
install_shellcheck
install_gitleaks
setup_git_hooks

echo ""
echo "=== Verify ==="
echo "AWS CLI:     $(aws --version 2>&1 | head -1)"
echo "SSM Plugin:  $(session-manager-plugin --version 2>/dev/null || echo 'not found')"
echo "Terraform:   $(terraform --version 2>/dev/null | head -1)"
echo "GitHub CLI:  $(gh --version 2>/dev/null | head -1)"
echo "Trivy:       $(trivy --version 2>&1 | head -1)"
echo "Checkov:     $(checkov --version 2>/dev/null || echo 'not found')"
echo "ShellCheck:  $(shellcheck --version 2>&1 | grep '^version:' || echo 'not found')"
echo "Gitleaks:    $(gitleaks version 2>/dev/null || echo 'not found')"

echo ""
echo "=== Next steps ==="
if ! aws sts get-caller-identity &>/dev/null; then
  echo "1. Configure AWS credentials:  aws configure"
else
  echo "1. AWS credentials: ✓ configured ($(aws sts get-caller-identity --query Account --output text))"
fi
if ! gh auth status &>/dev/null 2>&1; then
  echo "2. Authenticate GitHub CLI:    gh auth login"
else
  echo "2. GitHub CLI: ✓ authenticated"
fi
echo "3. Deploy:  cd terraform && terraform init && terraform apply"
