# DocSearch Frontend

Internal document search platform frontend — FastAPI, HTMX, Tailwind CSS, Authelia OIDC.

---

## Architecture

```
                          ┌───────────────────────────────────────────────┐
                          │               Docker network (internal)        │
                          │                                                │
  Browser ──HTTPS──► Nginx ──► FastAPI (uvicorn) ──► RAG backend (rag-01) │
                          │          │                                     │
                          │          └──► Authelia ──► Redis               │
                          └───────────────────────────────────────────────┘
```

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Frontend  | FastAPI + Jinja2 + HTMX | Server-rendered UI, OIDC auth |
| Styling   | Tailwind CSS (CDN) | Utility-first CSS, dark mode |
| Auth      | Authelia + Authlib | OIDC / OpenID Connect |
| Proxy     | Nginx | TLS termination, static files |
| Search    | RAG backend (external) | Document retrieval & chat |

---

## Prerequisites

- Docker >= 24 and Docker Compose v2
- Python 3.12 (for local development)
- Authelia (bundled Docker service)
- Access to the RAG backend service

---

## Local Development Setup

```bash
# 1. Clone and enter the project
git clone <repo-url> docsearch-frontend
cd docsearch-frontend

# 2. Create a virtual environment and install dependencies
python3.12 -m venv .venv
source .venv/bin/activate        # Linux / macOS
# .venv\Scripts\activate         # Windows

pip install -r requirements.txt

# 3. Configure environment variables
cp .env.example .env
# Edit .env with your Authelia URL, OIDC client credentials, and SECRET_KEY

# 4. Run the development server
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Open http://localhost:8000 – you will be redirected to Authelia to sign in.

---

## Docker Setup

### Generate self-signed TLS certificates (development only)

```bash
mkdir -p certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/privkey.pem \
  -out certs/fullchain.pem \
  -subj "/CN=localhost"
```

### Generate required secrets

```bash
# Session secret (64 hex characters)
python -c "import secrets; print(secrets.token_hex(32))"

# OIDC HMAC secret (32+ characters)
python -c "import secrets; print(secrets.token_hex(16))"

# OIDC client secret and its BCrypt hash
CLIENT_SECRET=$(python -c "import secrets; print(secrets.token_hex(32))")
echo "Client Secret: $CLIENT_SECRET"
python -c "from passlib.hash import bcrypt; print(bcrypt.hash('$CLIENT_SECRET'))"

# RSA private key for OIDC issuer (2048-bit)
openssl genrsa -out authelia_key.pem 2048
cat authelia_key.pem | awk '{print "  "$0}'
rm authelia_key.pem
```

### Start all services

```bash
cp .env.example .env
# Edit .env with generated secrets

docker compose up -d
```

Services start order: Redis -> Authelia -> FastAPI -> Nginx.

Access the app at https://localhost (port 443).

### Stop services

```bash
docker compose down
# To also remove volumes (session data):
docker compose down -v
```

---

## Authentication Setup (Authelia + OIDC)

### Quick Start (Development)

1. **Generate required secrets** (see Docker Setup section above)

2. **Configure Authelia:**
   - Copy `.env.example` to `.env` and fill in generated values
   - For development without AD, Authelia uses file-based users (see Authelia docs)
   - For AD integration, uncomment and configure `authentication_backend.ldap` in `authelia.yml`

3. **Start the stack:**
   ```bash
   docker compose up -d
   ```

4. **Access points:**
   - Application: `https://localhost` (port 443)
   - Authelia portal: `http://localhost:9091`

### OIDC Client Configuration

- **Client ID:** `docsearch-frontend` (set via `OIDC_CLIENT_ID`)
- **Redirect URI:** `https://localhost/auth/callback`
- **Scopes:** `openid profile email groups`
- **Grant Types:** `authorization_code`, `refresh_token`

### Active Directory Integration

1. Uncomment `authentication_backend.ldap` in `authelia.yml`
2. Configure AD parameters:
   - `url`: LDAP server address (e.g., `ldap://ad.example.com:389`)
   - `base_dn`: Base distinguished name (e.g., `dc=example,dc=com`)
   - `user`: Service account DN (e.g., `cn=authelia,ou=service,dc=example,dc=com`)
   - `password`: Service account password (store in `.env` as `LDAP_PASSWORD`)
3. Set `ALLOWED_AD_GROUPS` in `.env` to comma-separated group names

### Group-Based Access Control

- Users must belong to at least one group in `ALLOWED_AD_GROUPS`
- Group membership is extracted from OIDC `groups` claim
- `X-AD-Groups` header is automatically forwarded to RAG backend

---

## RAG Backend API Contract

The frontend expects the following from `RAG_SERVICE_URL`:

### `POST /query`

Request:
```json
{
  "query": "search terms",
  "page": 1,
  "page_size": 10
}
```

Response:
```json
{
  "total": 42,
  "results": [
    {
      "title": "Document Title",
      "snippet": "Relevant excerpt from the document…",
      "source_path": "\\\\server\\share\\path\\to\\document.pdf",
      "score": 0.92,
      "date_modified": "2024-01-15"
    }
  ]
}
```

### `POST /chat`

Request:
```json
{
  "question": "What does the Q3 report say about revenue?",
  "history": [
    {"role": "user", "content": "previous question"},
    {"role": "assistant", "content": "previous answer"}
  ]
}
```

Response:
```json
{
  "answer": "According to the Q3 report…",
  "sources": [
    {"title": "Q3 Report", "source_path": "\\\\srv\\reports\\q3.pdf"}
  ]
}
```

---

## Running Tests

```bash
source .venv/bin/activate

# All tests with coverage
pytest tests/ --asyncio-mode=auto --cov=app --cov-report=term-missing

# Specific test file
pytest tests/test_auth.py -v

# Lint
ruff check app/ tests/
ruff format --check app/ tests/

# Type check (matches CI flags exactly)
mypy app/ --ignore-missing-imports --warn-unused-ignores --python-version 3.12
```

---

## Environment Variables Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OIDC_ISSUER_URL` | Yes | — | Base URL of Authelia (no trailing slash) |
| `OIDC_CLIENT_ID` | Yes | — | OIDC client ID |
| `OIDC_CLIENT_SECRET` | Yes | — | OIDC client secret (plain text) |
| `RAG_SERVICE_URL` | No | `http://rag-01:8000` | RAG backend base URL |
| `SECRET_KEY` | Yes | — | Session signing key (random hex, >= 32 bytes) |
| `ALLOWED_AD_GROUPS` | No | `""` (all) | Comma-separated AD groups allowed access |
| `HOST` | No | `0.0.0.0` | Uvicorn bind host |
| `PORT` | No | `8000` | Uvicorn bind port |

Generate a secure `SECRET_KEY`:
```bash
python -c "import secrets; print(secrets.token_hex(32))"
```

---

## UNC Path Links (Windows)

Search results include clickable `file:////server/share/…` links for Windows network paths. Browser behaviour:

- **Internet Explorer / Edge Legacy**: works natively for Intranet Zone sites.
- **Chrome / Edge Chromium**: blocked by default. Administrators can allow via Group Policy (`URLAllowlist`) or a browser extension.
- **Firefox**: controlled by `security.fileuri.strict_origin_policy` (set to `false` in `about:config` for trusted intranet pages).

As a fallback, the raw UNC path is displayed as copyable plain text beneath each link.

---

## AD Group Filtering

`ALLOWED_AD_GROUPS` gates access at the application level (all-or-nothing login check).

Already implemented:
- **`X-AD-Groups` forwarding**: every `/query` and `/chat` request to the RAG backend includes an `X-AD-Groups: group1,group2` header carrying the authenticated user's groups. The RAG backend can use this to apply document-level ACL filters.

Planned enhancements:
1. **Per-result visibility**: filter out individual results the user's groups cannot access (requires RAG backend support).
2. **Audit logging**: record who searched for what, for compliance.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Redirect loop on `/login` | Authelia unreachable | Check `OIDC_ISSUER_URL` and container status |
| `401` after callback | Client secret mismatch | Verify `OIDC_CLIENT_SECRET` matches Authelia config |
| `503` on search | RAG backend down | Check `RAG_SERVICE_URL` and rag-01 service |
| `file://` links don't open | Browser security policy | See UNC Path Links section above |
| Dark mode not persisting | localStorage blocked | Check browser privacy settings |
| Authelia container stuck | Redis not ready | Wait for `redis` healthcheck to pass |
