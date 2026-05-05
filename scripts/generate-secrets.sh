#!/usr/bin/env bash
# Generate all required secrets for DocSearch Frontend deployment.
# Run this on the production server before first docker compose up.
#
# Prerequisites:
#   - Python 3 with passlib[bcrypt]: pip3 install passlib[bcrypt]
#   - openssl (usually pre-installed)

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

# Replace AUTH_COOKIE_DOMAIN placeholder in .env
sed -i "s/^AUTH_COOKIE_DOMAIN=.*/AUTH_COOKIE_DOMAIN=$COOKIE_DOMAIN/" "$ENV_FILE"
echo "[OK] AUTH_COOKIE_DOMAIN=$COOKIE_DOMAIN"

# 1. Authelia storage encryption key (32+ hex chars)
STORAGE_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
sed -i "s/^AUTHELIA_STORAGE_ENCRYPTION_KEY=.*/AUTHELIA_STORAGE_ENCRYPTION_KEY=$STORAGE_KEY/" "$ENV_FILE"
echo "[OK] AUTHELIA_STORAGE_ENCRYPTION_KEY generated"

# 2. Reset password JWT secret (32+ hex chars)
JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
sed -i "s/^AUTHELIA_RESET_PASSWORD_JWT_SECRET=.*/AUTHELIA_RESET_PASSWORD_JWT_SECRET=$JWT_SECRET/" "$ENV_FILE"
echo "[OK] AUTHELIA_RESET_PASSWORD_JWT_SECRET generated"

# 3. Session secret (64 hex chars)
SESSION_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
sed -i "s/^SESSION_SECRET=.*/SESSION_SECRET=$SESSION_SECRET/" "$ENV_FILE"
echo "[OK] SESSION_SECRET generated"

# 4. OIDC HMAC secret (32 hex chars)
OIDC_HMAC_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(16))")
sed -i "s/^OIDC_HMAC_SECRET=.*/OIDC_HMAC_SECRET=$OIDC_HMAC_SECRET/" "$ENV_FILE"
echo "[OK] OIDC_HMAC_SECRET generated"

# 5. OIDC client secret and hash
CLIENT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
echo "Client secret (save this securely): $CLIENT_SECRET"
sed -i "s/^OIDC_CLIENT_SECRET=.*/OIDC_CLIENT_SECRET=$CLIENT_SECRET/" "$ENV_FILE"

# Generate BCrypt hash
if python3 -c "from passlib.hash import bcrypt" 2>/dev/null; then
    CLIENT_SECRET_HASH=$(python3 -c "from passlib.hash import bcrypt; print(bcrypt.hash('$CLIENT_SECRET'))")
    sed -i "s|^OIDC_CLIENT_SECRET_HASH=.*|OIDC_CLIENT_SECRET_HASH=$CLIENT_SECRET_HASH|" "$ENV_FILE"
    echo "[OK] OIDC_CLIENT_SECRET_HASH generated"
else
    echo "[WARN] passlib[bcrypt] not installed."
    echo "  Install with: pip3 install passlib[bcrypt]"
    echo "  Then run: python3 -c \"from passlib.hash import bcrypt; print(bcrypt.hash('$CLIENT_SECRET'))\""
    echo "  And set OIDC_CLIENT_SECRET_HASH in .env manually"
fi

# 6. RSA private key for OIDC issuer (embedded directly into authelia.yml)
echo "[OK] Generating RSA private key..."
openssl genrsa -out _oidc_key_tmp.pem 2048 2>/dev/null
# Read the key and indent each line with 10 spaces (to match YAML block scalar indentation)
RSA_KEY=$(cat _oidc_key_tmp.pem | sed 's/^/          /')
# Replace the placeholder in authelia.yml
sed -i "s|__RSA_KEY_PLACEHOLDER__|$RSA_KEY|" authelia.yml
rm -f _oidc_key_tmp.pem
chmod 600 authelia.yml
echo "[OK] RSA key embedded into authelia.yml"

# 7. SECRET_KEY for FastAPI
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
sed -i "s/^SECRET_KEY=.*/SECRET_KEY=$SECRET_KEY/" "$ENV_FILE"
echo "[OK] SECRET_KEY generated"

echo ""
echo "All secrets written to $ENV_FILE"
echo "RSA key embedded in authelia.yml"
echo ""
echo "Next steps:"
echo "  1. Add at least one user to users_database.yml"
echo "  2. Run: docker compose up -d"
