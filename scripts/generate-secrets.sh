#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=".env"
AUTHELIA_FILE="authelia.yml"
HASH_FILE=".oidc_client_secret_hash"

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
        # Use python to do the substitution safely (no sed special-char issues)
        python3 -c "
import re, sys
key, value = sys.argv[1], sys.argv[2]
with open('$ENV_FILE') as f:
    lines = f.readlines()
with open('$ENV_FILE', 'w') as f:
    for line in lines:
        if line.startswith(key + '='):
            f.write(f'{key}={value}\n')
        else:
            f.write(line)
" "$key" "$value"
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

# Renamed from AUTHELIA_RESET_PASSWORD_JWT_SECRET — Authelia treats AUTHELIA_*
# env vars as config overrides, causing "configuration environment variable not
# expected" warnings.
RESET_PASSWORD_JWT_SECRET=$(get_env RESET_PASSWORD_JWT_SECRET)
if [ -z "$RESET_PASSWORD_JWT_SECRET" ]; then
    # Migrate from old name if present
    OLD_VAL=$(get_env AUTHELIA_RESET_PASSWORD_JWT_SECRET)
    if [ -n "$OLD_VAL" ]; then
        RESET_PASSWORD_JWT_SECRET="$OLD_VAL"
        # Remove the old key from .env
        sed -i '/^AUTHELIA_RESET_PASSWORD_JWT_SECRET=/d' "$ENV_FILE"
    else
        RESET_PASSWORD_JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    fi
    set_env "RESET_PASSWORD_JWT_SECRET" "$RESET_PASSWORD_JWT_SECRET"
fi
echo "[OK] RESET_PASSWORD_JWT_SECRET"

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

# Store the BCrypt hash in a separate file (NOT .env) to avoid Docker Compose's
# variable interpolation, which would expand $KA-like substrings in the hash
# even with $$ escaping.
needs_new_hash=true
if [ -f "$HASH_FILE" ]; then
    EXISTING_HASH=$(cat "$HASH_FILE")
    if [[ "$EXISTING_HASH" =~ ^\$2[yb]\$ ]]; then
        needs_new_hash=false
    else
        echo "[WARN] Existing $HASH_FILE is not a valid BCrypt hash; regenerating"
    fi
fi

# Also clean up any stale OIDC_CLIENT_SECRET_HASH from .env (no longer used)
sed -i '/^OIDC_CLIENT_SECRET_HASH=/d' "$ENV_FILE" 2>/dev/null || true

if $needs_new_hash; then
    if command -v htpasswd &>/dev/null; then
        htpasswd -nbB dummy "$OIDC_CLIENT_SECRET" | cut -d: -f2 > "$HASH_FILE"
        chmod 600 "$HASH_FILE"
        echo "[OK] BCrypt hash written to $HASH_FILE"
    else
        echo "[ERROR] htpasswd required. Install apache2-utils or httpd-tools."
        exit 1
    fi
else
    echo "[OK] $HASH_FILE (existing valid hash reused)"
fi

OIDC_CLIENT_SECRET_HASH=$(cat "$HASH_FILE")

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
export RESET_PASSWORD_JWT_SECRET
export OIDC_HMAC_SECRET
export OIDC_CLIENT_ID
export OIDC_CLIENT_SECRET_HASH

# ── Pre-flight validation ────────────────────────────────────────────────────
python3 << 'PYEOF'
import os, sys

PLACEHOLDER_PREFIX = "changeme-"
required = {
    "AUTHELIA_STORAGE_ENCRYPTION_KEY":  os.environ["AUTHELIA_STORAGE_ENCRYPTION_KEY"],
    "RESET_PASSWORD_JWT_SECRET":        os.environ["RESET_PASSWORD_JWT_SECRET"],
    "OIDC_HMAC_SECRET":                 os.environ["OIDC_HMAC_SECRET"],
    "OIDC_CLIENT_ID":                   os.environ["OIDC_CLIENT_ID"],
    "OIDC_CLIENT_SECRET_HASH":          os.environ["OIDC_CLIENT_SECRET_HASH"],
}

errors = []
for name, value in required.items():
    if not value:
        errors.append(f"  - {name} is empty")
    elif value.startswith(PLACEHOLDER_PREFIX):
        errors.append(f"  - {name} is still a placeholder ({value!r})")

hash_val = required["OIDC_CLIENT_SECRET_HASH"]
if not (hash_val.startswith("$2y$") or hash_val.startswith("$2b$")):
    errors.append(f"  - OIDC_CLIENT_SECRET_HASH is not a BCrypt hash (got: {hash_val[:20]!r})")

if errors:
    print("[ERROR] Pre-flight checks failed BEFORE writing authelia.yml:")
    for e in errors:
        print(e)
    sys.exit(1)
print("[OK] Pre-flight checks passed")
PYEOF

# ── Ensure authelia.yml is writable (handle stale 600-mode files from prior runs) ─
if [ -f "$AUTHELIA_FILE" ]; then
    if ! [ -w "$AUTHELIA_FILE" ]; then
        echo "[WARN] $AUTHELIA_FILE is not writable by $(whoami) — attempting to fix permissions"
        if chmod u+w "$AUTHELIA_FILE" 2>/dev/null; then
            echo "[OK] Fixed permissions on $AUTHELIA_FILE"
        else
            # File likely owned by another user (root from prior sudo run, or container)
            echo "[ERROR] Cannot make $AUTHELIA_FILE writable. Owned by: $(stat -c '%U:%G' "$AUTHELIA_FILE" 2>/dev/null || echo 'unknown')"
            echo "        Try: sudo rm -f $AUTHELIA_FILE  (then re-run this script)"
            exit 1
        fi
    fi
    # Remove the existing file so the new one is written with current user's umask
    rm -f "$AUTHELIA_FILE"
fi

# ── Generate authelia.yml via PyYAML with literal block scalar for RSA key ────
python3 << 'PYEOF'
import yaml
import os


class LiteralStr(str):
    """String type that PyYAML serializes as a literal block scalar (|)."""
    pass


def literal_str_representer(dumper, data):
    return dumper.represent_scalar(
        "tag:yaml.org,2002:str", str(data), style="|"
    )


yaml.add_representer(LiteralStr, literal_str_representer)

cookie_domain              = os.environ["COOKIE_DOMAIN"]
storage_key                = os.environ["AUTHELIA_STORAGE_ENCRYPTION_KEY"]
reset_password_jwt_secret  = os.environ["RESET_PASSWORD_JWT_SECRET"]
hmac_secret                = os.environ["OIDC_HMAC_SECRET"]
client_id                  = os.environ["OIDC_CLIENT_ID"]
client_secret_hash         = os.environ["OIDC_CLIENT_SECRET_HASH"]

with open("oidc_key.pem") as f:
    rsa_key = f.read().rstrip() + "\n"  # PEM must end with newline

# Always https:// — nginx terminates TLS at 443 with self-signed certs even for dev
authelia_url            = f"https://{cookie_domain}/authelia/"
default_redirection_url = f"https://{cookie_domain}/"
oidc_callback_url       = f"https://{cookie_domain}/auth/callback"

config = {
    "server":                 {"address": "tcp://0.0.0.0:9091/"},
    "log":                    {"level": "info", "format": "text"},
    "storage":                {"encryption_key": storage_key,
                               "local": {"path": "/var/lib/authelia/db.sqlite3"}},
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
            "jwks": [{"key": LiteralStr(rsa_key)}],
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
              allow_unicode=True, width=4096)

# Post-write validation
with open("authelia.yml") as f:
    verify = yaml.safe_load(f)

key = verify["identity_providers"]["oidc"]["jwks"][0]["key"]
assert key.startswith("-----BEGIN"), f"PEM header missing: {key[:30]!r}"
assert key.rstrip().endswith("-----"), f"PEM footer missing: {key[-30:]!r}"
assert "BEGIN PRIVATE KEY" in key or "BEGIN RSA PRIVATE KEY" in key, \
    "Not a valid PEM private key"
assert verify["session"]["cookies"][0]["domain"] == cookie_domain
assert verify["storage"]["encryption_key"] == storage_key
assert verify["identity_validation"]["reset_password"]["jwt_secret"] == reset_password_jwt_secret
cookie = verify["session"]["cookies"][0]
assert cookie["authelia_url"] != cookie["default_redirection_url"]
assert cookie["authelia_url"].endswith("/authelia/")
print(f"[OK] authelia.yml generated — authelia_url={cookie['authelia_url']}")
print(f"[OK] PEM key block scalar: {len(key.splitlines())} lines")
PYEOF

chmod 600 "$AUTHELIA_FILE"

echo ""
echo "All secrets written to $ENV_FILE"
echo "BCrypt hash stored in $HASH_FILE (kept out of .env to avoid Docker Compose issues)"
echo "Complete authelia.yml generated"
echo ""
echo "Next steps:"
echo "  1. Add at least one user to users_database.yml"
echo "  2. Run: docker compose up -d"
