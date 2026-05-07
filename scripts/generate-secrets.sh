#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=".env"
AUTHELIA_FILE="authelia.yml"
HASH_FILE=".oidc_client_secret_hash"
FORCE_REGENERATE=false

# Parse flags
for arg in "$@"; do
    case $arg in
        --force|-f)
            FORCE_REGENERATE=true
            echo "[INFO] Force regenerate mode enabled — will overwrite existing secrets"
            ;;
    esac
done

# ── Handle stale users_database.yml directory early (Docker bind-mount artifact) ─
USERS_FILE="users_database.yml"
if [ -d "$USERS_FILE" ]; then
    echo "[WARN] $USERS_FILE is a directory — removing before proceeding"
    OWNER=$(stat -c '%U:%G' "$USERS_FILE" 2>/dev/null || echo 'unknown')
    if rmdir "$USERS_FILE" 2>/dev/null; then
        echo "[OK] Removed empty directory $USERS_FILE"
    elif rm -rf "$USERS_FILE" 2>/dev/null; then
        echo "[OK] Removed directory $USERS_FILE"
    else
        echo "[ERROR] Cannot remove directory $USERS_FILE (owned by: $OWNER)"
        echo "        Try: sudo rm -rf $USERS_FILE  (then re-run this script)"
        exit 1
    fi
fi

# ── Detect stale authelia-config volume that may cause directory re-creation ───
if command -v docker &>/dev/null && docker volume ls --format '{{.Name}}' | grep -q 'docsearch-frontend_authelia-config'; then
    echo "[ERROR] Stale Docker volume 'docsearch-frontend_authelia-config' exists."
    echo "        This volume used to mount /config and can cause users_database.yml to appear as a directory."
    echo "        Remove it with: docker volume rm docsearch-frontend_authelia-config"
    echo "        Then re-run this script and restart containers."
    exit 1
fi

echo "Generating secrets for DocSearch Frontend..."
echo ""

# ── Check if Docker containers are running (bind-mounts can interfere) ────────
if command -v docker &>/dev/null && docker ps | grep -q docsearch; then
    echo "[WARN] DocSearch containers appear to be running. Bind-mounts will interfere with file generation."
    echo "        Attempting to stop containers automatically..."
    if docker compose down; then
        echo "[OK] Containers stopped."
    else
        echo "[ERROR] Failed to stop containers automatically."
        echo "        Please stop them manually: docker compose down"
        echo "        Then re-run this script."
        exit 1
    fi
fi

# ── Determine sudo prefix (not needed if already root) ───────────────────────
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
elif command -v sudo &>/dev/null; then
    SUDO="sudo"
else
    SUDO=""
fi

# ── Ensure pip is available ───────────────────────────────────────────────────
if ! command -v pip3 &>/dev/null && ! python3 -m pip --version &>/dev/null 2>&1; then
    echo "[INFO] pip not found — installing python3-pip..."
    if ! $SUDO apt-get update -q && $SUDO apt-get install -y python3-pip; then
        echo "[ERROR] Failed to install python3-pip."
        echo "        Please install it manually: sudo apt install python3-pip"
        exit 1
    fi
    echo "[OK] python3-pip installed"
fi

# ── Ensure PyYAML is available for authelia.yml generation ───────────────────
if ! python3 -c "import yaml" 2>/dev/null; then
    echo "[INFO] Installing PyYAML for authelia.yml generation..."
    if ! python3 -m pip install --break-system-packages PyYAML; then
        echo "[ERROR] Failed to install PyYAML."
        echo "        Please install it manually: pip install --break-system-packages PyYAML"
        exit 1
    fi
    echo "[OK] PyYAML installed"
fi

# ── Ensure argon2-cffi is available for password hashing ─────────────────────
if ! python3 -c "from argon2 import PasswordHasher" 2>/dev/null; then
    echo "[INFO] Installing argon2-cffi for password hashing..."
    if ! python3 -m pip install --break-system-packages argon2-cffi; then
        echo "[ERROR] Failed to install argon2-cffi."
        echo "        Please install it manually: pip install --break-system-packages argon2-cffi"
        exit 1
    fi
    echo "[OK] argon2-cffi installed"
fi

# ── .env file setup ──────────────────────────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then
    cp .env.example "$ENV_FILE"
    echo "Created $ENV_FILE from .env.example"
fi

# ── Smart set_env: only set if missing, placeholder, or forced ───────────────
#   - If key doesn't exist → append
#   - If key exists but value is a placeholder ("changeme-*") → overwrite
#   - If key exists with real value and NOT forced → skip with message
set_env() {
    local key="$1" value="$2"
    local existing_val
    existing_val=$(grep -oP "^${key}=\K.*" "$ENV_FILE" 2>/dev/null || echo "")
    
    if [ -z "$existing_val" ]; then
        # Key doesn't exist — append
        # Use printf to avoid bash re-expanding $ characters in $value
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
        echo "  [SET] $key (new)"
    elif [[ "$existing_val" == changeme-* ]] && [ "$FORCE_REGENERATE" = false ]; then
        # Placeholder — overwrite
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
        echo "  [SET] $key (replaced placeholder)"
    elif [ "$FORCE_REGENERATE" = true ]; then
        # Force mode — always overwrite
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
        echo "  [SET] $key (forced overwrite)"
    else
        # Real existing value — preserve
        echo "  [SKIP] $key (already set, use --force to overwrite)"
    fi
}

# ── Get existing value or empty ──────────────────────────────────────────────
get_env() {
    local val
    val=$(grep -oP "^${1}=\K.*" "$ENV_FILE" 2>/dev/null || echo "")
    if [[ "$val" == changeme-* ]]; then
        echo ""
    else
        # printf avoids bash re-interpreting $ sequences in $val
        printf '%s\n' "$val"
    fi
}

# ── Cookie domain ────────────────────────────────────────────────────────────
COOKIE_DOMAIN=$(get_env AUTH_COOKIE_DOMAIN)
if [ -n "$COOKIE_DOMAIN" ] && [ "$FORCE_REGENERATE" = false ]; then
    echo "[OK] AUTH_COOKIE_DOMAIN (already set: $COOKIE_DOMAIN)"
else
    CURRENT_DOMAIN=$(grep '^AUTH_COOKIE_DOMAIN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo 'not set')
    echo -n "Cookie domain (e.g. docsearch.example.com, or 127.0.0.1 for local) "
    echo "(current: ${CURRENT_DOMAIN:-not set}): "
    read -r COOKIE_DOMAIN_INPUT
    if [ -z "$COOKIE_DOMAIN_INPUT" ]; then
        COOKIE_DOMAIN="${CURRENT_DOMAIN:-127.0.0.1}"
        echo "Using existing or default: $COOKIE_DOMAIN"
    else
        COOKIE_DOMAIN="$COOKIE_DOMAIN_INPUT"
    fi
    set_env "AUTH_COOKIE_DOMAIN" "$COOKIE_DOMAIN"
fi

# ── Session cookie domain ────────────────────────────────────────────────────
# This domain is used by Authelia's session cookies. In Docker environments,
# set it to the internal hostname (e.g. "authelia") so OIDC discovery works
# with X-Forwarded-Proto: https. Defaults to AUTH_COOKIE_DOMAIN if not set.
AUTHELIA_SESSION_DOMAIN=$(get_env AUTHELIA_SESSION_DOMAIN)
if [ -z "$AUTHELIA_SESSION_DOMAIN" ]; then
    AUTHELIA_SESSION_DOMAIN="$COOKIE_DOMAIN"
    set_env "AUTHELIA_SESSION_DOMAIN" "$AUTHELIA_SESSION_DOMAIN"
fi

# ── OIDC issuer URL ───────────────────────────────────────────────────────────
# This is the public-facing issuer URL. May be empty; Python will default to
# https://<AUTH_COOKIE_DOMAIN>/authelia if not set.
OIDC_ISSUER_URL=$(get_env OIDC_ISSUER_URL)

# ── Generate secrets only if missing ─────────────────────────────────────────
AUTHELIA_STORAGE_ENCRYPTION_KEY=$(get_env AUTHELIA_STORAGE_ENCRYPTION_KEY)
if [ -z "$AUTHELIA_STORAGE_ENCRYPTION_KEY" ]; then
    AUTHELIA_STORAGE_ENCRYPTION_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    set_env "AUTHELIA_STORAGE_ENCRYPTION_KEY" "$AUTHELIA_STORAGE_ENCRYPTION_KEY"
else
    echo "[OK] AUTHELIA_STORAGE_ENCRYPTION_KEY (already set)"
fi

# Handle RESET_PASSWORD_JWT_SECRET (migration from old name)
RESET_PASSWORD_JWT_SECRET=$(get_env RESET_PASSWORD_JWT_SECRET)
if [ -z "$RESET_PASSWORD_JWT_SECRET" ]; then
    OLD_VAL=$(get_env AUTHELIA_RESET_PASSWORD_JWT_SECRET)
    if [ -n "$OLD_VAL" ]; then
        RESET_PASSWORD_JWT_SECRET="$OLD_VAL"
        sed -i '/^AUTHELIA_RESET_PASSWORD_JWT_SECRET=/d' "$ENV_FILE" 2>/dev/null || true
        set_env "RESET_PASSWORD_JWT_SECRET" "$RESET_PASSWORD_JWT_SECRET"
    else
        RESET_PASSWORD_JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
        set_env "RESET_PASSWORD_JWT_SECRET" "$RESET_PASSWORD_JWT_SECRET"
    fi
else
    echo "[OK] RESET_PASSWORD_JWT_SECRET (already set)"
fi

SESSION_SECRET=$(get_env SESSION_SECRET)
if [ -z "$SESSION_SECRET" ]; then
    SESSION_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    set_env "SESSION_SECRET" "$SESSION_SECRET"
else
    echo "[OK] SESSION_SECRET (already set)"
fi

OIDC_HMAC_SECRET=$(get_env OIDC_HMAC_SECRET)
if [ -z "$OIDC_HMAC_SECRET" ]; then
    OIDC_HMAC_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(16))")
    set_env "OIDC_HMAC_SECRET" "$OIDC_HMAC_SECRET"
else
    echo "[OK] OIDC_HMAC_SECRET (already set)"
fi

OIDC_CLIENT_ID=$(get_env OIDC_CLIENT_ID)
if [ -z "$OIDC_CLIENT_ID" ]; then
    OIDC_CLIENT_ID="docsearch-frontend"
    set_env "OIDC_CLIENT_ID" "$OIDC_CLIENT_ID"
else
    echo "[OK] OIDC_CLIENT_ID (already set: $OIDC_CLIENT_ID)"
fi

OIDC_CLIENT_SECRET=$(get_env OIDC_CLIENT_SECRET)
if [ -z "$OIDC_CLIENT_SECRET" ]; then
    OIDC_CLIENT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    set_env "OIDC_CLIENT_SECRET" "$OIDC_CLIENT_SECRET"
    echo "  [SET] OIDC_CLIENT_SECRET (new — save this securely: $OIDC_CLIENT_SECRET)"
else
    echo "[OK] OIDC_CLIENT_SECRET (already set)"
fi

# Store the BCrypt hash in a separate file (NOT .env) to avoid Docker Compose's
# variable interpolation, which would expand $KA-like substrings in the hash
# even with $$ escaping.
needs_new_hash=false
if [ "$FORCE_REGENERATE" = true ]; then
    needs_new_hash=true
fi
if [ -f "$HASH_FILE" ]; then
    EXISTING_HASH=$(cat "$HASH_FILE")
    if [[ "$EXISTING_HASH" =~ ^\$2[yb]\$ ]]; then
        if [ "$FORCE_REGENERATE" = false ]; then
            needs_new_hash=false
            echo "[OK] .oidc_client_secret_hash (existing valid BCrypt hash reused)"
        else
            needs_new_hash=true
            echo "[INFO] Regenerating BCrypt hash (--force)"
        fi
    else
        echo "[WARN] Existing $HASH_FILE is not a valid BCrypt hash; regenerating"
        needs_new_hash=true
    fi
else
    needs_new_hash=true
fi

if $needs_new_hash; then
    if command -v htpasswd &>/dev/null; then
        htpasswd -nbB dummy "$OIDC_CLIENT_SECRET" | cut -d: -f2 > "$HASH_FILE"
        chmod 600 "$HASH_FILE"
        echo "[OK] BCrypt hash written to $HASH_FILE"
    else
        echo "[ERROR] htpasswd required. Install apache2-utils or httpd-tools."
        exit 1
    fi
fi

OIDC_CLIENT_SECRET_HASH=$(cat "$HASH_FILE")

SECRET_KEY=$(get_env SECRET_KEY)
if [ -z "$SECRET_KEY" ]; then
    SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    set_env "SECRET_KEY" "$SECRET_KEY"
else
    echo "[OK] SECRET_KEY (already set)"
fi

# Handle stale directory (Docker bind-mount can create one if file missing)
if [ -d "oidc_key.pem" ]; then
    echo "[WARN] oidc_key.pem is a directory (likely Docker bind-mount artifact)"
    if rmdir oidc_key.pem 2>/dev/null || rm -rf oidc_key.pem 2>/dev/null; then
        echo "[OK] Removed stale oidc_key.pem directory"
    else
        echo "[ERROR] Cannot remove oidc_key.pem directory. Try: sudo rm -rf oidc_key.pem"
        exit 1
    fi
fi

if [ ! -f "oidc_key.pem" ]; then
    echo "[OK] Generating RSA private key for OIDC..."
    openssl genrsa -out oidc_key.pem 2048 2>/dev/null
    chmod 600 oidc_key.pem
else
    echo "[OK] Reusing existing oidc_key.pem"
fi

# ── Check for SSL certificates ────────────────────────────────────────────────
# If certs/ directory doesn't exist or is missing key/cert, generate self-signed.
# Never overwrite existing certs unless --force is passed.
if [ ! -d "certs" ]; then
    mkdir -p certs
fi

cert_privkey_exists=false
cert_fullchain_exists=false
if [ -f "certs/privkey.pem" ]; then cert_privkey_exists=true; fi
if [ -f "certs/fullchain.pem" ]; then cert_fullchain_exists=true; fi

if [ "$FORCE_REGENERATE" = true ]; then
    echo "[INFO] --force: regenerating self-signed SSL certs in certs/ (overwriting existing)"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout certs/privkey.pem \
      -out certs/fullchain.pem \
      -subj "/CN=localhost" 2>/dev/null
    echo "[OK] Self-signed certificates regenerated in certs/"
elif $cert_privkey_exists && $cert_fullchain_exists; then
    echo "[OK] SSL certificates already present in certs/ (reusing existing — not regenerating)"
elif $cert_privkey_exists || $cert_fullchain_exists; then
    if $cert_privkey_exists; then
        echo "[WARN] certs/fullchain.pem missing while certs/privkey.pem exists — regenerating both"
    else
        echo "[WARN] certs/privkey.pem missing while certs/fullchain.pem exists — regenerating both"
    fi
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout certs/privkey.pem \
      -out certs/fullchain.pem \
      -subj "/CN=localhost" 2>/dev/null
    echo "[OK] Self-signed certificates generated in certs/"
else
    echo "[INFO] SSL certificates not found in certs/ — generating self-signed dev certs..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout certs/privkey.pem \
      -out certs/fullchain.pem \
      -subj "/CN=localhost" 2>/dev/null
    echo "[OK] Self-signed certificates generated in certs/"
fi

# ── Ensure authelia.yml is a writable file (handle stale dirs/perms from prior runs) ─
export COOKIE_DOMAIN
export AUTHELIA_SESSION_DOMAIN
export OIDC_ISSUER_URL
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

# ── Ensure authelia.yml is a writable file (handle stale dirs/perms from prior runs) ─
if [ -d "$AUTHELIA_FILE" ]; then
    # Docker creates a directory if a bind-mount target file doesn't exist on the host
    echo "[WARN] $AUTHELIA_FILE is a directory (likely created by Docker bind mount)"
    OWNER=$(stat -c '%U:%G' "$AUTHELIA_FILE" 2>/dev/null || echo 'unknown')
    if rmdir "$AUTHELIA_FILE" 2>/dev/null; then
        echo "[OK] Removed empty directory $AUTHELIA_FILE"
    elif rm -rf "$AUTHELIA_FILE" 2>/dev/null; then
        echo "[OK] Removed directory $AUTHELIA_FILE"
    else
        echo "[ERROR] Cannot remove directory $AUTHELIA_FILE (owned by: $OWNER)"
        echo "        Try: sudo rm -rf $AUTHELIA_FILE  (then re-run this script)"
        exit 1
    fi
elif [ -f "$AUTHELIA_FILE" ]; then
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
session_domain             = os.environ.get("AUTHELIA_SESSION_DOMAIN", cookie_domain)
storage_key                = os.environ["AUTHELIA_STORAGE_ENCRYPTION_KEY"]
reset_password_jwt_secret  = os.environ["RESET_PASSWORD_JWT_SECRET"]
hmac_secret                = os.environ["OIDC_HMAC_SECRET"]
client_id                  = os.environ["OIDC_CLIENT_ID"]
client_secret_hash         = os.environ["OIDC_CLIENT_SECRET_HASH"]
oidc_issuer_url            = os.environ.get("OIDC_ISSUER_URL") or f"https://{cookie_domain}/authelia"

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
            "domain": session_domain,
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
            "issuer": oidc_issuer_url,
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
            "issuer": oidc_issuer_url,
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
assert verify["storage"]["encryption_key"] == storage_key
assert verify["identity_validation"]["reset_password"]["jwt_secret"] == reset_password_jwt_secret
cookie = verify["session"]["cookies"][0]
assert cookie["domain"] == session_domain, f"Session domain mismatch: {cookie['domain']} != {session_domain}"
assert cookie["authelia_url"] == authelia_url
assert cookie["default_redirection_url"] == default_redirection_url
assert cookie["authelia_url"] != cookie["default_redirection_url"]
assert cookie["authelia_url"].endswith("/authelia/")
print(f"[OK] authelia.yml generated — authelia_url={cookie['authelia_url']}")
print(f"[OK] Session cookie domain: {cookie['domain']}")
print(f"[OK] PEM key block scalar: {len(key.splitlines())} lines")
PYEOF

chmod 600 "$AUTHELIA_FILE"

# ── Manage users_database.yml from .env (file authentication backend) ──────────
# This block ensures users_database.yml is populated so Authelia can start.
# If the file already contains a real user, it is left untouched.
#
# Sources (from .env):
#   ADMIN_USERNAME       — Authelia username (default: admin)
#   ADMIN_PASSWORD       — Plaintext password; auto-hashed to Argon2id by this script
#   ADMIN_EMAIL          — User email
#   ADMIN_DISPLAYNAME    — Display name
#
# Hashing strategy:
#   1. Try system Python with argon2-cffi (fast, no temp files).
#   2. Fall back to a temporary venv with pip-installed argon2-cffi.
#   The temp venv (if created) is cleaned up by the EXIT trap at the top.
#
# Idempotency:
#   - If users_database.yml already has real user data → skip entirely.
#   - If missing, empty, or still the repo placeholder (users: {}) → generate
#     it from the .env variables.
#   - --force always regenerates from current .env values.
echo ""

USERS_FILE="users_database.yml"

has_real_users() {
    # Returns 0 (true) if the file exists AND contains actual user entries.
    # Returns 1 (false) if the file is missing, empty, or just a placeholder.
    if [ ! -f "$USERS_FILE" ]; then
        return 1
    fi
    # Strip comments and blank lines, then check if any line under "users:"
    # defines a real user key (i.e. a username indented under "users:").
    # The repo ships "users: {}" as a placeholder.
    local content
    content=$(sed '/^#/d;/^[[:space:]]*$/d' "$USERS_FILE")
    # If the file just says "users: {}" or "users: null" or "users: ~" → placeholder
    if echo "$content" | grep -qE '^users:[[:space:]]*(\{\}|null|~)[[:space:]]*$'; then
        return 1
    fi
    # If there's no "users:" key at all → placeholder
    if ! echo "$content" | grep -qE '^users:'; then
        return 1
    fi
    # Check if there's an actual username entry (indented key under users:)
    if echo "$content" | grep -qE '^  [a-zA-Z0-9_.-]+:'; then
        return 0
    fi
    return 1
}

argon2_hash_password() {
    # Hashes $1 using argon2id with authelia-matching parameters.
    # Relies on argon2-cffi being pre-installed (handled before script execution).
    local password="$1"

    if ! command -v python3 >/dev/null 2>&1; then
        echo "[ERROR] python3 not found on PATH — required for Argon2 hashing."
        return 1
    fi

    # Generate the hash
    python3 - "$password" << 'PYEOF'
import sys
from argon2 import PasswordHasher
ph = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=4, hash_len=32, salt_len=16)
print(ph.hash(sys.argv[1]))
PYEOF
}

# Read values from .env
ADMIN_USER=$(get_env ADMIN_USERNAME)
ADMIN_PASS=$(get_env ADMIN_PASSWORD)
ADMIN_EMAIL_VAL=$(get_env ADMIN_EMAIL)
ADMIN_DISPLAY_VAL=$(get_env ADMIN_DISPLAYNAME)

# Migration: remove stale ADMIN_PASSWORD_HASH from .env (it's no longer stored
# there — the hash lives in users_database.yml only).  Leaving it in .env causes
# Docker Compose to interpret $argon2id$, $v, $m, etc. as undefined variables,
# producing WARN[0000] spam on every compose operation.
# Catch: (a) lines with leading whitespace, (b) any leftover $argon2id anywhere.
sed -i '/^[[:space:]]*ADMIN_PASSWORD_HASH[[:space:]]*=/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/argon2id/d' "$ENV_FILE" 2>/dev/null || true

# Apply defaults
ADMIN_USER="${ADMIN_USER:-admin}"

    if [ "$FORCE_REGENERATE" = false ] && has_real_users; then
        echo "[OK] users_database.yml already contains real user data (verified — skipping)"
    else
        # Validate that a password is set
        if [ -z "$ADMIN_PASS" ]; then
            echo "[ERROR] ADMIN_PASSWORD is not set in .env (or still set to placeholder)."
            echo "        Set a strong password in .env:"
            echo "          ADMIN_PASSWORD=YourStrongPassword"
            echo "        Then re-run this script. It will auto-hash the password to Argon2id."
            exit 1
        fi

        ADMIN_EMAIL_VAL="${ADMIN_EMAIL_VAL:-${ADMIN_USER}@example.com}"
        ADMIN_DISPLAY_VAL="${ADMIN_DISPLAY_VAL:-Administrator}"

        if [ "$FORCE_REGENERATE" = true ] && has_real_users; then
            echo "[INFO] --force: regenerating users_database.yml from .env values"
        fi

        # ── Hash the password ─────────────────────────────────────────────────────
        echo "[INFO] Generating Argon2id hash for admin user password..."
        ADMIN_HASH=$(argon2_hash_password "$ADMIN_PASS") || {
            echo "[ERROR] Failed to generate Argon2id hash."
            echo "        Ensure python3 is installed and try again."
            echo "        Alternatively, install argon2-cffi: pip install argon2-cffi"
            exit 1
        }

        if [ -z "$ADMIN_HASH" ]; then
            echo "[ERROR] Argon2id hash output was empty."
            exit 1
        fi
        echo "[OK] Argon2id hash generated"

        # ── Remove existing file if not forcing (we already handled directory at startup) ─
        if [ -f "$USERS_FILE" ]; then
            # Remove the existing file so the new one is written with current user's umask
            rm -f "$USERS_FILE"
        fi

        # ── Write users_database.yml ────────────────────────────────────────────────
        cat > "$USERS_FILE" << EOF
# Authelia users database for file-based authentication (development only).
#
# Generated by scripts/generate-secrets.sh — do not edit manually.
# For production with Active Directory/LDAP, configure the ldap backend in
# authelia.yml instead and remove this file.
#
# ── To add additional users ──────────────────────────────────────────────────
# Run generate-secrets.sh with a new username/password set, or generate a
# hash manually:
#   docker run --rm authelia/authelia authelia crypto hash generate argon2 \\
#     --password 'NewUserPassword' --random-salt \\
#     --iterations 3 --memory 65536 --parallelism 4
#
# Then append a new user block below:
#
#   newusername:
#     disabled: false
#     displayname: 'New User'
#     password: '\$argon2id\$v=19\$...'
#     email: 'newuser@example.com'
#     groups:
#       - 'dev'
#       - 'admins'
# ──────────────────────────────────────────────────────────────────────────────
---
users:
  ${ADMIN_USER}:
    disabled: false
    displayname: '${ADMIN_DISPLAY_VAL}'
    password: '${ADMIN_HASH}'
    email: '${ADMIN_EMAIL_VAL}'
    groups:
      - 'dev'
      - 'admins'
EOF

    echo "[OK] users_database.yml generated/verified for user: ${ADMIN_USER}"
fi

echo ""
echo "All secrets written to $ENV_FILE"
echo "BCrypt hash stored in $HASH_FILE (kept out of .env to avoid Docker Compose issues)"
echo "Complete authelia.yml generated"
echo "users_database.yml verified for file-based authentication"
echo ""
echo "Next steps:"
echo "  1. Review generated files (authelia.yml, users_database.yml)"
echo "  2. Run: docker compose up -d"
