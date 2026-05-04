# DocSearch Frontend

Internal document search platform frontend — FastAPI, HTMX, Tailwind CSS, Keycloak OIDC.

---

## Architecture

```
                          ┌───────────────────────────────────────────────┐
                          │               Docker network (internal)        │
                          │                                                │
  Browser ──HTTPS──► Nginx ──► FastAPI (uvicorn) ──► RAG backend (rag-01) │
                          │          │                                     │
                          │          └──► Keycloak ──► PostgreSQL          │
                          └───────────────────────────────────────────────┘
```

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Frontend  | FastAPI + Jinja2 + HTMX | Server-rendered UI, OIDC auth |
| Styling   | Tailwind CSS (CDN) | Utility-first CSS, dark mode |
| Auth      | Keycloak + Authlib | OIDC / OpenID Connect |
| Proxy     | Nginx | TLS termination, static files |
| Search    | RAG backend (external) | Document retrieval & chat |

---

## Prerequisites

- Docker ≥ 24 and Docker Compose v2
- Python 3.12 (for local development)
- A Keycloak instance (or use the bundled Docker service)
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
# Edit .env with your Keycloak URL, realm, client credentials, and SECRET_KEY

# 4. Run the development server
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Open http://localhost:8000 – you will be redirected to Keycloak to sign in.

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

### Start all services

```bash
cp .env.example .env
# Edit .env

docker compose up -d
```

Services start order: PostgreSQL → Keycloak → FastAPI → Nginx.

Access the app at https://localhost (port 443).

### Stop services

```bash
docker compose down
# To also remove volumes (database data):
docker compose down -v
```

---

## Keycloak Configuration

After the Keycloak container starts (default: http://localhost – proxied at /auth/):

1. **Log in** to the Keycloak admin console at `http://localhost:8080` with credentials from `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD`.

2. **Create a realm** (or import an existing one):
   - Realm name should match `KEYCLOAK_REALM` in your `.env`.

3. **Create a client**:
   - Client ID: value of `KEYCLOAK_CLIENT_ID`
   - Client authentication: **ON** (confidential)
   - Valid redirect URIs: `https://<your-host>/auth/callback`
   - Copy the client secret to `KEYCLOAK_CLIENT_SECRET`

4. **Add AD group mapper** (for group-based access control):
   - In the client → *Client scopes* → add a mapper of type **Group Membership**
   - Token claim name: `groups`
   - Full group path: enabled

5. **Create groups** matching your `ALLOWED_AD_GROUPS` config and assign users.

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
| `KEYCLOAK_URL` | Yes | — | Base URL of Keycloak (no trailing slash) |
| `KEYCLOAK_REALM` | Yes | — | Keycloak realm name |
| `KEYCLOAK_CLIENT_ID` | Yes | — | OIDC client ID |
| `KEYCLOAK_CLIENT_SECRET` | Yes | — | OIDC client secret |
| `RAG_SERVICE_URL` | No | `http://rag-01:8000` | RAG backend base URL |
| `SECRET_KEY` | Yes | — | Session signing key (random hex, ≥ 32 bytes) |
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
| Redirect loop on `/login` | Keycloak unreachable | Check `KEYCLOAK_URL` and container status |
| `401` after callback | Client secret mismatch | Verify `KEYCLOAK_CLIENT_SECRET` in Keycloak admin |
| `503` on search | RAG backend down | Check `RAG_SERVICE_URL` and rag-01 service |
| `file://` links don't open | Browser security policy | See UNC Path Links section above |
| Dark mode not persisting | localStorage blocked | Check browser privacy settings |
| Keycloak container stuck | DB not ready | Wait for `keycloak-db` healthcheck to pass |
