#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=".env"
AUTHELIA_FILE="authelia.yml"

echo "Generating secrets for DocSearch Frontend..."
echo ""

if [ ! -f "$ENV_FILE" ]; then
    cp .env.example "$ENV_FILE"
    echo "Created $ENV_FILE from .env.example"
fi

echo -n "Cookie domain (e.g. docsearch.example.com, or 127.0.0.1 for local): "
read -r COOKIE_DOMAIN
if [ -z "$COOKIE_DOMAIN" ]; then
    COOKIE_DOMAIN="127.0.0.1"
    echo "Using default: $COOKIE_DOMAIN"
fi

set_env() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

# Returns the value from .env, or empty string if missing OR a "changeme-*" placeholder
get_env() {
    local val
    val=$(grep -oP "^${1}=\K.*" "$ENV_FILE" 2>/dev/null || echo "")
    if [[ "$val" == changeme-* ]]; then
        echo ""
    else
        echo "$val"
    fi
}

set_env "AUTH_COOKIE_DOMAIN" "$COOKIE_DOMAIN"

AUTHELIA_STORAGE_ENCRYPTION_KEY=$(get_env AUTHELIA_STORAGE_ENCRYPTION_KEY)
if [ -z "$AUTHELIA_STORAGE_ENCRYPTION_KEY" ]; then
    AUTHELIA_STORAGE_ENCRYPTION_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    set_env "AUTHELIA_STORAGE_ENCRYPTION_KEY" "$AUTHELIA_STORAGE_ENCRYPTION_KEY"
fi
echo "[OK] AUTHELIA_STORAGE_ENCRYPTION_KEY"

AUTHELIA_RESET_PASSWORD_JWT_SECRET=$(get_env AUTHELIA_RESET_PASSWORD_JWT_SECRET)
if [ -z "$AUTHELIA_RESET_PASSWORD_JWT_SECRET" ]; then
    AUTHELIA_RESET_PASSWORD_JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    set_env "AUTHELIA_RESET_PASSWORD_JWT_SECRET" "$AUTHELIA_RESET_PASSWORD_JWT_SECRET"
fi
echo "[OK] AUTHELIA_RESET_PASSWORD_JWT_SECRET"

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
set_env "OIDC_CLIENT_ID" "$OIDC_CLIENT_ID"

OIDC_CLIENT_SECRET=$(get_env OIDC_CLIENT_SECRET)
if [ -z "$OIDC_CLIENT_SECRET" ]; then
    OIDC_CLIENT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    set_env "OIDC_CLIENT_SECRET" "$OIDC_CLIENT_SECRET"
fi
echo "Client secret (save this securely): $OIDC_CLIENT_SECRET"

# Generate BCrypt hash whenever the existing one is missing or invalid
OIDC_CLIENT_SECRET_HASH=$(get_env OIDC_CLIENT_SECRET_HASH)
# Validate that the existing hash looks like a real BCrypt hash
needs_new_hash=false
if [ -z "$OIDC_CLIENT_SECRET_HASH" ]; then
    needs_new_hash=true
else
    # Strip $$ escaping and check format
    raw_check=$(printf '%s' "$OIDC_CLIENT_SECRET_HASH" | sed 's/\$\$/\$/g')
    if [[ ! "$raw_check" =~ ^\$2[yb]\$ ]]; then
        echo "[WARN] Existing OIDC_CLIENT_SECRET_HASH is not a valid BCrypt hash; regenerating"
        needs_new_hash=true
    fi
fi
if $needs_new_hash; then
    if command -v htpasswd &>/dev/null; then
        RAW_HASH=$(htpasswd -nbB dummy "$OIDC_CLIENT_SECRET" | cut -d: -f2)
        # $$ escaping for Docker Compose .env files
        OIDC_CLIENT_SECRET_HASH=$(printf '%s' "$RAW_HASH" | sed 's/\$/\$\$/g')
        set_env "OIDC_CLIENT_SECRET_HASH" "$OIDC_CLIENT_SECRET_HASH"
        echo "[OK] OIDC_CLIENT_SECRET_HASH via htpasswd"
    else
        echo "[ERROR] htpasswd required. Install apache2-utils or httpd-tools."
        exit 1
    fi
else
    echo "[OK] OIDC_CLIENT_SECRET_HASH (existing valid hash reused)"
fi

SECRET_KEY=$(get_env SECRET_KEY)
if [ -z "$SECRET_KEY" ]; then
    SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    set_env "SECRET_KEY" "$SECRET_KEY"
fi
echo "[OK] SECRET_KEY"

if [ ! -f "oidc_key.pem" ]; then
    echo "[OK] Generating RSA private key..."
    openssl genrsa -out oidc_key.pem 2048 2>/dev/null
    chmod 600 oidc_key.pem
else
    echo "[OK] Reusing existing oidc_key.pem"
fi

# ── Export all variables needed by the Python block ──────────────────────────
export COOKIE_DOMAIN
export AUTHELIA_STORAGE_ENCRYPTION_KEY
export AUTHELIA_RESET_PASSWORD_JWT_SECRET
export OIDC_HMAC_SECRET
export OIDC_CLIENT_ID
# Unescape $$ → $ for YAML (Docker Compose escaping not needed inside authelia.yml)
OIDC_CLIENT_SECRET_HASH_RAW=$(printf '%s' "$OIDC_CLIENT_SECRET_HASH" | sed 's/\$\$/\$/g')
export OIDC_CLIENT_SECRET_HASH_RAW

# ── Pre-flight validation: catch placeholder values BEFORE writing authelia.yml ─
python3 << 'PYEOF'
import os
import sys

PLACEHOLDER_PREFIX = "changeme-"
required = {
    "AUTHELIA_STORAGE_ENCRYPTION_KEY":     os.environ["AUTHELIA_STORAGE_ENCRYPTION_KEY"],
    "AUTHELIA_RESET_PASSWORD_JWT_SECRET":  os.environ["AUTHELIA_RESET_PASSWORD_JWT_SECRET"],
    "OIDC_HMAC_SECRET":                    os.environ["OIDC_HMAC_SECRET"],
    "OIDC_CLIENT_ID":                      os.environ["OIDC_CLIENT_ID"],
    "OIDC_CLIENT_SECRET_HASH_RAW":         os.environ["OIDC_CLIENT_SECRET_HASH_RAW"],
}

errors = []
for name, value in required.items():
    if not value:
        errors.append(f"  - {name} is empty")
    elif value.startswith(PLACEHOLDER_PREFIX):
        errors.append(f"  - {name} is still a placeholder ({value!r})")

# BCrypt hash format check
hash_val = required["OIDC_CLIENT_SECRET_HASH_RAW"]
if not (hash_val.startswith("$2y$") or hash_val.startswith("$2b$")):
    errors.append(f"  - OIDC_CLIENT_SECRET_HASH_RAW is not a BCrypt hash (got: {hash_val[:20]!r})")

if errors:
    print("[ERROR] Pre-flight checks failed BEFORE writing authelia.yml:")
    for e in errors:
        print(e)
    sys.exit(1)
print("[OK] Pre-flight checks passed")
PYEOF

# ── Generate authelia.yml via PyYAML ─────────────────────────────────────────
python3 << 'PYEOF'
import yaml
import os

cookie_domain              = os.environ["COOKIE_DOMAIN"]
storage_key                = os.environ["AUTHELIA_STORAGE_ENCRYPTION_KEY"]
reset_password_jwt_secret  = os.environ["AUTHELIA_RESET_PASSWORD_JWT_SECRET"]
hmac_secret                = os.environ["OIDC_HMAC_SECRET"]
client_id                  = os.environ["OIDC_CLIENT_ID"]
client_secret_hash         = os.environ["OIDC_CLIENT_SECRET_HASH_RAW"]

with open("oidc_key.pem") as f:
    rsa_key = f.read().rstrip()

# Always https:// — nginx terminates TLS at 443 with self-signed certs even for dev
authelia_url            = f"https://{cookie_domain}/authelia/"
default_redirection_url = f"https://{cookie_domain}/"
oidc_callback_url       = f"https://{cookie_domain}/auth/callback"

config = {
    "server":                 {"address": "tcp://0.0.0.0:9091/"},
    "log":                    {"level": "info", "format": "text"},
    "storage":                {"encryption_key": storage_key,
                               "local": {"path": "/var/lib/authelia"}},
    "identity_validation":    {"reset_password": {"jwt_secret": reset_password_jwt_secret}},
    "session": {
        "name": "authelia_session",
        "same_site": "lax",
        "expiration": "1h",
        "inactivity": "5m",
        "remember_me": "1M",
        "cookies": [{
            "domain": cookie_domain,
            "authelia_url": authelia_url,
            "default_redirection_url": default_redirection_url,
        }],
    },
    "access_control": {
        "default_policy": "deny",
        "rules": [{"domain": "*", "policy": "one_factor"}],
    },
    "authentication_backend": {
        "file": {
            "path": "/config/users_database.yml",
            "password": {
                "algorithm": "argon2",
                "iterations": 3, "memory": 65536, "parallelism": 4,
                "key_length": 32, "salt_length": 16,
            },
        },
    },
    "identity_providers": {
        "oidc": {
            "hmac_secret": hmac_secret,
            "jwks": [{"key": rsa_key}],
            "enable_client_debug_messages": True,
            "clients": [{
                "client_id": client_id,
                "client_name": "DocSearch Frontend",
                "client_secret": client_secret_hash,
                "public": False,
                "authorization_policy": "one_factor",
                "redirect_uris": [oidc_callback_url, "http://localhost:8000/auth/callback"],
                "scopes": ["openid", "offline_access", "profile", "email", "groups"],
                "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"],
                "token_endpoint_auth_method": "client_secret_basic",
            }],
        },
    },
    "notifier": {
        "disable_startup_check": True,
        "filesystem": {"filename": "/var/lib/authelia/notification.txt"},
    },
}

with open("authelia.yml", "w") as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False,
              allow_unicode=True, width=120)

# Post-write validation
with open("authelia.yml") as f:
    verify = yaml.safe_load(f)

assert verify["identity_providers"]["oidc"]["jwks"][0]["key"].startswith("-----BEGIN")
assert verify["session"]["cookies"][0]["domain"] == cookie_domain
assert verify["storage"]["encryption_key"] == storage_key
assert verify["identity_validation"]["reset_password"]["jwt_secret"] == reset_password_jwt_secret
cookie = verify["session"]["cookies"][0]
assert cookie["authelia_url"] != cookie["default_redirection_url"]
assert cookie["authelia_url"].endswith("/authelia/")
print(f"[OK] authelia.yml generated — authelia_url={cookie['authelia_url']}")
PYEOF

chmod 600 "$AUTHELIA_FILE"

echo ""
echo "All secrets written to $ENV_FILE"
echo "Complete authelia.yml generated (no placeholders, valid YAML)"
echo ""
echo "Next steps:"
echo "  1. Add at least one user to users_database.yml"
echo "  2. Run: docker compose up -d"
