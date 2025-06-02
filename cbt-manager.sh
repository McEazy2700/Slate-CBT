#!/usr/bin/env bash

# Centralized CBT Application Manager Script

set -e # Exit immediately if a command exits with a non-zero status

# --- Configuration ---
# Get the directory where this script resides (project root)
PROJECT_ROOT="$(dirname "$(realpath "$0")")"

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

# --- Core Logic Functions for Commands ---

# Helper to check for root
require_root() {
  if [ "$EUID" -ne 0 ]; then
    log_error "This command requires root privileges. Please run with sudo (e.g., 'sudo $0 $1')."
  fi
}

# Helper to get Docker Compose command
get_compose_cmd() {
  local compose_cmd=""
  if command -v docker-compose &>/dev/null; then
    compose_cmd="docker-compose"
  elif command -v podman-compose &>/dev/null; then
    compose_cmd="podman-compose"
  elif command -v docker &>/dev/null && docker compose version &>/dev/null; then
    compose_cmd="docker compose"
  fi
  echo "$compose_cmd" # Return the command
}

# Command: install-deps (Installs/updates Docker and system dependencies)
cmd_install_deps() {
  log_info "Running system update/upgrade and installing/updating Docker..."
  require_root "install-deps"
  
  # Execute the install-dependencies.sh script
  "$PROJECT_ROOT/install-dependencies.sh" || log_error "Dependency installation failed."
  log_success "Dependencies installed/updated."
}

# Command: setup (Initial setup, creates .env, superuser, SSL)
cmd_setup() {
  log_info "Running initial project setup..."
  require_root "setup"

  # Execute the prepare-env-and-deploy.sh script
  # We pass an argument to it to signal if it should start the server or not
  read -r -p "Do you want to start the server after setup? (y/N): " start_server
  if [[ "$start_server" == "y" || "$start_server" == "Y" ]]; then
    # Pass a flag to the setup script to indicate immediate start
    "$PROJECT_ROOT/prepare-env-and-deploy.sh" "start" || log_error "Initial setup failed."
  else
    "$PROJECT_ROOT/prepare-env-and-deploy.sh" "no-start" || log_error "Initial setup failed."
  fi
  
  log_success "Project setup complete."
}

# Command: update (Checks for new version, downloads, deploys, runs migrations, restarts)
cmd_update() {
  log_info "Initiating full application update process..."
  require_root "update" # Update process needs root for various steps

  log_info "Step 1/4: Checking for new releases and downloading if available..."
  # check-for-updates.sh will download latest.tar.gz if a new version is found
  "$PROJECT_ROOT/check-for-updates.sh" || log_error "Failed to check for updates or download new version."
  
  # Check if latest.tar.gz exists, which means a download occurred or it was left from a previous run
  if [ -f "$PROJECT_ROOT/latest.tar.gz" ]; then
    log_info "Step 2/4: Deploying new version and preserving migrations..."
    "$PROJECT_ROOT/save-updates.sh" || log_error "Deployment of new version failed."
    log_success "New version deployed."

    log_info "Step 3/4: Running database migrations and creating/updating superuser..."
    local COMPOSE_CMD=$(get_compose_cmd)
    if [ -z "$COMPOSE_CMD" ]; then
      log_error "Could not find docker compose command. Is Docker installed?"
    fi
    
    cd "$PROJECT_ROOT" # Ensure we are in the project root for compose commands
    
    # Run migrations
    $COMPOSE_CMD exec web python manage.py migrate --noinput || log_error "Database migrations failed."
    log_success "Database migrations applied."

    # Create/Update superuser using values from the config file (loaded by prepare-env-and-deploy.sh)
    # Ensure config is sourced if not already from prepare-env-and-deploy.sh
    if [ ! -f "/etc/slatemd/cbt.conf" ]; then
      log_error "Config file not found at /etc/slatemd/cbt.conf. Cannot update superuser."
    fi
    source "/etc/slatemd/cbt.conf" # Load config variables

    log_info "Creating/updating Django superuser..."
    $COMPOSE_CMD exec web python manage.py createsuperuser \
        --username="$DJANGO_SUPERUSER_USERNAME" \
        --email="$DJANGO_SUPERUSER_EMAIL" \
        --noinput || true # || true to prevent script from exiting if superuser already exists
    log_success "Django superuser checked/updated."

    log_info "Step 4/4: Rebuilding and restarting containers..."
    $COMPOSE_CMD up -d --build --force-recreate || log_error "Failed to rebuild and restart containers."
    log_success "Containers restarted successfully."

    log_success "Application update complete!"
    log_info "Access your application at the configured BASE_URL."

  else
    log_info "No new version detected or downloaded. No deployment performed."
  fi
}

# Command: start
cmd_start() {
  log_info "Starting CBT application containers..."
  require_root "start"

  local COMPOSE_CMD=$(get_compose_cmd)
  if [ -z "$COMPOSE_CMD" ]; then
    log_error "Could not find docker compose command. Is Docker installed?"
  fi
  
  cd "$PROJECT_ROOT" # Ensure we are in the project root for compose commands
  $COMPOSE_CMD up -d || log_error "Failed to start containers."
  log_success "CBT application started."
}

# Command: stop
cmd_stop() {
  log_info "Stopping CBT application containers..."
  require_root "stop"

  local COMPOSE_CMD=$(get_compose_cmd)
  if [ -z "$COMPOSE_CMD" ]; then
    log_error "Could not find docker compose command. Is Docker installed?"
  fi
  
  cd "$PROJECT_ROOT" # Ensure we are in the project root for compose commands
  $COMPOSE_CMD down || log_error "Failed to stop containers."
  log_success "CBT application stopped."
}

# Command: status (Check container status)
cmd_status() {
  log_info "Checking CBT application container status..."
  require_root "status"

  local COMPOSE_CMD=$(get_compose_cmd)
  if [ -z "$COMPOSE_CMD" ]; then
    log_error "Could not find docker compose command. Is Docker installed?"
  fi
  
  cd "$PROJECT_ROOT" # Ensure we are in the project root for compose commands
  $COMPOSE_CMD ps || log_error "Failed to get container status."
}

# Help message
show_help() {
  echo "Usage: $0 <command>"
  echo ""
  echo "Available commands:"
  echo "  install-deps  : Installs/updates system dependencies (Docker, jq, etc.). Requires sudo."
  echo "  setup         : Runs initial project setup (config, .env, superuser, SSL). Requires sudo."
  echo "  update        : Checks for new release, downloads, deploys, runs migrations, restarts services. Requires sudo."
  echo "  start         : Starts the CBT application containers. Requires sudo."
  echo "  stop          : Stops the CBT application containers. Requires sudo."
  echo "  status        : Shows the status of CBT application containers. Requires sudo."
  echo "  help          : Show this help message."
  echo ""
  echo "Example: sudo $0 update"
}

# --- Command Dispatcher ---

if [ "$#" -eq 0 ]; then
  show_help
  exit 1
fi

COMMAND="$1"
shift # Remove the command from the arguments list

case "$COMMAND" in
  install-deps)
    cmd_install_deps "$@"
    ;;
  setup)
    cmd_setup "$@"
    ;;
  update)
    cmd_update "$@"
    ;;
  start)
    cmd_start "$@"
    ;;
  stop)
    cmd_stop "$@"
    ;;
  status)
    cmd_status "$@"
    ;;
  help)
    show_help
    ;;
  *)
    log_error "Unknown command: '$COMMAND'. Use '$0 help' for usage."
    ;;
esac

exit 0
