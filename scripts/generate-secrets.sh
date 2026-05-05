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

# ── Embedded Authelia template (used if authelia.example.yml is missing) ──
AUTHELIA_TEMPLATE='---
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
    filename: /var/lib/authelia/notification.txt'

echo "Generating secrets for DocSearch Frontend..."
echo ""

# ── Create .env from example ────────────────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then
    cp .env.example "$ENV_FILE"
    echo "Created $ENV_FILE from .env.example"
fi

# ── Create authelia.yml from example or embedded template ───────────────────
if [ ! -f "authelia.yml" ]; then
    if [ -f "authelia.example.yml" ]; then
        cp authelia.example.yml authelia.yml
        echo "Created authelia.yml from authelia.example.yml"
    else
        echo "[WARN] authelia.example.yml not found, using embedded template"
        echo "$AUTHELIA_TEMPLATE" > authelia.yml
        echo "Created authelia.yml from embedded template"
    fi
fi

# ── Validate required sections in authelia.yml ──────────────────────────────
REQUIRED_SECTIONS=(
    "server:"
    "storage:"
    "session:"
    "access_control:"
    "authentication_backend:"
    "identity_providers:"
    "notifier:"
)
for section in "${REQUIRED_SECTIONS[@]}"; do
    if ! grep -q "$section" authelia.yml; then
        echo "[ERROR] authelia.yml is missing required section: $section"
        exit 1
    fi
done
echo "[OK] authelia.yml contains all required sections"

# ── Validate placeholders match .env.example ────────────────────────────────
ENV_VARS=$(grep -oP '\$\{[A-Z_]+\}' authelia.yml | sed 's/[${}]//g' | sort -u)
for var in $ENV_VARS; do
    if ! grep -q "^${var}=" "$ENV_FILE" 2>/dev/null; then
        echo "[ERROR] authelia.yml uses \${$var} but it is not defined in $ENV_FILE"
        exit 1
    fi
done
echo "[OK] All authelia.yml variables are defined in .env"

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

# Embed the key into authelia.yml using Python (safe for multi-line PEM)
python3 -c "
with open('oidc_key.pem') as f:
    key = f.read()
with open('authelia.yml') as f:
    content = f.read()
indented_key = '\n'.join('          ' + line for line in key.rstrip().split('\n'))
content = content.replace('__RSA_KEY_PLACEHOLDER__', indented_key)
with open('authelia.yml', 'w') as f:
    f.write(content)
"
chmod 600 authelia.yml
echo "[OK] RSA key saved to oidc_key.pem and embedded into authelia.yml"

SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
set_env "SECRET_KEY" "$SECRET_KEY"
echo "[OK] SECRET_KEY generated"

echo ""
echo "All secrets written to $ENV_FILE"
echo "RSA key saved as oidc_key.pem and embedded in authelia.yml"
echo ""
echo "Next steps:"
echo "  1. Add at least one user to users_database.yml"
echo "  2. Run: docker compose up -d"
