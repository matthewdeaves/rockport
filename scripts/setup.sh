#!/bin/bash
set -euo pipefail

# Setup script for Rockport development — works on Ubuntu/Debian and macOS (Homebrew)

echo "=== Rockport Setup ==="

OS="$(uname -s)"

install_brew() {
  if ! command -v brew &>/dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
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
      brew install awscli
      ;;
    Linux)
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
      unzip -qo /tmp/awscliv2.zip -d /tmp/aws-install
      sudo /tmp/aws-install/aws/install --update
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
      brew install --cask session-manager-plugin
      ;;
    Linux)
      curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/session-manager-plugin.deb
      sudo dpkg -i /tmp/session-manager-plugin.deb
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
      brew tap hashicorp/tap
      brew install hashicorp/tap/terraform
      ;;
    Linux)
      local tf_version="1.14.7"
      curl -fsSL "https://releases.hashicorp.com/terraform/${tf_version}/terraform_${tf_version}_linux_amd64.zip" -o /tmp/terraform.zip
      unzip -qo /tmp/terraform.zip -d /tmp
      sudo mv /tmp/terraform /usr/local/bin/
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
      brew install gh
      ;;
    Linux)
      sudo mkdir -p -m 755 /etc/apt/keyrings
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
      sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
      sudo apt-get update && sudo apt-get install -y gh
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
      brew install trivy
      ;;
    Linux)
      curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin
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
      brew install checkov
      ;;
    Linux)
      if command -v pipx &>/dev/null; then
        pipx install checkov
      else
        echo "Installing pipx first..."
        sudo apt-get update && sudo apt-get install -y pipx
        pipx ensurepath
        pipx install checkov
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
      brew install shellcheck
      ;;
    Linux)
      sudo apt-get update && sudo apt-get install -y shellcheck
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
      brew install gitleaks
      ;;
    Linux)
      local gl_version
      gl_version=$(curl -sL https://api.github.com/repos/gitleaks/gitleaks/releases/latest | grep -oP '"tag_name":\s*"v\K[^"]+')
      curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${gl_version}/gitleaks_${gl_version}_linux_x64.tar.gz" -o /tmp/gitleaks.tar.gz
      mkdir -p "$HOME/.local/bin"
      tar -xzf /tmp/gitleaks.tar.gz -C "$HOME/.local/bin" gitleaks
      rm /tmp/gitleaks.tar.gz
      ;;
  esac
}

setup_git_hooks() {
  local repo_root
  repo_root="$(cd "$(dirname "$0")/.." && pwd)"
  if [[ -d "$repo_root/.githooks" ]]; then
    git -C "$repo_root" config core.hooksPath .githooks
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
