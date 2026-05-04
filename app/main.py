"""FastAPI application entry point for DocSearch Frontend.

Routes
------
GET  /              → Search landing page (protected)
POST /query         → HTMX-powered search proxy (protected)
GET  /results       → Results partial (HTMX, protected)
GET  /chat          → Chat mode page (protected)
POST /chat          → Chat query proxy (HTMX, protected)
GET  /login         → Redirect to Keycloak authorisation endpoint
GET  /auth/callback → OIDC callback handler
GET  /logout        → Clears session + redirects to Keycloak logout
GET  /health        → Public health check
"""

from __future__ import annotations

import logging
import math
from contextlib import asynccontextmanager
from typing import Any, AsyncGenerator, Dict, List, Optional

from authlib.integrations.starlette_client import OAuth
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware

from app.config import get_settings
from app.middleware.auth import (
    extract_ad_groups,
    get_current_user,
    get_user_groups,
    require_auth,
)
from app.services.rag_client import ChatMessage, RAGClient, unc_to_file_uri

logger = logging.getLogger(__name__)

# ── OIDC OAuth setup ─────────────────────────────────────────────────────────

oauth = OAuth()


def _register_oidc(settings: Any) -> None:
    oauth.register(
        name="keycloak",
        client_id=settings.keycloak_client_id,
        client_secret=settings.keycloak_client_secret,
        server_metadata_url=settings.oidc_discovery_url,
        client_kwargs={
            "scope": "openid email profile groups",
            "response_type": "code",
        },
    )


# ── Lifespan ─────────────────────────────────────────────────────────────────


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    settings = get_settings()
    _register_oidc(settings)
    app.state.rag = RAGClient()
    logger.info("RAG client initialised, base URL: %s", settings.rag_service_url)
    yield
    await app.state.rag.close()
    logger.info("RAG client closed.")


# ── Application factory ───────────────────────────────────────────────────────

def create_app() -> FastAPI:
    settings = get_settings()

    application = FastAPI(
        title="DocSearch",
        description="Internal document search powered by RAG",
        version="1.0.0",
        docs_url=None,   # disable Swagger UI in production
        redoc_url=None,
        lifespan=lifespan,
    )

    # Session middleware (must be added before any route registration)
    application.add_middleware(
        SessionMiddleware,
        secret_key=settings.secret_key,
        session_cookie="docsearch_session",
        max_age=28800,        # 8 hours
        https_only=False,     # set to True in production behind HTTPS
        same_site="lax",
    )

    return application


app = create_app()

# ── Static files & Templates ─────────────────────────────────────────────────

import os as _os  # noqa: E402

_base_dir = _os.path.dirname(__file__)

app.mount(
    "/static",
    StaticFiles(directory=_os.path.join(_base_dir, "static")),
    name="static",
)

templates = Jinja2Templates(directory=_os.path.join(_base_dir, "templates"))

# Register custom Jinja2 filter for UNC → file:// conversion
templates.env.filters["unc_to_file_uri"] = unc_to_file_uri


# ── Helper ───────────────────────────────────────────────────────────────────


def _base_context(request: Request) -> Dict[str, Any]:
    """Return template context variables common to all protected pages."""
    user = get_current_user(request)
    groups = get_user_groups(request)
    return {
        "request": request,
        "user": user,
        "groups": groups,
    }


# ── Public routes ─────────────────────────────────────────────────────────────


@app.get("/health", response_class=HTMLResponse)
async def health(request: Request) -> Dict[str, str]:
    """Liveness probe – always returns 200 OK."""
    return {"status": "ok"}  # type: ignore[return-value]


# ── Auth routes ───────────────────────────────────────────────────────────────


@app.get("/login")
async def login(request: Request) -> RedirectResponse:
    """Redirect to Keycloak's authorisation endpoint."""
    redirect_uri = request.url_for("auth_callback")
    return await oauth.keycloak.authorize_redirect(request, redirect_uri)  # type: ignore[union-attr]


@app.get("/auth/callback")
async def auth_callback(request: Request) -> RedirectResponse:
    """Handle the OIDC authorisation code callback from Keycloak."""
    try:
        token = await oauth.keycloak.authorize_access_token(request)  # type: ignore[union-attr]
    except Exception as exc:
        logger.error("OIDC callback error: %s", exc)
        return templates.TemplateResponse(
            "error.html",
            {
                "request": request,
                "status_code": 401,
                "title": "Authentication Failed",
                "message": "Could not complete sign-in. Please try again.",
            },
            status_code=401,
        )  # type: ignore[return-value]

    userinfo: Dict[str, Any] = token.get("userinfo") or {}
    if not userinfo:
        # Fallback: parse id_token claims
        id_token = token.get("id_token")
        if id_token:
            userinfo = dict(oauth.keycloak.parse_id_token(token, nonce=None) or {})  # type: ignore[union-attr]

    groups = extract_ad_groups(userinfo)

    request.session["user"] = {
        "sub": userinfo.get("sub", ""),
        "name": userinfo.get("name", userinfo.get("preferred_username", "User")),
        "email": userinfo.get("email", ""),
        "preferred_username": userinfo.get("preferred_username", ""),
    }
    request.session["groups"] = groups
    request.session["access_token"] = token.get("access_token", "")

    next_url: str = request.session.pop("next", "/")
    logger.info("User %s authenticated, groups: %s", userinfo.get("sub"), groups)
    return RedirectResponse(url=next_url, status_code=302)


@app.get("/logout")
async def logout(request: Request) -> RedirectResponse:
    """Clear the local session and redirect to Keycloak's end-session endpoint."""
    settings = get_settings()
    request.session.clear()

    # Build Keycloak logout URL
    keycloak_logout = (
        f"{settings.keycloak_url}/realms/{settings.keycloak_realm}"
        f"/protocol/openid-connect/logout"
        f"?redirect_uri={request.url_for('index')}"
    )
    return RedirectResponse(url=keycloak_logout, status_code=302)


# ── Protected application routes ──────────────────────────────────────────────


@app.get("/", response_class=HTMLResponse)
@require_auth
async def index(request: Request) -> Any:
    """Search landing page."""
    ctx = _base_context(request)
    return templates.TemplateResponse("index.html", ctx)


@app.post("/query", response_class=HTMLResponse)
@require_auth
async def query(
    request: Request,
    q: str = Form(...),
    page: int = Form(1),
    page_size: int = Form(10),
) -> Any:
    """HTMX search handler – proxies to RAG backend and returns results partial."""
    rag: RAGClient = request.app.state.rag
    groups = get_user_groups(request)

    result = await rag.search(query=q, page=page, page_size=page_size, ad_groups=groups)

    total_pages = max(1, math.ceil(result.total / page_size)) if result.total else 1

    ctx = _base_context(request)
    ctx.update(
        {
            "query": q,
            "results": [r.to_dict() for r in result.results],
            "total": result.total,
            "page": page,
            "page_size": page_size,
            "total_pages": total_pages,
            "error": result.error,
        }
    )
    return templates.TemplateResponse("results.html", ctx)


@app.get("/chat", response_class=HTMLResponse)
@require_auth
async def chat_page(request: Request) -> Any:
    """Chat mode page (initial load)."""
    ctx = _base_context(request)
    ctx["messages"] = []
    return templates.TemplateResponse("chat.html", ctx)


@app.post("/chat", response_class=HTMLResponse)
@require_auth
async def chat_query(
    request: Request,
    question: str = Form(...),
    history: Optional[str] = Form(None),
) -> Any:
    """HTMX chat handler – sends question to RAG backend and returns answer partial."""
    import json

    rag: RAGClient = request.app.state.rag
    groups = get_user_groups(request)

    parsed_history: List[ChatMessage] = []
    if history:
        try:
            raw = json.loads(history)
            parsed_history = [ChatMessage(role=m["role"], content=m["content"]) for m in raw]
        except (json.JSONDecodeError, KeyError):
            parsed_history = []

    response = await rag.chat(question=question, history=parsed_history, ad_groups=groups)

    ctx = _base_context(request)
    ctx.update(
        {
            "question": question,
            "answer": response.answer,
            "sources": response.sources,
            "error": response.error,
            "history": parsed_history,
        }
    )
    return templates.TemplateResponse("chat.html", ctx)


# ── Error handlers ────────────────────────────────────────────────────────────


@app.exception_handler(404)
async def not_found_handler(request: Request, exc: Any) -> Any:
    return templates.TemplateResponse(
        "error.html",
        {
            "request": request,
            "status_code": 404,
            "title": "Page Not Found",
            "message": "The page you requested could not be found.",
        },
        status_code=404,
    )


@app.exception_handler(500)
async def server_error_handler(request: Request, exc: Any) -> Any:
    logger.exception("Unhandled server error: %s", exc)
    return templates.TemplateResponse(
        "error.html",
        {
            "request": request,
            "status_code": 500,
            "title": "Internal Server Error",
            "message": "Something went wrong on our end. Please try again later.",
        },
        status_code=500,
    )
