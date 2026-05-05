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

echo "Generating secrets for DocSearch Frontend..."
echo ""

# Copy .env.example if .env doesn't exist
if [ ! -f "$ENV_FILE" ]; then
    cp .env.example "$ENV_FILE"
    echo "Created $ENV_FILE from .env.example"
fi

# Copy authelia.example.yml if authelia.yml doesn't exist
if [ ! -f "authelia.yml" ]; then
    cp authelia.example.yml authelia.yml
    echo "Created authelia.yml from authelia.example.yml"
fi

# Prompt for cookie domain
echo -n "Cookie domain (e.g. docsearch.example.com, or 127.0.0.1 for local): "
read -r COOKIE_DOMAIN
if [ -z "$COOKIE_DOMAIN" ]; then
    COOKIE_DOMAIN="127.0.0.1"
    echo "Using default: $COOKIE_DOMAIN"
fi

# Helper: set or replace a variable in .env without creating duplicates
set_env() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

# Replace AUTH_COOKIE_DOMAIN
set_env "AUTH_COOKIE_DOMAIN" "$COOKIE_DOMAIN"
echo "[OK] AUTH_COOKIE_DOMAIN=$COOKIE_DOMAIN"

# 1. Authelia storage encryption key (32+ hex chars)
STORAGE_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
set_env "AUTHELIA_STORAGE_ENCRYPTION_KEY" "$STORAGE_KEY"
echo "[OK] AUTHELIA_STORAGE_ENCRYPTION_KEY generated"

# 2. Session secret (64 hex chars)
SESSION_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
set_env "SESSION_SECRET" "$SESSION_SECRET"
echo "[OK] SESSION_SECRET generated"

# 3. OIDC HMAC secret (32 hex chars)
OIDC_HMAC_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(16))")
set_env "OIDC_HMAC_SECRET" "$OIDC_HMAC_SECRET"
echo "[OK] OIDC_HMAC_SECRET generated"

# 4. OIDC client secret and BCrypt hash (using htpasswd)
CLIENT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
set_env "OIDC_CLIENT_SECRET" "$CLIENT_SECRET"
echo "Client secret (save this securely): $CLIENT_SECRET"

if command -v htpasswd &>/dev/null; then
    # htpasswd outputs username:hash; extract hash portion
    # Docker Compose requires $$ for literal $ in .env files
    RAW_HASH=$(htpasswd -nbB dummy "$CLIENT_SECRET" | cut -d: -f2)
    CLIENT_SECRET_HASH=$(printf '%s' "$RAW_HASH" | sed 's/\$/\$\$/g')
    set_env "OIDC_CLIENT_SECRET_HASH" "$CLIENT_SECRET_HASH"
    echo "[OK] OIDC_CLIENT_SECRET_HASH generated via htpasswd"
else
    echo "[WARN] htpasswd not found (install apache2-utils or httpd-tools)."
    echo "  Set OIDC_CLIENT_SECRET_HASH manually using:"
    echo "  python3 -c \"from passlib.hash import bcrypt; print(bcrypt.hash('$CLIENT_SECRET'))\""
fi

# 5. RSA private key for OIDC issuer
# Always create oidc_key.pem on disk AND embed it into authelia.yml
echo "[OK] Generating RSA private key..."
openssl genrsa -out oidc_key.pem 2048 2>/dev/null
chmod 600 oidc_key.pem

# Embed the key into authelia.yml
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

# 6. SECRET_KEY for FastAPI
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
