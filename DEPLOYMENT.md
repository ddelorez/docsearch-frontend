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

### What You Need to Set

For a typical Docker Compose deployment, configure these variables:

| Variable | What to set | Example |
|----------|-------------|---------|
| `AUTH_COOKIE_DOMAIN` | Your production domain | `docsearch.example.com` |
| `AUTHELIA_SESSION_DOMAIN` | **For Docker:** the internal hostname `authelia` | `authelia` |
| `OIDC_ISSUER_URL` | Public HTTPS URL to Authelia | `https://docsearch.example.com/authelia` |
| `AUTHELIA_INTERNAL_URL` | **For Docker:** internal HTTP URL | `http://authelia:9091` |
| `AUTHELIA_PUBLIC_URL` | Public HTTPS URL for browser redirects | `https://docsearch.example.com/authelia` |
| `SECRET_KEY` | Generate a random 64-character hex string | (see below) |
| `ADMIN_PASSWORD` | Strong password for the admin account | `YourStrongPassword` |

**Non-Docker / external deployments:** Skip `AUTHELIA_INTERNAL_URL` and set `AUTHELIA_SESSION_DOMAIN` to the same value as `AUTH_COOKIE_DOMAIN`.

### Generating Secure Secrets

Run these commands to generate random secrets:

```bash
python3 -c "import secrets; print('SECRET_KEY:', secrets.token_hex(32))"
python3 -c "import secrets; print('SESSION_SECRET:', secrets.token_hex(32))"
python3 -c "import secrets; print('OIDC_HMAC_SECRET:', secrets.token_hex(16))"
python3 -c "import secrets; print('OIDC_CLIENT_SECRET:', secrets.token_hex(32))"
python3 -c "import secrets; print('AUTHELIA_STORAGE_ENCRYPTION_KEY:', secrets.token_hex(32))"
python3 -c "import secrets; print('RESET_PASSWORD_JWT_SECRET:', secrets.token_hex(32))"
```

Copy the generated values into your `.env` file.

### After editing `.env`

```bash
./scripts/generate-secrets.sh
```

---

### Internal vs External URLs

In Docker Compose, the frontend container communicates with Authelia over the internal Docker network (`http://authelia:9091`). This avoids TLS verification issues with self-signed certificates. Browsers, however, access Authelia via HTTPS through the nginx reverse proxy (e.g. `https://your-domain/authelia`).

To support both paths:

- **`OIDC_ISSUER_URL`** — public HTTPS base URL (e.g. `https://docsearch.example.com/authelia`). This becomes the *issuer* identifier in ID tokens and is used for browser redirects.
- **`AUTHELIA_INTERNAL_URL`** — internal HTTP base URL (e.g. `http://authelia:9091`). The frontend uses this for OIDC discovery, token exchange, and userinfo calls.
- **`AUTHELIA_PUBLIC_URL`** — also HTTPS, used to construct the login redirect (authorization endpoint). Typically the same as `OIDC_ISSUER_URL`.
- **`AUTHELIA_SESSION_DOMAIN`** — the domain for Authelia's session cookies. **For Docker Compose, set this to the internal hostname** (`authelia`) so OIDC discovery on `http://authelia:9091` (with `X-Forwarded-Proto: https`) matches the session cookie domain. For external HTTPS deployments, use your public domain (usually same as `AUTH_COOKIE_DOMAIN`). Defaults to `AUTH_COOKIE_DOMAIN` if unset.

The frontend automatically sends the `X-Forwarded-Proto: https` header on all internal calls so that Authelia treats them as secure, satisfying its OIDC requirement that the issuer use HTTPS.

**nginx configuration** already sets `X-Forwarded-Proto https` for the `/authelia/`, `/api/oidc/`, and `/.well-known/openid-configuration` locations to ensure browser-facing requests are also treated as HTTPS.

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

### "Could not perform consent" error

This error occurs when Authelia's consent screen fails to complete. The OIDC client
in `authelia.yml` is configured with `consent_mode: implicit`, which skips the
consent screen entirely for this trusted internal application.

If you see this error:

1. **Verify `consent_mode: implicit` is set** in `authelia.yml` under
   `identity_providers.oidc.clients[0]`:
   ```yaml
   clients:
     - client_id: ${OIDC_CLIENT_ID}
       # ... other fields ...
       consent_mode: implicit
   ```

2. **Restart Authelia** to pick up the config change:
   ```bash
   docker compose restart authelia
   ```

3. **Clear the `authelia-data` volume** if the error persists (stale SQLite records
   from prior failed flows may be causing the issue):
   ```bash
   docker compose down
   docker volume rm docsearch-frontend_authelia-data
   docker compose up -d
   ```
   > Warning: this resets all Authelia stored state (sessions, TOTP, WebAuthn).
   > Since only file-based user auth is configured, no user data is lost.

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

### Updating Authelia Configuration on the Server

When `authelia.example.yml` is updated (e.g., adding `consent_mode: implicit`), the
live `authelia.yml` on the server must also be updated:

1. **Option A — Re-run the secrets generation script** (if `authelia.example.yml` is the only change):
   ```bash
   ./scripts/generate-secrets.sh
   ```
   This regenerates `authelia.yml` from the updated template, preserving existing secrets in `.env`.

2. **Option B — Manually edit `authelia.yml`** on the server:
   Add the new field to the existing file without regenerating. After editing:
   ```bash
   docker compose restart authelia
   ```

> **Important:** `docker compose restart authelia` is sufficient when only `authelia.yml`
> changes. A full rebuild (`docker compose up -d --build authelia`) is only needed
> if the Authelia Docker image itself was updated.

---

## Generated Files (Gitignored)

The following files are created locally by `./scripts/generate-secrets.sh` and are **not tracked** in the repository. Fresh clones will not have them — run the script to regenerate:

| File | Purpose |
|------|---------|
| `.env` | Environment variables and secrets |
| `authelia.yml` | Authelia server configuration (embedded RSA key, secrets) |
| `users_database.yml` | File-based user database (Argon2id password hashes) |
| `oidc_key.pem` | RSA private key for OIDC provider |
| `.oidc_client_secret_hash` | BCrypt hash of `OIDC_CLIENT_SECRET` |
| `certs/` | TLS certificates (self-signed for dev, Let's Encrypt for prod) |

> **If any of these files appear as "tracked and modified" on a fresh clone**, they were accidentally committed in a prior branch. Remove them from the index with:
> ```bash
> git rm --cached .env authelia.yml users_database.yml oidc_key.pem .oidc_client_secret_hash
> git rm --cached -r certs/
> git commit -m "chore: remove accidentally tracked secret files from git index"
> ```
