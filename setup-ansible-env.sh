#!/bin/bash
set -e

VENV_DIR="$HOME/.venvs/talos-deploy"

echo "Creating Python virtual environment at $VENV_DIR..."
mkdir -p "$HOME/.venvs"
python3 -m venv "$VENV_DIR"

echo "Activating virtual environment..."
source "$VENV_DIR/bin/activate"

echo "Upgrading pip..."
pip install --upgrade pip

echo "Installing Ansible and required Python packages..."
pip install ansible netaddr

echo "Installing Ansible collections..."
ansible-galaxy collection install ansible.utils
ansible-galaxy collection install ansible.posix
ansible-galaxy collection install community.general

echo ""
echo "========================================="
echo "Setup complete!"
echo "========================================="
echo ""
echo "To activate the environment in your current shell, run:"
echo "  source $VENV_DIR/bin/activate"
echo ""
echo "Or add this to your shell profile to activate automatically:"
echo "  export VIRTUAL_ENV=$VENV_DIR"
echo "  export PATH=\"\$VIRTUAL_ENV/bin:\$PATH\""
echo ""
