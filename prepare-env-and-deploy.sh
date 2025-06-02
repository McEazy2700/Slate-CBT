#!/usr/bin/env bash

set -e

CONFIG_PATH="/etc/slatemd"
CONFIG_FILE="$CONFIG_PATH/cbt.conf"
NGINX_CERTS_PATH="./nginx/certs"

# 1. Require root privileges
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script with sudo or as root."
  exit 1
fi

# 2. Create config if it doesn't exist
if [ ! -f "$CONFIG_FILE" ]; then
    echo "⚙️  No config found at $CONFIG_FILE — starting setup..."
    mkdir -p "$CONFIG_PATH"

    read -r -p "Enter the school name (e.g TOSA): " school_name
    read -r -p "Enter the base URL (e.g. https://tosa.slate.ng): " base_url

    # Django superuser credentials with defaults
    read -r -p "Enter Django superuser username [admin]: " superuser_username
    superuser_username=${superuser_username:-admin}
    
    read -r -p "Enter Django superuser email [admin@example.com]: " superuser_email
    superuser_email=${superuser_email:-admin@example.com}
    
    while true; do
        read -r -s -p "Enter Django superuser password: " superuser_password
        echo
        read -r -s -p "Confirm Django superuser password: " superuser_password_confirm
        echo
        
        if [ "$superuser_password" = "$superuser_password_confirm" ]; then
            break
        else
            echo "❌ Passwords do not match. Please try again."
        fi
    done

    secret_key=$(openssl rand -base64 32)

    cat > "$CONFIG_FILE" <<EOF
SCHOOL_NAME="$school_name"
BASE_URL="$base_url"
SECRET_KEY="$secret_key"
DJANGO_SUPERUSER_USERNAME="$superuser_username"
DJANGO_SUPERUSER_EMAIL="$superuser_email"
DJANGO_SUPERUSER_PASSWORD="$superuser_password"
EOF

    echo "✅ Config saved to $CONFIG_FILE"
fi

# 3. Load config values
source "$CONFIG_FILE"

# 4. Always reset .env
if [ -f .env ]; then
    echo "🗑️  Removing old .env file..."
    rm .env
fi

echo "📁 Creating new .env file from .env.example..."
cp .env.example .env

# 5. Replace placeholders in the copied .env
sed -i "s|{SCHOOL_NAME}|$SCHOOL_NAME|g" .env
sed -i "s|{BASE_URL}|$BASE_URL|g" .env
sed -i "s|{SERVER_BASE_URL}|$BASE_URL|g" .env
sed -i "s|{SECRET_KEY}|$SECRET_KEY|g" .env
sed -i "s|export DJANGO_SUPERUSER_USERNAME=admin|export DJANGO_SUPERUSER_USERNAME=$DJANGO_SUPERUSER_USERNAME|g" .env
sed -i "s|export DJANGO_SUPERUSER_EMAIL=admin@example.com|export DJANGO_SUPERUSER_EMAIL=$DJANGO_SUPERUSER_EMAIL|g" .env
sed -i "s|export DJANGO_SUPERUSER_PASSWORD=mypassword|export DJANGO_SUPERUSER_PASSWORD=$DJANGO_SUPERUSER_PASSWORD|g" .env

echo "✅ .env file fully regenerated using values from $CONFIG_FILE"

# 6. Setup SSL certificates
echo "🔐 Setting up SSL certificates..."
mkdir -p "$NGINX_CERTS_PATH"

if [ ! -f "$NGINX_CERTS_PATH/cbt.slate.ng.crt" ] || [ ! -f "$NGINX_CERTS_PATH/cbt.slate.ng.key" ]; then
    echo "⚙️  Generating self-signed SSL certificates..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$NGINX_CERTS_PATH/cbt.slate.ng.key" \
        -out "$NGINX_CERTS_PATH/cbt.slate.ng.crt" \
        -subj "/CN=cbt.slate.ng" >/dev/null 2>&1
    
    chmod 644 "$NGINX_CERTS_PATH/cbt.slate.ng.crt"
    chmod 600 "$NGINX_CERTS_PATH/cbt.slate.ng.key"
    echo "✅ Certificates generated in $NGINX_CERTS_PATH"
else
    echo "🔑 Existing certificates found in $NGINX_CERTS_PATH"
fi

# 7. Update hosts file if needed
if ! grep -q "cbt.slate.ng" /etc/hosts 2>/dev/null; then
    echo "📝 Attempting to add cbt.slate.ng to /etc/hosts..."
    
    if touch /etc/hosts 2>/dev/null; then
        echo "127.0.0.1 cbt.slate.ng" >> /etc/hosts
        echo "✅ Added cbt.slate.ng to /etc/hosts"
    else
        echo "⚠️  Could not modify /etc/hosts (read-only filesystem)"
        echo "ℹ️  Please manually add this line to your hosts file:"
        echo "   127.0.0.1 cbt.slate.ng"
        echo "ℹ️  On most systems, you can do this with:"
        echo "   sudo nano /etc/hosts"
    fi
else
    echo "🔍 cbt.slate.ng already exists in /etc/hosts"
fi

# 8. Optionally start the server
read -r -p "Do you want to start the server now? (y/N): " start_now
if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
    echo "🐳 Starting containers..."
    
    # Determine which compose command to use
    if command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
        echo "ℹ️  Using Docker Compose"
    elif command -v podman-compose &>/dev/null; then
        COMPOSE_CMD="podman-compose"
        echo "ℹ️  Using Podman Compose"
    elif command -v docker &>/dev/null && docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
        echo "ℹ️  Using Docker Compose Plugin"
    else
        echo "❌ Error: No container runtime found!"
        echo "Please install either:"
        echo "1. Docker and Docker Compose (https://docs.docker.com/compose/install/)"
        echo "2. Podman and Podman Compose (https://github.com/containers/podman-compose)"
        exit 1
    fi

    # Start the containers
    $COMPOSE_CMD up -d

    echo "🚀 Deployment complete!"
    echo "🌐 Access your application at:"
    echo "   - Main app: https://cbt.slate.ng"
    echo "   - Admin interface: https://cbt.slate.ng/admin/"
else
    # Suggest the correct command for later use
    if command -v docker-compose &>/dev/null; then
        echo "ℹ️  You can start the server later with: docker-compose up -d"
    elif command -v podman-compose &>/dev/null; then
        echo "ℹ️  You can start the server later with: podman-compose up -d"
    elif command -v docker &>/dev/null && docker compose version &>/dev/null; then
        echo "ℹ️  You can start the server later with: docker compose up -d"
    else
        echo "ℹ️  Install docker-compose or podman-compose to start the server later"
    fi
fi
