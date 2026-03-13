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
      wget -q "https://releases.hashicorp.com/terraform/${tf_version}/terraform_${tf_version}_linux_amd64.zip" -O /tmp/terraform.zip
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

install_aws_cli
install_session_manager_plugin
install_terraform
install_gh_cli

echo ""
echo "=== Verify ==="
echo "AWS CLI:     $(aws --version 2>&1 | head -1)"
echo "SSM Plugin:  $(session-manager-plugin --version 2>/dev/null || echo 'not found')"
echo "Terraform:   $(terraform --version 2>/dev/null | head -1)"
echo "GitHub CLI:  $(gh --version 2>/dev/null | head -1)"

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
