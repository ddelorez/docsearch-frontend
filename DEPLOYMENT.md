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
| Authelia | OIDC identity provider (replaces Keycloak) |
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
- Python 3.12 with `passlib[bcrypt]` (for secret generation only)

---

## Step 1: Clone the Repository

```bash
git clone <repo-url> /opt/docsearch-frontend
cd /opt/docsearch-frontend
```

Verify all required files are present:

```bash
ls -la docker-compose.yml authelia.yml users_database.yml nginx.conf .env.example
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
pip3 install passlib[bcrypt]
./scripts/generate-secrets.sh
```

The script will:
1. Prompt for your cookie domain (e.g., `docsearch.example.com`)
2. Generate `AUTH_COOKIE_DOMAIN`, `AUTHELIA_STORAGE_ENCRYPTION_KEY`, `SESSION_SECRET`, `OIDC_HMAC_SECRET`, `OIDC_CLIENT_SECRET` + BCrypt hash, RSA private key, and `SECRET_KEY`
3. Write all values to `.env`
4. Write the RSA key directly into `authelia.yml`

Or generate manually:

```bash
# Authelia storage encryption key (required in v4.38+)
python3 -c "import secrets; print(secrets.token_hex(32))"

# Cookie domain (must contain a period, e.g. docsearch.example.com)
# Do NOT use 'localhost' - Authelia requires a valid FQDN for cookies

# OIDC HMAC secret (32+ characters)
python3 -c "import secrets; print(secrets.token_hex(16))"

# OIDC client secret
CLIENT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
echo "Client Secret: $CLIENT_SECRET"

# BCrypt hash of client secret (requires passlib)
pip3 install passlib[bcrypt]
python3 -c "from passlib.hash import bcrypt; print(bcrypt.hash('$CLIENT_SECRET'))"

# RSA private key for OIDC issuer (2048-bit, indented with 2 spaces)
openssl genrsa -out authelia_key.pem 2048
echo "RSA Key (copy exactly, with indentation):"
cat authelia_key.pem | awk '{print "  "$0}'
rm authelia_key.pem

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
| `AUTH_COOKIE_DOMAIN` | **Required.** Domain for auth cookies (e.g., `docsearch.example.com`). Must contain a period — `localhost` is not valid. |
| `AUTHELIA_STORAGE_ENCRYPTION_KEY` | **Required in v4.38+.** 32+ character hex string for encrypting Authelia's local storage. |
| `OIDC_ISSUER_URL` | Internal Authelia URL: `http://authelia:9091` |
| `OIDC_CLIENT_ID` | OIDC client ID: `docsearch-frontend` |
| `OIDC_CLIENT_SECRET` | Plain text client secret from Step 3 |
| `OIDC_CLIENT_SECRET_HASH` | BCrypt hash of `OIDC_CLIENT_SECRET` |
| `SESSION_SECRET` | 64 hex character session secret |
| `OIDC_HMAC_SECRET` | 32+ character HMAC secret |
| `OIDC_ISSUER_PRIVATE_KEY` | RSA private key (written to `authelia.yml` by the script) |
| `SECRET_KEY` | FastAPI session signing key (random hex) |
| `RAG_SERVICE_URL` | Internal URL of RAG backend (e.g., `http://rag-01:8000`) |
| `ALLOWED_AD_GROUPS` | Comma-separated AD groups, or empty for all users |
| `HOST` | `0.0.0.0` (bind to all interfaces) |
| `PORT` | `8000` (container port) |

---

## Step 5: Configure Authelia Authentication

### Option A: File-Based Users (Development / Small Deployments)

1. Edit `users_database.yml`:

```bash
nano users_database.yml
```

2. Add a user:

```yaml
users:
  admin:
    displayname: "Admin User"
    password: "$argon2id$v=19$m=65536,t=3,p=1$..." # generated hash
    groups:
      - admins
      - docsearch-users
```

3. Generate password hashes:

```bash
docker run --rm authelia/authelia authelia crypto hash generate argon2 --password 'your-secure-password'
```

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
- **Missing `AUTH_COOKIE_DOMAIN`** — must be a valid FQDN with a period (not `localhost`)
- **No notifier configured** — `authelia.yml` includes `notifier.filesystem` by default
- **No storage backend** — `authelia.yml` uses `storage.local` by default
- **Invalid RSA key** — must be a PEM key indented with 2 spaces under `jwks[0].key`
- **Invalid BCrypt client secret hash** — must be generated from `OIDC_CLIENT_SECRET` using passlib bcrypt
- **No `users_database.yml`** — must exist with at least one user (or LDAP configured)

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

Source files (`authelia.yml`, `users_database.yml`, `.env`) are **not** affected by `docker system prune` since they live on the host filesystem and are tracked by git.

---

## Backup & Restore

### Backup

```bash
# Backup Authelia data (sessions, encryption keys)
docker run --rm -v docsearch-frontend_authelia-data:/data -v $(pwd):/backup alpine tar czf /backup/authelia-backup.tar.gz -C /data .

# Backup Redis data
docker run --rm -v docsearch-frontend_redis-data:/data -v $(pwd):/backup alpine tar czf /backup/redis-backup.tar.gz -C /data .

# Backup configuration files
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
