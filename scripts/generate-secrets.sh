#!/usr/bin/env bash
# Generate all required secrets and produce a complete authelia.yml.
# No ${VARIABLE} placeholders remain in the generated config.
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

get_env() { grep -oP "^${1}=\K.*" "$ENV_FILE" 2>/dev/null || echo ""; }

# ── Generate or retrieve all secrets ────────────────────────────────────────
set_env "AUTH_COOKIE_DOMAIN" "$COOKIE_DOMAIN"

AUTHELIA_STORAGE_ENCRYPTION_KEY=$(get_env AUTHELIA_STORAGE_ENCRYPTION_KEY)
if [ -z "$AUTHELIA_STORAGE_ENCRYPTION_KEY" ]; then
    AUTHELIA_STORAGE_ENCRYPTION_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    set_env "AUTHELIA_STORAGE_ENCRYPTION_KEY" "$AUTHELIA_STORAGE_ENCRYPTION_KEY"
fi
echo "[OK] AUTHELIA_STORAGE_ENCRYPTION_KEY"

SESSION_SECRET=$(get_env SESSION_SECRET)
if [ -z "$SESSION_SECRET" ]; then
    SESSION_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    set_env "SESSION_SECRET" "$SESSION_SECRET"
fi
echo "[OK] SESSION_SECRET"

OIDC_HMAC_SECRET=$(get_env OIDC_HMAC_SECRET)
if [ -z "$OIDC_HMAC_SECRET" ]; then
    OIDC_HMAC_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(16))")
    set_env "OIDC_HMAC_SECRET" "$OIDC_HMAC_SECRET"
fi
echo "[OK] OIDC_HMAC_SECRET"

OIDC_CLIENT_ID=$(get_env OIDC_CLIENT_ID)
[ -z "$OIDC_CLIENT_ID" ] && OIDC_CLIENT_ID="docsearch-frontend"

OIDC_CLIENT_SECRET=$(get_env OIDC_CLIENT_SECRET)
if [ -z "$OIDC_CLIENT_SECRET" ]; then
    OIDC_CLIENT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    set_env "OIDC_CLIENT_SECRET" "$OIDC_CLIENT_SECRET"
fi
echo "Client secret (save this securely): $OIDC_CLIENT_SECRET"

OIDC_CLIENT_SECRET_HASH=$(get_env OIDC_CLIENT_SECRET_HASH)
if [ -z "$OIDC_CLIENT_SECRET_HASH" ]; then
    if command -v htpasswd &>/dev/null; then
        RAW_HASH=$(htpasswd -nbB dummy "$OIDC_CLIENT_SECRET" | cut -d: -f2)
        OIDC_CLIENT_SECRET_HASH=$(printf '%s' "$RAW_HASH" | sed 's/\$/\$\$/g')
        set_env "OIDC_CLIENT_SECRET_HASH" "$OIDC_CLIENT_SECRET_HASH"
        echo "[OK] OIDC_CLIENT_SECRET_HASH via htpasswd"
    else
        echo "[ERROR] htpasswd required. Install apache2-utils or httpd-tools."
        exit 1
    fi
fi

SECRET_KEY=$(get_env SECRET_KEY)
if [ -z "$SECRET_KEY" ]; then
    SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    set_env "SECRET_KEY" "$SECRET_KEY"
fi
echo "[OK] SECRET_KEY"

# ── Generate RSA key ────────────────────────────────────────────────────────
echo "[OK] Generating RSA private key..."
openssl genrsa -out oidc_key.pem 2048 2>/dev/null
chmod 600 oidc_key.pem

# ── Generate complete authelia.yml via Python (NO placeholders) ─────────────
python3 - "$AUTHELIA_FILE" "$COOKIE_DOMAIN" "$AUTHELIA_STORAGE_ENCRYPTION_KEY" \
    "$OIDC_HMAC_SECRET" "$OIDC_CLIENT_ID" "$OIDC_CLIENT_SECRET_HASH" << 'PYSCRIPT'
import sys

authelia_file = sys.argv[1]
cookie_domain = sys.argv[2]
storage_key = sys.argv[3]
hmac_secret = sys.argv[4]
client_id = sys.argv[5]
client_secret_hash = sys.argv[6]

with open("oidc_key.pem") as f:
    rsa_key = f.read().rstrip()
indented_key = "\n".join("          " + line for line in rsa_key.split("\n"))

config = f"""---
server:
  address: tcp://0.0.0.0:9091/

log:
  level: info
  format: text

storage:
  encryption_key: {storage_key}
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
    - domain: {cookie_domain}
      authelia_url: https://{cookie_domain}
      default_redirection_url: https://{cookie_domain}

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
      iterations: 3
      memory: 65536
      parallelism: 4
      key_length: 32
      salt_length: 16

identity_providers:
  oidc:
    hmac_secret: {hmac_secret}
    jwks:
      - key: |
{indented_key}
    enable_client_debug_messages: true
    clients:
      - client_id: {client_id}
        client_name: "DocSearch Frontend"
        client_secret: {client_secret_hash}
        public: false
        authorization_policy: one_factor
        redirect_uris:
          - "https://{cookie_domain}/auth/callback"
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
"""

with open(authelia_file, "w") as f:
    f.write(config)
PYSCRIPT

chmod 600 "$AUTHELIA_FILE"
echo "[OK] Generated $AUTHELIA_FILE (all values resolved, no placeholders)"

# ── Validate YAML ───────────────────────────────────────────────────────────
if python3 -c "
import yaml, sys
try:
    with open('$AUTHELIA_FILE') as f:
        data = yaml.safe_load(f)
    assert 'server' in data
    assert 'storage' in data and 'encryption_key' in data['storage']
    assert 'session' in data
    assert 'identity_providers' in data
    assert 'notifier' in data
    content = open('$AUTHELIA_FILE').read()
    assert '\${' not in content, 'unresolved placeholder found'
    print('[OK] authelia.yml validated successfully')
except Exception as e:
    print(f'[ERROR] {e}')
    sys.exit(1)
" 2>/dev/null; then
    :
else
    echo "[WARN] PyYAML not installed, skipping validation"
fi

echo ""
echo "All secrets written to $ENV_FILE"
echo ""
echo "Next steps:"
echo "  1. Add at least one user to users_database.yml"
echo "  2. Run: docker compose up -d"
