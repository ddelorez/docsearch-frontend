# Production Deployment Guide

This guide covers deploying DocSearch Frontend on a production server.

> **Note:** Authelia v4.38+ is used, which requires a different configuration format than older versions. All config files in this repo are already updated for v4.38+.

---

## Architecture Overview

```
                    ┌───────────────────────────────────────────────┐
                    │              Production Server                  │
                    │                                                 │
  Browser ──HTTPS──► Nginx ──► FastAPI (uvicorn) ──► RAG (rag-01)    │
                    │    │           │                                │
                    │    │           └──► Authelia ──► Redis          │
                    └───────────────────────────────────────────────┘
```

| Component | Purpose |
|-----------|---------|
| Nginx | TLS termination, reverse proxy, static files |
| FastAPI | Server-rendered UI, OIDC authentication, RAG proxy |
| Authelia | OIDC identity provider |
| Redis | Authelia session and cache storage |
| RAG backend | External document retrieval & chat service |

---

## Prerequisites

- Ubuntu 22.04+ (or equivalent Linux)
- Docker >= 24 with Docker Compose v2
- A domain name with DNS pointing to the server (e.g., `docsearch.example.com`)
- TLS certificate (Let's Encrypt recommended)
- Access to the RAG backend service
- Access to Active Directory/LDAP (if using AD authentication)
- Python 3.12 (for random secret generation)
- `htpasswd` from `apache2-utils` or `httpd-tools` (for BCrypt hash generation)

---

## Step 1: Clone the Repository

```bash
git clone <repo-url> /opt/docsearch-frontend
cd /opt/docsearch-frontend
```

Verify all required files are present:

```bash
ls -la docker-compose.yml authelia.example.yml users_database.yml nginx.conf .env.example
```

---

## Step 2: Generate TLS Certificates

### Option A: Let's Encrypt (Production)

```bash
sudo apt install certbot
sudo certbot certonly --standalone -d docsearch.your-domain.com
sudo ln -sf /etc/letsencrypt/live/docsearch.your-domain.com/fullchain.pem certs/fullchain.pem
sudo ln -sf /etc/letsencrypt/live/docsearch.your-domain.com/privkey.pem certs/privkey.pem
```

Set up auto-renewal:

```bash
echo "0 3 * * * certbot renew --quiet && cp /etc/letsencrypt/live/docsearch.your-domain.com/fullchain.pem /opt/docsearch-frontend/certs/ && cp /etc/letsencrypt/live/docsearch.your-domain.com/privkey.pem /opt/docsearch-frontend/certs/" | sudo tee /etc/cron.d/certbot-renew
```

### Option B: Self-Signed (Development Only)

```bash
mkdir -p certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/privkey.pem \
  -out certs/fullchain.pem \
  -subj "/CN=localhost"
```

---

## Step 3: Generate Secrets

Run the automated secret generation script:

```bash
cd /opt/docsearch-frontend
chmod +x scripts/generate-secrets.sh
./scripts/generate-secrets.sh
```

The script will:
1. Copy `.env.example` → `.env` (if it doesn't exist)
2. Populate all missing secrets in `.env` (skips values that are already set)
3. Generate all required secrets and write them to `.env`
4. Generate a 2048-bit RSA key and embed it directly into `authelia.yml`
5. Generate self-signed TLS certs in `certs/` (if missing)
6. Build `users_database.yml` from `ADMIN_*` variables in `.env`
7. Set proper file permissions

The script is **idempotent**: re-running it skips secrets and files that already have real values. Use `--force` to regenerate everything.

> **Important:** Before running the script on a fresh checkout, set `ADMIN_PASSWORD` in your `.env` file with a strong password. The script will auto-hash it to Argon2id. See [Step 5: Configure Authelia Authentication](#step-5-configure-authelia-authentication) below.

Or generate manually:

```bash
# Cookie domain (must be a valid FQDN or IP address)
# Use your production domain (e.g. docsearch.example.com) or 127.0.0.1 for local

# Authelia storage encryption key (required in v4.38+)
python3 -c "import secrets; print(secrets.token_hex(32))"

# OIDC HMAC secret (32+ characters)
python3 -c "import secrets; print(secrets.token_hex(16))"

# OIDC client secret
CLIENT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
echo "Client Secret: $CLIENT_SECRET"

# BCrypt hash of client secret (requires htpasswd from apache2-utils or httpd-tools)
htpasswd -nbB dummy "$CLIENT_SECRET" | cut -d: -f2
# Note: In .env files, escape $ as $$ for Docker Compose

# RSA private key for OIDC issuer (2048-bit, embedded in authelia.yml)
# RSA key is embedded directly into authelia.yml by scripts/generate-secrets.sh
# Do NOT attempt to embed manually with sed — it will break on PEM special characters

# Session secret (64 hex characters)
python3 -c "import secrets; print(secrets.token_hex(32))"

# FastAPI SECRET_KEY
python3 -c "import secrets; print(secrets.token_hex(32))"
```

---

## Step 4: Configure Environment Variables

```bash
cp .env.example .env
nano .env
```

Fill in the generated values:

| Variable | Description |
|----------|-------------|
| `AUTH_COOKIE_DOMAIN` | **Required.** Domain for auth cookies (e.g., `docsearch.example.com` or `127.0.0.1`). Must be a valid FQDN or IP address. |
| `AUTHELIA_STORAGE_ENCRYPTION_KEY` | **Required in v4.38+.** 32+ character hex string for encrypting Authelia's local storage. |
| `OIDC_ISSUER_URL` | Public-facing Authelia URL (HTTPS, e.g. `https://docsearch.example.com/authelia`). Used for browser redirects. |
| `AUTHELIA_INTERNAL_URL` | Internal Docker-network URL for server-to-server OIDC discovery (e.g. `http://authelia:9091`). Avoids SSL errors with self-signed certs. |
| `AUTHELIA_PUBLIC_URL` | Public URL for browser OIDC login redirects. Must match nginx proxy path. |
| `OIDC_CLIENT_ID` | OIDC client ID: `docsearch-frontend` |
| `OIDC_CLIENT_SECRET` | Plain text client secret from Step 3 |
| `SESSION_SECRET` | 64 hex character session secret |
| `OIDC_HMAC_SECRET` | 32+ character HMAC secret |
| `SECRET_KEY` | FastAPI session signing key (random hex) |
| `RAG_SERVICE_URL` | Internal URL of RAG backend (e.g., `http://rag-01:8000`) |
| `ALLOWED_AD_GROUPS` | Comma-separated AD groups, or empty for all users |
| `ADMIN_USERNAME` | File-based Authelia username (default: `admin`). Used by `generate-secrets.sh` to build `users_database.yml`. |
| `ADMIN_PASSWORD` | **Required for file auth.** Plaintext password — auto-hashed to Argon2id by the script. |
| `ADMIN_EMAIL` | Admin user email address. |
| `ADMIN_DISPLAYNAME` | Admin user display name. |
| `HOST` | `0.0.0.0` (bind to all interfaces) |
| `PORT` | `8000` (container port) |

---

## Step 5: Configure Authelia Authentication

### Option A: File-Based Users (Development / Small Deployments)

The `generate-secrets.sh` script automatically creates `users_database.yml` from `.env` variables and hashes the password using Argon2id (no manual hash generation needed).

1. **Set admin variables in `.env`:**

   ```env
   ADMIN_USERNAME=admin
   ADMIN_PASSWORD=YourStrongPassword   # ← the script auto-hashes this
   ADMIN_EMAIL=admin@example.com
   ADMIN_DISPLAYNAME=Administrator
   ```

2. **Run the script to generate `users_database.yml`:**

   ```bash
   ./scripts/generate-secrets.sh
   ```

   The script will auto-hash the password to Argon2id. It tries `argon2-cffi` in system Python first (fast), and falls back to a temporary venv if needed (cleaned up automatically).

3. **Adding additional users:**

   Edit `users_database.yml` directly (it is gitignored). Generate additional hashes with:

   ```bash
   docker run --rm authelia/authelia authelia crypto hash generate argon2 \
     --password 'NewUserPassword' --random-salt \
     --iterations 3 --memory 65536 --parallelism 4
   ```

   Then append user blocks:

   ```yaml
   users:
     admin:
       disabled: false
       displayname: 'Administrator'
       password: '$argon2id$v=19$...'
       email: 'admin@example.com'
       groups:
         - 'admins'
     newuser:
       disabled: false
       displayname: 'New User'
       password: '$argon2id$v=19$...'
       email: 'newuser@example.com'
       groups:
         - 'docsearch-users'
   ```

   > **Note:** If you manually edit `users_database.yml` and then re-run `generate-secrets.sh`, the script will detect existing user data and skip overwriting it (unless `--force` is passed).

### Option B: Active Directory / LDAP (Production)

1. Replace the `authentication_backend.file` section in `authelia.yml` with:

```yaml
authentication_backend:
  ldap:
    implementation: activedirectory
    url: ldaps://ad.example.com:636
    timeout: 5s
    start_tls: false
    base_dn: dc=example,dc=com
    username_attribute: sAMAccountName
    additional_users_dn: ou=users
    users_filter: (&({username_attribute}={input})(objectClass=person))
    additional_groups_dn: ou=groups
    groups_filter: (member={dn})
    group_name_attribute: cn
    mail_attribute: mail
    display_name_attribute: displayName
    user: cn=authelia,ou=service,dc=example,dc=com
    password: ${LDAP_PASSWORD}
```

2. Add `LDAP_PASSWORD` to `.env`
3. Set `ALLOWED_AD_GROUPS` in `.env` to the groups allowed access

---

## Step 6: Configure Domain and Redirect URIs

### Update `.env`

Set `AUTH_COOKIE_DOMAIN` to your production domain:

```
AUTH_COOKIE_DOMAIN=docsearch.example.com
```

### Update `nginx.conf`

Change `server_name _;` to your domain:

```nginx
server_name docsearch.example.com;
```

### Redirect URIs

The `authelia.yml` uses `${AUTH_COOKIE_DOMAIN}` for redirect URIs, so they will automatically resolve from your `.env`. No manual edit needed.

---

## Step 7: Start the Stack

```bash
cd /opt/docsearch-frontend
docker compose pull    # Pull latest images
docker compose up -d   # Start all services
```

Verify all containers are healthy:

```bash
docker compose ps
docker compose logs --tail=50
```

Check individual service health:

```bash
# Authelia
curl -f http://localhost:9091/api/health

# Frontend
curl -f http://localhost:8000/health

# Nginx (HTTPS)
curl -fk https://localhost/health
```

---

## Step 8: Verify Deployment

1. Open `https://docsearch.example.com` in a browser
2. You should be redirected to the Authelia login page
3. Log in with a file-based user or AD credentials
4. Verify search functionality works
5. Check group filtering (if `ALLOWED_AD_GROUPS` is set)

---

## Troubleshooting

### Authelia fails to start

```bash
docker compose logs authelia
```

Common causes in Authelia v4.38+:
- **Missing `AUTHELIA_STORAGE_ENCRYPTION_KEY`** — must be a 32+ character hex string in `.env`
- **Missing `AUTH_COOKIE_DOMAIN`** — must be a valid FQDN or IP address (not `localhost`)
- **No `users_database.yml`** — must exist with at least one user (or LDAP configured)
- **Invalid RSA key** — must be a valid PEM key embedded under `jwks[0].key` in `authelia.yml`
- **Invalid BCrypt client secret hash** — must be generated from `OIDC_CLIENT_SECRET` using `htpasswd -nbB`
- **No notifier configured** — `authelia.yml` includes `notifier.filesystem` by default

### Frontend fails to start

```bash
docker compose logs frontend
```

Common causes:
- Missing required env vars in `.env` (check `OIDC_ISSUER_URL`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`)
- `SECRET_KEY` not set
- Cannot reach Authelia at `OIDC_ISSUER_URL`

### Nginx fails to start

```bash
docker compose logs nginx
```

Common causes:
- Missing TLS certificates in `certs/` directory
- Invalid `nginx.conf` syntax

### 401 after login callback

- Verify `OIDC_CLIENT_SECRET` and `OIDC_CLIENT_SECRET_HASH` match
- Ensure `OIDC_CLIENT_SECRET_HASH` is a valid BCrypt hash of `OIDC_CLIENT_SECRET`
- Check redirect URIs in `authelia.yml` match the actual callback URL

### `docker system prune -a --volumes` removes data

This command removes all unused volumes, which will delete:
- `authelia-data` (session storage, encryption keys)
- `redis-data` (Redis persistence)

To recover:
1. Regenerate secrets if needed (they're in `.env`, not volumes)
2. Re-add users to `users_database.yml`
3. Restart: `docker compose up -d`

Source files (`.env`, `authelia.yml`, `users_database.yml`) are **not** affected by `docker system prune` since they live on the host filesystem. Note that `authelia.yml` is gitignored (it contains embedded secrets) — the template `authelia.example.yml` is tracked instead.

---

## Backup & Restore

### Backup

```bash
# Backup Authelia data (sessions, encryption keys)
docker run --rm -v docsearch-frontend_authelia-data:/data -v $(pwd):/backup alpine tar czf /backup/authelia-backup.tar.gz -C /data .

# Backup Redis data
docker run --rm -v docsearch-frontend_redis-data:/data -v $(pwd):/backup alpine tar czf /backup/redis-backup.tar.gz -C /data .

# Backup configuration files (including secrets)
cp authelia.yml users_database.yml .env nginx.conf /backup/
```

### Restore

```bash
docker compose down
docker run --rm -v docsearch-frontend_authelia-data:/data -v $(pwd):/backup alpine tar xzf /backup/authelia-backup.tar.gz -C /data
docker run --rm -v docsearch-frontend_redis-data:/data -v $(pwd):/backup alpine tar xzf /backup/redis-backup.tar.gz -C /data
docker compose up -d
```

---

## Updating

```bash
cd /opt/docsearch-frontend
git pull
docker compose pull
docker compose up -d --remove-orphans
```

> **Note:** `authelia.yml` contains embedded secrets and is gitignored. `users_database.yml` is also gitignored and managed by `generate-secrets.sh`. After pulling updates, verify both files are still correct and re-run `./scripts/generate-secrets.sh` if needed.
