#!/usr/bin/env bash
# Generate all required secrets for DocSearch Frontend deployment.
# Run this on the production server before first docker compose up.

set -euo pipefail

ENV_FILE=".env"

echo "Generating secrets for DocSearch Frontend..."
echo ""

# Copy .env.example if .env doesn't exist
if [ ! -f "$ENV_FILE" ]; then
    cp .env.example "$ENV_FILE"
    echo "Created $ENV_FILE from .env.example"
fi

# 1. Session secret (64 hex chars)
SESSION_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
echo "SESSION_SECRET=$SESSION_SECRET" >> "$ENV_FILE"
echo "[OK] SESSION_SECRET generated"

# 2. OIDC HMAC secret (32 hex chars)
OIDC_HMAC_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(16))")
echo "OIDC_HMAC_SECRET=$OIDC_HMAC_SECRET" >> "$ENV_FILE"
echo "[OK] OIDC_HMAC_SECRET generated"

# 3. OIDC client secret and hash
CLIENT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
echo "Client secret (save this securely): $CLIENT_SECRET"
echo "OIDC_CLIENT_SECRET=$CLIENT_SECRET" >> "$ENV_FILE"

# Generate BCrypt hash
if python3 -c "from passlib.hash import bcrypt" 2>/dev/null; then
    CLIENT_SECRET_HASH=$(python3 -c "from passlib.hash import bcrypt; print(bcrypt.hash('$CLIENT_SECRET'))")
    echo "OIDC_CLIENT_SECRET_HASH=$CLIENT_SECRET_HASH" >> "$ENV_FILE"
    echo "[OK] OIDC_CLIENT_SECRET_HASH generated"
else
    echo "[WARN] passlib[bcrypt] not installed."
    echo "  Install with: pip3 install passlib[bcrypt]"
    echo "  Then run: python3 -c \"from passlib.hash import bcrypt; print(bcrypt.hash('$CLIENT_SECRET'))\""
    echo "  And set OIDC_CLIENT_SECRET_HASH in .env manually"
fi

# 4. RSA private key for OIDC issuer
echo "[OK] Generating RSA private key..."
openssl genrsa -out authelia_key.pem 2048 2>/dev/null
RSA_KEY=$(cat authelia_key.pem | awk '{printf "  %s\n", $0}')
# Use sed to replace the placeholder in authelia.yml if it exists
if grep -q "changeme-generate-rsa-private-key" authelia.yml 2>/dev/null; then
    sed -i "s|  changeme-generate-rsa-private-key|$RSA_KEY|" authelia.yml
    echo "OIDC_ISSUER_PRIVATE_KEY=**SET_IN_AUTHLIA_YML**" >> "$ENV_FILE"
    echo "[OK] RSA key written to authelia.yml"
else
    echo "[INFO] RSA key generated. Add it to authelia.yml under issuer_private_key:"
    echo "$RSA_KEY"
fi
rm authelia_key.pem

# 5. SECRET_KEY for FastAPI
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
echo "SECRET_KEY=$SECRET_KEY" >> "$ENV_FILE"
echo "[OK] SECRET_KEY generated"

echo ""
echo "Secrets written to $ENV_FILE"
echo "Review and edit the file, then set OIDC_ISSUER_URL if needed."
echo ""
echo "Next: docker compose up -d"
