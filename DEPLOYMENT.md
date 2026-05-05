# Production Deployment Guide

This guide covers deploying DocSearch Frontend on a production server.

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
| Redis | Authelia session storage |
| RAG backend | External document retrieval & chat service |

---

## Prerequisites

- Ubuntu 22.04+ (or equivalent Linux)
- Docker >= 24 with Docker Compose v2
- A domain name with DNS pointing to the server
- TLS certificate (Let's Encrypt recommended)
- Access to the RAG backend service
- Access to Active Directory/LDAP (if using AD authentication)
- Python 3.12 (for secret generation only, not for running the app)

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

Run the secret generation script:

```bash
cd /opt/docsearch-frontend
chmod +x scripts/generate-secrets.sh
./scripts/generate-secrets.sh
```

Or generate manually:

```bash
# Session secret (64 hex characters)
python3 -c "import secrets; print(secrets.token_hex(32))"

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
| `OIDC_ISSUER_URL` | Internal Authelia URL: `http://authelia:9091` |
| `OIDC_CLIENT_ID` | OIDC client ID: `docsearch-frontend` |
| `OIDC_CLIENT_SECRET` | Plain text client secret from Step 3 |
| `OIDC_CLIENT_SECRET_HASH` | BCrypt hash of `OIDC_CLIENT_SECRET` |
| `SESSION_SECRET` | 64 hex character session secret |
| `OIDC_HMAC_SECRET` | 32+ character HMAC secret |
| `OIDC_ISSUER_PRIVATE_KEY` | RSA private key (indented, 2 spaces per line) |
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

1. Uncomment `authentication_backend.ldap` in `authelia.yml`
2. Replace the `authentication_backend.file` section with the LDAP block
3. Configure:
   - `url`: LDAP server address (e.g., `ldap://ad.example.com:389` or `ldaps://...`)
   - `base_dn`: Base distinguished name (e.g., `dc=example,dc=com`)
   - `user`: Service account DN (e.g., `cn=authelia,ou=service,dc=example,dc=com`)
   - `password`: Service account password (add to `.env` as `LDAP_PASSWORD`)
4. Set `ALLOWED_AD_GROUPS` in `.env` to the groups allowed access

---

## Step 6: Update nginx.conf for Production

Edit `nginx.conf` and update:

1. **Server name**: Change `server_name _;` to `server_name docsearch.your-domain.com;`
2. **TLS paths**: Ensure `ssl_certificate` and `ssl_certificate_key` point to your certs
3. **Redirect URIs**: If using a custom domain, update redirect URIs in `authelia.yml`:
   ```yaml
   redirect_uris:
     - "https://docsearch.your-domain.com/auth/callback"
   ```

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

1. Open `https://docsearch.your-domain.com` in a browser
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

Common causes:
- Missing or invalid `users_database.yml`
- Unresolved `${VARIABLE}` in `authelia.yml` (check `.env` values)
- Invalid RSA key format (must be PEM, indented with 2 spaces)

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
