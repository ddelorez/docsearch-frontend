#!/usr/bin/env bash
# Generate all required secrets for DocSearch Frontend deployment.
# Run this on the production server before first docker compose up.
#
# Prerequisites:
#   - Python 3 (for random secret generation)
#   - openssl (for RSA key generation)
#   - htpasswd (for BCrypt hash generation, usually in apache2-utils)

set -euo pipefail

ENV_FILE=".env"
AUTHELIA_FILE="authelia.yml"

echo "Generating secrets for DocSearch Frontend..."
echo ""

# ── Create .env from example ────────────────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then
    cp .env.example "$ENV_FILE"
    echo "Created $ENV_FILE from .env.example"
fi

# ── Create authelia.yml from example or embedded template ───────────────────
if [ ! -f "$AUTHELIA_FILE" ]; then
    if [ -f "authelia.example.yml" ]; then
        cp authelia.example.yml "$AUTHELIA_FILE"
        echo "Created $AUTHELIA_FILE from authelia.example.yml"
    else
        echo "[INFO] authelia.example.yml not found, using embedded template"
        cat > "$AUTHELIA_FILE" << 'YAML_TEMPLATE'
---
server:
  address: tcp://0.0.0.0:9091/

log:
  level: info
  format: text

storage:
  encryption_key: ${AUTHELIA_STORAGE_ENCRYPTION_KEY}
  local:
    path: /var/lib/authelia

identity_validation:
  reset_password:
    disable: true

session:
  name: authelia_session
  same_site: lax
  expiration: 1h
  inactivity: 5m
  remember_me: 1M
  cookies:
    - domain: ${AUTH_COOKIE_DOMAIN}
      authelia_url: https://${AUTH_COOKIE_DOMAIN}
      default_redirection_url: https://${AUTH_COOKIE_DOMAIN}

access_control:
  default_policy: deny
  rules:
    - domain: "*"
      policy: one_factor

authentication_backend:
  file:
    path: /config/users_database.yml
    password:
      algorithm: argon2

identity_providers:
  oidc:
    hmac_secret: ${OIDC_HMAC_SECRET}
    jwks:
      - key: |
          __RSA_KEY_PLACEHOLDER__
    enable_client_debug_messages: true
    clients:
      - client_id: ${OIDC_CLIENT_ID}
        client_name: "DocSearch Frontend"
        client_secret: ${OIDC_CLIENT_SECRET_HASH}
        public: false
        authorization_policy: one_factor
        redirect_uris:
          - "https://${AUTH_COOKIE_DOMAIN}/auth/callback"
          - "http://localhost:8000/auth/callback"
        scopes:
          - openid
          - profile
          - email
          - groups
        grant_types:
          - authorization_code
          - refresh_token
        response_types:
          - code
        token_endpoint_auth_method: client_secret_basic

notifier:
  disable_startup_check: true
  filesystem:
    filename: /var/lib/authelia/notification.txt
YAML_TEMPLATE
        echo "Created $AUTHELIA_FILE from embedded template"
    fi
fi

# ── Validate required sections ──────────────────────────────────────────────
REQUIRED_SECTIONS=("server:" "storage:" "session:" "access_control:" "authentication_backend:" "identity_providers:" "notifier:")
for section in "${REQUIRED_SECTIONS[@]}"; do
    if ! grep -q "$section" "$AUTHELIA_FILE"; then
        echo "[ERROR] $AUTHELIA_FILE is missing required section: $section"
        exit 1
    fi
done
echo "[OK] $AUTHELIA_FILE contains all required sections"

# ── Validate YAML syntax ────────────────────────────────────────────────────
if python3 -c "import yaml; yaml.safe_load(open('$AUTHELIA_FILE'))" 2>/dev/null; then
    echo "[OK] $AUTHELIA_FILE has valid YAML syntax (pre-key embedding)"
else
    # Placeholder causes yaml.safe_load to fail; check structure instead
    if python3 -c "
import yaml, sys
with open('$AUTHELIA_FILE') as f:
    content = f.read().replace('__RSA_KEY_PLACEHOLDER__', 'dummy')
try:
    yaml.safe_load(content)
    sys.exit(0)
except yaml.YAMLError as e:
    print(e)
    sys.exit(1)
" 2>/dev/null; then
        echo "[OK] $AUTHELIA_FILE has valid YAML syntax (pre-key embedding)"
    else
        echo "[ERROR] $AUTHELIA_FILE has invalid YAML syntax"
        exit 1
    fi
fi

# ── Validate placeholders match .env ────────────────────────────────────────
MISSING_VARS=""
for var in AUTHELIA_STORAGE_ENCRYPTION_KEY AUTH_COOKIE_DOMAIN OIDC_HMAC_SECRET OIDC_CLIENT_ID OIDC_CLIENT_SECRET_HASH; do
    if ! grep -q "^${var}=" "$ENV_FILE" 2>/dev/null; then
        MISSING_VARS="$MISSING_VARS \${$var}"
    fi
done
if [ -n "$MISSING_VARS" ]; then
    echo "[ERROR] $AUTHELIA_FILE uses undefined variables:$MISSING_VARS"
    exit 1
fi
echo "[OK] All $AUTHELIA_FILE variables are defined in .env"

# ── Prompt for cookie domain ────────────────────────────────────────────────
echo -n "Cookie domain (e.g. docsearch.example.com, or 127.0.0.1 for local): "
read -r COOKIE_DOMAIN
if [ -z "$COOKIE_DOMAIN" ]; then
    COOKIE_DOMAIN="127.0.0.1"
    echo "Using default: $COOKIE_DOMAIN"
fi

# ── Helper: set or replace a variable in .env without duplicates ────────────
set_env() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

# ── Generate secrets ────────────────────────────────────────────────────────
set_env "AUTH_COOKIE_DOMAIN" "$COOKIE_DOMAIN"
echo "[OK] AUTH_COOKIE_DOMAIN=$COOKIE_DOMAIN"

STORAGE_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
set_env "AUTHELIA_STORAGE_ENCRYPTION_KEY" "$STORAGE_KEY"
echo "[OK] AUTHELIA_STORAGE_ENCRYPTION_KEY generated"

SESSION_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
set_env "SESSION_SECRET" "$SESSION_SECRET"
echo "[OK] SESSION_SECRET generated"

OIDC_HMAC_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(16))")
set_env "OIDC_HMAC_SECRET" "$OIDC_HMAC_SECRET"
echo "[OK] OIDC_HMAC_SECRET generated"

CLIENT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
set_env "OIDC_CLIENT_SECRET" "$CLIENT_SECRET"
echo "Client secret (save this securely): $CLIENT_SECRET"

if command -v htpasswd &>/dev/null; then
    RAW_HASH=$(htpasswd -nbB dummy "$CLIENT_SECRET" | cut -d: -f2)
    CLIENT_SECRET_HASH=$(printf '%s' "$RAW_HASH" | sed 's/\$/\$\$/g')
    set_env "OIDC_CLIENT_SECRET_HASH" "$CLIENT_SECRET_HASH"
    echo "[OK] OIDC_CLIENT_SECRET_HASH generated via htpasswd"
else
    echo "[WARN] htpasswd not found (install apache2-utils or httpd-tools)."
    echo "  Set OIDC_CLIENT_SECRET_HASH manually using:"
    echo "  python3 -c \"from passlib.hash import bcrypt; print(bcrypt.hash('$CLIENT_SECRET'))\""
fi

echo "[OK] Generating RSA private key..."
openssl genrsa -out oidc_key.pem 2048 2>/dev/null
chmod 600 oidc_key.pem

# Embed the key into authelia.yml using Python
python3 -c "
with open('oidc_key.pem') as f:
    key = f.read()
with open('$AUTHELIA_FILE') as f:
    content = f.read()
indented_key = '\n'.join('          ' + line for line in key.rstrip().split('\n'))
content = content.replace('__RSA_KEY_PLACEHOLDER__', indented_key)
with open('$AUTHELIA_FILE', 'w') as f:
    f.write(content)
"
chmod 600 "$AUTHELIA_FILE"
echo "[OK] RSA key saved to oidc_key.pem and embedded into $AUTHELIA_FILE"

# ── Final YAML validation after key embedding ───────────────────────────────
if python3 -c "
import yaml, sys
try:
    with open('$AUTHELIA_FILE') as f:
        yaml.safe_load(f)
    sys.exit(0)
except yaml.YAMLError as e:
    print(f'[ERROR] Invalid YAML after key embedding: {e}')
    sys.exit(1)
" 2>/dev/null; then
    echo "[OK] $AUTHELIA_FILE has valid YAML syntax (post-key embedding)"
else
    echo "[WARN] YAML validation skipped (PyYAML not installed)"
fi

SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
set_env "SECRET_KEY" "$SECRET_KEY"
echo "[OK] SECRET_KEY generated"

echo ""
echo "All secrets written to $ENV_FILE"
echo "RSA key saved as oidc_key.pem and embedded in $AUTHELIA_FILE"
echo ""
echo "Next steps:"
echo "  1. Add at least one user to users_database.yml"
echo "  2. Run: docker compose up -d"
