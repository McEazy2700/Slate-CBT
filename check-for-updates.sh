#!/usr/bin/env bash

set -e

# --- Configuration ---
REPO_OWNER="McEazy2700"
REPO_NAME="Slate-CBT"
VERSION_FILE="VERSION.txt" # Path to your local version file
# GitHub API endpoint for the latest release
GITHUB_API_URL="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest"
DOWNLOAD_TARGET_FILENAME="latest.tar.gz" # Name to save the downloaded file as

# --- Functions for logging ---
log_info() {
  echo "ℹ️  $1"
}

log_success() {
  echo "✅ $1"
}

log_warning() {
  echo "⚠️  $1" >&2
}

log_error() {
  echo "❌ $1" >&2
  exit 1
}

# --- Main Script Logic ---

log_info "Starting version check and potential download for $REPO_OWNER/$REPO_NAME..."

# 1. Ensure jq is installed
if ! command -v jq &>/dev/null; then
  log_info "jq is not installed. Attempting to install it."
  if [ "$EUID" -ne 0 ]; then
    log_error "jq requires root privileges to install. Please run this script with sudo or install jq manually (e.g., 'sudo apt install jq')."
  fi
  sudo apt update -y || log_error "Failed to update apt package list before installing jq."
  sudo apt install -y jq || log_error "Failed to install jq. Please try installing it manually and re-run."
  log_success "jq installed successfully."
else
  log_info "jq is already installed."
fi

# 2. Get local version
if [ ! -f "$VERSION_FILE" ]; then
  log_error "Local version file '$VERSION_FILE' not found. Cannot determine current version."
fi

# Extract the Release tag using grep and awk
LOCAL_VERSION=$(grep "Release tag:" "$VERSION_FILE" | awk '{print $NF}' | tr -d '\n')

if [ -z "$LOCAL_VERSION" ]; then
  log_error "Could not extract Release tag from '$VERSION_FILE'. Ensure it has 'Release tag: X.Y.Z'."
fi

log_info "Current local version: $LOCAL_VERSION"

# 3. Get latest remote version and download URL from GitHub API
log_info "Fetching latest release details from GitHub API..."

# Fetch the latest release and extract tag_name and the .tar.gz download URL
API_RESPONSE=$(curl -sL "$GITHUB_API_URL")

LATEST_REMOTE_VERSION=$(echo "$API_RESPONSE" | jq -r '.tag_name')

if [ -z "$LATEST_REMOTE_VERSION" ] || [ "$LATEST_REMOTE_VERSION" == "null" ]; then
  log_error "Could not retrieve latest release tag from GitHub API. Check repository name/owner or API rate limits."
fi

# Extract the download URL for the .tar.gz asset
DOWNLOAD_URL=$(echo "$API_RESPONSE" | jq -r ".assets[] | select(.name | endswith(\".tar.gz\")) | .browser_download_url")

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
  log_error "Could not find a .tar.gz asset in the latest release. Is the release structured as expected?"
fi


log_info "Latest remote version: $LATEST_REMOTE_VERSION"
log_info "Download URL found: $DOWNLOAD_URL"

# 4. Compare versions and perform download if needed
# Use 'sort -V' for robust semantic version comparison.
if [ "$LOCAL_VERSION" = "$LATEST_REMOTE_VERSION" ]; then
  log_success "You are running the latest version ($LOCAL_VERSION). No download needed."
elif printf '%s\n' "$LOCAL_VERSION" "$LATEST_REMOTE_VERSION" | sort -V | head -n 1 | grep -q "$LATEST_REMOTE_VERSION"; then
  log_warning "You are running a newer version ($LOCAL_VERSION) than the latest release ($LATEST_REMOTE_VERSION)!"
  log_info "This can happen if you're on a pre-release or development build. No download needed."
else
  log_warning "A new version is available! (Local: $LOCAL_VERSION, Latest: $LATEST_REMOTE_VERSION)"
  log_info "Downloading the latest version ($LATEST_REMOTE_VERSION) to '$DOWNLOAD_TARGET_FILENAME'..."

  # Use curl with -L (follow redirects) and -o (output to specified filename)
  curl -Lfo "$DOWNLOAD_TARGET_FILENAME" "$DOWNLOAD_URL" || log_error "Failed to download the new version."

  if [ -f "$DOWNLOAD_TARGET_FILENAME" ]; then
    log_success "New version downloaded successfully to '$DOWNLOAD_TARGET_FILENAME'."
    log_info "You can now process '$DOWNLOAD_TARGET_FILENAME' (e.g., extract and deploy)."
  else
    log_error "Download completed but '$DOWNLOAD_TARGET_FILENAME' not found. Check curl output above."
  fi
fi

log_success "Version check and download process complete."
