#!/bin/bash

set -e

echo "Updating package index..."
sudo apt-get update -y

echo "Installing required packages..."
sudo apt-get install -y git curl unzip

echo "Verifying installations..."
git --version
curl --version
unzip -v | head -n 1

echo "Bootstrap completed successfully."
