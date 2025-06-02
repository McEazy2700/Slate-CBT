#!/usr/bin/env bash

set -e

# --- Configuration ---
DOWNLOADED_TAR_FILE="latest.tar.gz" # Name of the downloaded tarball from the previous script
TEMP_EXTRACT_DIR="./temp_update_bundle" # Temporary directory to extract the new version

# Base directories to search for 'migrations' folders.
# This should be your project root.
SEARCH_BASE_DIR="."

# Additional directories to EXCLUDE from being replaced, besides 'migrations'.
# Use relative paths from the project root.
# Examples:
# - "./media" # For user-uploaded media files
# - "./static_collected" # If you collect static files locally and serve them
# - "./.env" # If .env is not managed by your setup script but manually edited
# - "./local_settings.py" # If you have local override settings
ADDITIONAL_EXCLUDE_DIRS=(
    # Add any other specific paths you want to exclude here, e.g.:
    # "./config/.env"
    # "./settings/local_settings.py"
)

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

log_info "Starting deployment of new version from '$DOWNLOADED_TAR_FILE'..."

# 1. Check if the downloaded tar file exists
if [ ! -f "$DOWNLOADED_TAR_FILE" ]; then
  log_error "Downloaded tar file '$DOWNLOADED_TAR_FILE' not found. Please run the update check script first."
fi

# 2. Dynamically find all 'migrations' directories
log_info "Detecting 'migrations' directories to preserve..."
# Use find to locate all directories named 'migrations'
# -type d: only directories
# -name "migrations": directories named 'migrations'
# -wholename "./temp_update_bundle/*": exclude the temp directory
# -print0: null-terminate output for robust handling of spaces/special characters
# xargs -0: read null-terminated input
# sed 's/^\.\///': remove leading "./" for cleaner paths
mapfile -t MIGRATIONS_DIRS < <(find "$SEARCH_BASE_DIR" -type d -name "migrations" ! -wholename "$TEMP_EXTRACT_DIR/*" -print0 | xargs -0 -n1 realpath --relative-to="$SEARCH_BASE_DIR" | sed 's/^\.\///')

# Combine automatically found migrations dirs with explicitly defined ones
declare -a EXCLUDE_DIRS=("${MIGRATIONS_DIRS[@]}" "${ADDITIONAL_EXCLUDE_DIRS[@]}")

if [ ${#EXCLUDE_DIRS[@]} -eq 0 ]; then
    log_warning "No 'migrations' directories found to preserve. If you have migrations, this might be an issue."
else
    log_info "Found and will preserve the following directories:"
    for dir in "${EXCLUDE_DIRS[@]}"; do
        log_info "  - $dir"
    done
fi

# 3. Create a temporary directory for extraction
log_info "Creating temporary extraction directory: $TEMP_EXTRACT_DIR"
mkdir -p "$TEMP_EXTRACT_DIR" || log_error "Failed to create temporary directory."

# 4. Extract the tar file into the temporary directory
log_info "Extracting '$DOWNLOADED_TAR_FILE' to '$TEMP_EXTRACT_DIR'..."
# Determine the top-level directory inside the tarball.
# Tarballs from GitHub releases usually have a single top-level directory like "repo-name-version".
# We need to extract its *contents* directly into TEMP_EXTRACT_DIR.
# First, list contents to find the top-level folder name.
TAR_TOP_LEVEL_DIR=$(tar -tzf "$DOWNLOADED_TAR_FILE" | head -1 | cut -f1 -d'/' | tr -d '\n')

if [ -z "$TAR_TOP_LEVEL_DIR" ]; then
    log_error "Could not determine top-level directory in the tarball. Tarball might be malformed."
fi

log_info "Tarball's top-level directory: '$TAR_TOP_LEVEL_DIR'"

tar -xzf "$DOWNLOADED_TAR_FILE" -C "$TEMP_EXTRACT_DIR" || log_error "Failed to extract tar file."

# Move contents of the top-level directory directly into TEMP_EXTRACT_DIR
log_info "Moving extracted contents to root of temporary directory..."
# Use shopt -s dotglob to include dotfiles (like .github) during the move
shopt -s dotglob
mv "$TEMP_EXTRACT_DIR/$TAR_TOP_LEVEL_DIR"/* "$TEMP_EXTRACT_DIR"/ || log_error "Failed to move extracted contents."
shopt -u dotglob # Disable dotglob after use

rmdir "$TEMP_EXTRACT_DIR/$TAR_TOP_LEVEL_DIR" || log_warning "Could not remove empty top-level directory '$TEMP_EXTRACT_DIR/$TAR_TOP_LEVEL_DIR'."

log_success "Tarball extracted successfully."

# 5. Preserve specified directories (like migrations)
log_info "Preserving specified directories before update..."
declare -A PRESERVED_DIRS_TEMP # Associative array to store paths of preserved dirs

for dir in "${EXCLUDE_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        # Create a temporary name to move it
        # Ensure path is unique if multiple 'migrations' exist at same depth
        TEMP_PRESERVE_PATH="$TEMP_EXTRACT_DIR/PRESERVED_$(echo "$dir" | tr '/' '_')_$(date +%s%N)"
        log_info "Moving '$dir' to '$TEMP_PRESERVE_PATH' for preservation..."
        mv "$dir" "$TEMP_PRESERVE_PATH" || log_error "Failed to move '$dir' for preservation."
        PRESERVED_DIRS_TEMP["$dir"]="$TEMP_PRESERVE_PATH"
    else
        log_warning "Directory to exclude '$dir' not found. Skipping preservation."
    fi
done
log_success "Directories marked for preservation."

# 6. Delete old files and directories (except preserved ones)
# This is a critical step. Ensure you are in the correct directory.
log_info "Deleting old project files and directories (excluding preserved ones)..."
# Use find to delete files and directories excluding the temp_update_bundle itself
# This `find` command will target items in the current directory, but ignore the
# temporary directory we created and any preserved directories (which are now
# temporarily moved out of the way inside the temp_extract_dir).
# We exclude the dot-directories and the script itself too for safety.
find . -maxdepth 1 -mindepth 1 \
    ! -name "$(basename "$TEMP_EXTRACT_DIR")" \
    ! -name "$(basename "$DOWNLOADED_TAR_FILE")" \
    ! -name "$(basename "$0")" \
    ! -name ".*" \
    -exec rm -rf {} + || log_error "Failed to delete old files."
log_success "Old files and directories removed."

# 7. Copy new files from temporary directory
log_info "Copying new files from '$TEMP_EXTRACT_DIR' to current directory..."
# Use shopt -s dotglob again to ensure dotfiles are copied
shopt -s dotglob
cp -r "$TEMP_EXTRACT_DIR"/* . || log_error "Failed to copy new files."
shopt -u dotglob # Disable dotglob after use
log_success "New files copied."

# 8. Restore preserved directories
log_info "Restoring preserved directories..."
for dir in "${!PRESERVED_DIRS_TEMP[@]}"; do
    TEMP_PATH="${PRESERVED_DIRS_TEMP[$dir]}"
    if [ -d "$TEMP_PATH" ]; then
        log_info "Restoring '$TEMP_PATH' to '$dir'..."
        mv "$TEMP_PATH" "$dir" || log_error "Failed to restore '$dir'."
    fi
done
log_success "Preserved directories restored."

# 9. Clean up temporary directory and downloaded tar
log_info "Cleaning up temporary extraction directory and downloaded tar..."
rm -rf "$TEMP_EXTRACT_DIR" || log_warning "Failed to remove temporary directory '$TEMP_EXTRACT_DIR'."
rm -f "$DOWNLOADED_TAR_FILE" || log_warning "Failed to remove downloaded tar file '$DOWNLOADED_TAR_FILE'."
log_success "Clean up complete."

log_success "Deployment of new version completed successfully!"
log_info "Remember to run 'python manage.py migrate' and restart your services."
