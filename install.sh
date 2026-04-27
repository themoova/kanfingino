#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# Komfingino Ubuntu Installer
# Source ZIP: GitHub raw zip file
# Developed by Temmova
# ==========================================================

APP_NAME="komfingino"

# اگر فایل zip داخل branch main همین repo باشد، این لینک درست است
ZIP_URL="https://raw.githubusercontent.com/themoova/kanfingino/main/komfingino.zip"
ZIP_FILE="komfingino.zip"

DEFAULT_WEBROOT="/var/www/komfingino"
TMP_DIR="/tmp/komfingino_install_$$"

red() { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    red "This installer must be run as root."
    echo "Use:"
    echo "sudo bash install.sh"
    exit 1
  fi
}

detect_os() {
  if [ ! -f /etc/os-release ]; then
    red "Cannot detect OS. Ubuntu/Debian is required."
    exit 1
  fi

  . /etc/os-release

  case "${ID:-}" in
    ubuntu|debian)
      green "OS detected: ${PRETTY_NAME}"
      ;;
    *)
      red "This installer supports Ubuntu/Debian only. Current OS: ${ID:-unknown}"
      exit 1
      ;;
  esac
}

ask_inputs() {
  echo "===================================="
  echo " Komfingino Installer"
  echo " Developed by Temmova"
  echo "===================================="
  echo

  read -rp "Enter bot domain/subdomain, example bot.example.com: " DOMAIN
  if [ -z "$DOMAIN" ]; then
    red "Domain is required."
    exit 1
  fi

  read -rp "Enter install path [${DEFAULT_WEBROOT}]: " WEBROOT
  WEBROOT="${WEBROOT:-$DEFAULT_WEBROOT}"

  echo
  yellow "Installer settings:"
  echo "Domain:   $DOMAIN"
  echo "Webroot:  $WEBROOT"
  echo "ZIP URL:  $ZIP_URL"
  echo

  read -rp "Continue installation? [Y/n]: " CONTINUE_INSTALL
  CONTINUE_INSTALL="${CONTINUE_INSTALL:-Y}"

  if [[ ! "$CONTINUE_INSTALL" =~ ^[Yy]$ ]]; then
    yellow "Installation cancelled."
    exit 0
  fi
}

install_packages() {
  yellow "Installing required packages..."

  apt update

  DEBIAN_FRONTEND=noninteractive apt install -y \
    curl \
    unzip \
    rsync \
    ca-certificates \
    apache2 \
    php \
    php-cli \
    php-curl \
    php-sqlite3 \
    php-mbstring \
    php-xml \
    php-zip \
    php-gd \
    php-fileinfo \
    certbot \
    python3-certbot-apache

  a2enmod rewrite headers >/dev/null
}

download_zip() {
  yellow "Downloading Komfingino ZIP..."

  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"

  curl -L --fail --connect-timeout 20 --max-time 300 \
    -o "$TMP_DIR/$ZIP_FILE" \
    "$ZIP_URL"

  if [ ! -s "$TMP_DIR/$ZIP_FILE" ]; then
    red "ZIP download failed or file is empty."
    exit 1
  fi

  green "ZIP downloaded successfully."
}

extract_zip() {
  yellow "Extracting ZIP..."

  mkdir -p "$TMP_DIR/extracted"
  unzip -q "$TMP_DIR/$ZIP_FILE" -d "$TMP_DIR/extracted"

  first_dir_count=$(find "$TMP_DIR/extracted" -mindepth 1 -maxdepth 1 -type d | wc -l)
  first_file_count=$(find "$TMP_DIR/extracted" -mindepth 1 -maxdepth 1 -type f | wc -l)

  if [ "$first_dir_count" -eq 1 ] && [ "$first_file_count" -eq 0 ]; then
    SRC_DIR="$(find "$TMP_DIR/extracted" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  else
    SRC_DIR="$TMP_DIR/extracted"
  fi

  if [ ! -f "$SRC_DIR/index.php" ]; then
    red "index.php was not found inside the ZIP."
    echo "Checked path: $SRC_DIR"
    echo
    echo "Make sure komfingino.zip contains project files like:"
    echo "index.php, app/, admin/, install/, pay/, config.sample.php"
    exit 1
  fi

  green "ZIP extracted successfully."
}

deploy_files() {
  yellow "Deploying files to $WEBROOT..."

  mkdir -p "$(dirname "$WEBROOT")"

  if [ -d "$WEBROOT" ] && [ "$(ls -A "$WEBROOT" 2>/dev/null)" ]; then
    BACKUP="${WEBROOT}_backup_$(date +%Y%m%d_%H%M%S)"
    yellow "Install path is not empty. Creating backup:"
    echo "$BACKUP"
    mv "$WEBROOT" "$BACKUP"
  fi

  mkdir -p "$WEBROOT"
  rsync -a "$SRC_DIR"/ "$WEBROOT"/

  mkdir -p "$WEBROOT/storage" "$WEBROOT/logs"

  chown -R www-data:www-data "$WEBROOT"

  find "$WEBROOT" -type d -exec chmod 755 {} \;
  find "$WEBROOT" -type f -exec chmod 644 {} \;

  chmod -R 775 "$WEBROOT/storage" "$WEBROOT/logs"

  if [ -f "$WEBROOT/config.php" ]; then
    chmod 640 "$WEBROOT/config.php"
  fi

  green "Files deployed successfully."
}

setup_apache() {
  yellow "Configuring Apache..."

  cat > "/etc/apache2/sites-available/${APP_NAME}.conf" <<APACHE
<VirtualHost *:80>
    ServerName ${DOMAIN}
    DocumentRoot ${WEBROOT}

    <Directory ${WEBROOT}>
        AllowOverride All
        Require all granted
        Options -Indexes +FollowSymLinks
    </Directory>

    <Directory ${WEBROOT}/storage>
        Require all denied
    </Directory>

    <Directory ${WEBROOT}/logs>
        Require all denied
    </Directory>

    <Directory ${WEBROOT}/app>
        Require all denied
    </Directory>

    <FilesMatch "^(config\\.php|.*\\.sqlite|.*\\.sqlite3|.*\\.db|.*\\.log|\\.env)$">
        Require all denied
    </FilesMatch>

    ErrorLog \${APACHE_LOG_DIR}/${APP_NAME}_error.log
    CustomLog \${APACHE_LOG_DIR}/${APP_NAME}_access.log combined
</VirtualHost>
APACHE

  a2dissite 000-default.conf >/dev/null 2>&1 || true
  a2ensite "${APP_NAME}.conf" >/dev/null

  apache2ctl configtest
  systemctl reload apache2

  green "Apache configured successfully."
}

setup_ssl() {
  echo
  read -rp "Install free SSL with Certbot? Telegram webhook needs HTTPS. [Y/n]: " SSL_ANSWER
  SSL_ANSWER="${SSL_ANSWER:-Y}"

  if [[ "$SSL_ANSWER" =~ ^[Yy]$ ]]; then
    yellow "Installing SSL for $DOMAIN..."

    certbot --apache \
      -d "$DOMAIN" \
      --non-interactive \
      --agree-tos \
      -m "admin@$DOMAIN" \
      --redirect || {
        yellow "Automatic SSL failed."
        echo "You can run it manually later:"
        echo "sudo certbot --apache -d $DOMAIN"
      }
  else
    yellow "SSL skipped. Telegram webhook will not work without HTTPS."
  fi
}

show_final_message() {
  echo
  green "Komfingino files installed successfully."
  echo
  echo "Open this URL to finish bot setup:"
  echo "https://${DOMAIN}/install/"
  echo
  echo "In the installer, enter:"
  echo "- Bot Token"
  echo "- Admin Numeric ID"
  echo "- Base URL: https://${DOMAIN}"
  echo "- Admin panel password"
  echo "- Payment gateway settings"
  echo "- Card-to-card settings"
  echo
  yellow "After successful installation, delete install folder if it still exists:"
  echo "sudo rm -rf ${WEBROOT}/install"
  echo
}

main() {
  require_root
  detect_os
  ask_inputs
  install_packages
  download_zip
  extract_zip
  deploy_files
  setup_apache
  setup_ssl
  show_final_message
}

main "$@"
