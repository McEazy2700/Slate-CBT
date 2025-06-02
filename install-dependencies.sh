#!/usr/bin/env bash

set -e

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

log_info "Starting Docker and Docker Compose plugin installation/update for Ubuntu..."

# 1. Require root privileges
if [ "$EUID" -ne 0 ]; then
  log_error "Please run this script with sudo or as root."
fi

# 2. Update and Upgrade System
log_info "Updating and upgrading system packages..."
sudo apt-get update -y || log_error "Failed to update apt packages."
sudo apt-get upgrade -y || log_error "Failed to upgrade apt packages."
sudo apt-get dist-upgrade -y || log_error "Failed to dist-upgrade apt packages."
sudo apt-get autoremove -y || log_warning "Failed to autoremove old packages, continuing..."
sudo apt-get clean || log_warning "Failed to clean apt cache, continuing..."
log_success "System packages updated and upgraded."

# 3. Setup Docker apt repository
log_info "Setting up Docker APT repository."

# Install prerequisites
apt_prereqs=(
  "ca-certificates"
  "curl"
  "gnupg"
  "lsb-release"
)
log_info "Installing apt prerequisites: ${apt_prereqs[*]}..."
sudo apt-get install -y "${apt_prereqs[@]}" || log_error "Failed to install apt prerequisites."

# Add Docker GPG key
sudo install -m 0755 -d /etc/apt/keyrings || log_error "Failed to create /etc/apt/keyrings directory."
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  log_info "Adding Docker GPG key..."
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg || log_error "Failed to add Docker GPG key."
  sudo chmod a+r /etc/apt/keyrings/docker.gpg || log_error "Failed to set permissions on GPG key."
else
  log_info "Docker GPG key already exists."
fi

# Add Docker repository to Apt sources
if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
  log_info "Adding Docker repository to APT sources..."
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null || log_error "Failed to add Docker repository."
else
  log_info "Docker repository already configured."
fi

# Update apt index again after adding the new repository
log_info "Updating apt package index with new Docker repository..."
sudo apt-get update -y || log_error "Failed to update apt package index after adding Docker repository."

# 4. Install Docker Engine and Docker Compose plugin
log_info "Installing/updating Docker Engine, CLI, containerd, and Docker Compose plugin..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || log_error "Failed to install Docker components."
log_success "Docker Engine and Docker Compose plugin installed/updated."

# 5. Start and enable Docker service
log_info "Ensuring Docker service is running and enabled..."
sudo systemctl start docker || log_error "Failed to start Docker service."
sudo systemctl enable docker || log_error "Failed to enable Docker service to start on boot."
log_success "Docker service is active and enabled."

# 6. Add current user to 'docker' group
CURRENT_USER=$(whoami)
if ! getent group docker | grep -q "\b$CURRENT_USER\b"; then
  log_info "Adding current user ($CURRENT_USER) to the 'docker' group..."
  sudo usermod -aG docker "$CURRENT_USER" || log_error "Failed to add user to 'docker' group."
  log_warning "You need to log out and log back in (or reboot) for the group changes to take effect."
  log_warning "After logging back in, you should be able to run 'docker' commands without 'sudo'."
else
  log_info "Current user ($CURRENT_USER) is already in the 'docker' group."
fi

# 7. Verify installation
log_info "Verifying Docker and Docker Compose installation..."
docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "not installed")
docker_compose_version=$(docker compose version --short 2>/dev/null || echo "not installed")

if [[ "$docker_version" == "not installed" || "$docker_compose_version" == "not installed" ]]; then
  log_error "Docker Engine or Docker Compose plugin installation verification failed."
else
  log_success "Docker Engine (v$docker_version) and Docker Compose plugin (v$docker_compose_version) are installed and running."
  log_info "You can test Docker by running: docker run hello-world"
fi

log_success "Docker installation/update process complete for Ubuntu."
