"""FastAPI application entry point for DocSearch Frontend.

Routes
------
GET  /              → Search landing page (protected)
POST /query         → HTMX-powered search proxy (protected)
GET  /results       → Results partial (HTMX, protected)
GET  /chat          → Chat mode page (protected)
POST /chat          → Chat query proxy (HTMX, protected)
GET  /login         → Redirect to OIDC authorisation endpoint
GET  /auth/callback → OIDC callback handler
GET  /logout        → Clears session + redirects to Authelia logout
GET  /health        → Public health check
"""

from __future__ import annotations

import json
import logging
import math
import os
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Any

from authlib.integrations.starlette_client import OAuth
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
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
    client_kwargs: dict[str, str] = {
        "scope": "openid email profile groups",
        "response_type": "code",
    }

    # If a public Authelia URL is configured, override the authorization
    # endpoint so the browser is redirected to the externally reachable URL
    # instead of the internal Docker hostname.
    if settings.authelia_public_url:
        client_kwargs["authorize_url"] = (
            f"{settings.authelia_public_url}/api/oidc/authorization"
        )

    oauth.register(
        name="authelia",
        client_id=settings.oidc_client_id,
        client_secret=settings.oidc_client_secret,
        server_metadata_url=settings.oidc_discovery_url,
        client_kwargs=client_kwargs,
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
        docs_url=None,  # disable Swagger UI in production
        redoc_url=None,
        lifespan=lifespan,
    )

    # Session middleware (must be added before any route registration)
    application.add_middleware(
        SessionMiddleware,
        secret_key=settings.secret_key,
        session_cookie="docsearch_session",
        max_age=28800,  # 8 hours
        https_only=True,
        same_site="lax",
    )

    return application


app = create_app()

# ── Static files & Templates ─────────────────────────────────────────────────

_base_dir = os.path.dirname(__file__)

app.mount(
    "/static",
    StaticFiles(directory=os.path.join(_base_dir, "static")),
    name="static",
)

templates = Jinja2Templates(directory=os.path.join(_base_dir, "templates"))

# Register custom Jinja2 filter for UNC → file:// conversion
templates.env.filters["unc_to_file_uri"] = unc_to_file_uri


# ── Helper ───────────────────────────────────────────────────────────────────


def _base_context(request: Request) -> dict[str, Any]:
    """Return template context variables common to all protected pages."""
    user = get_current_user(request)
    groups = get_user_groups(request)
    return {
        "request": request,
        "user": user,
        "groups": groups,
        "current_year": datetime.now().year,
    }


# ── Public routes ─────────────────────────────────────────────────────────────


@app.get("/health")
async def health(request: Request) -> JSONResponse:
    """Liveness probe – always returns 200 OK."""
    return JSONResponse({"status": "ok"})


@app.get("/api/state")
async def api_state(request: Request) -> JSONResponse:
    """Return current authentication state. Public endpoint – returns empty user if not logged in."""
    user = request.session.get("user")
    groups = request.session.get("groups", [])
    if user:
        return JSONResponse({
            "authenticated": True,
            "user": user,
            "groups": groups,
        })
    return JSONResponse({
        "authenticated": False,
        "user": None,
        "groups": [],
    })


# ── Auth routes ───────────────────────────────────────────────────────────────


@app.get("/login")
async def login(request: Request) -> RedirectResponse:
    """Redirect to Authelia's authorisation endpoint."""
    # Build the redirect URI — always use HTTPS when behind the proxy
    redirect_uri = request.url_for("auth_callback")
    if request.headers.get("x-forwarded-proto") == "https":
        redirect_uri = redirect_uri.replace(scheme="https")
    # If a public Authelia URL is configured, ensure the redirect URI
    # uses the same public hostname for consistency
    settings = get_settings()
    if settings.authelia_public_url and redirect_uri.scheme != "https":
        # Behind HTTPS proxy: force https scheme
        redirect_uri = redirect_uri.replace(scheme="https")
    return await oauth.authelia.authorize_redirect(request, redirect_uri)


@app.get("/auth/callback")
async def auth_callback(request: Request) -> Response:
    """Handle the OIDC authorisation code callback from Authelia."""
    try:
        token = await oauth.authelia.authorize_access_token(request)
    except Exception as exc:
        logger.error("OIDC callback error: %s", exc)
        return templates.TemplateResponse(
            request,
            "error.html",
            {
                "status_code": 401,
                "title": "Authentication Failed",
                "message": "Could not complete sign-in. Please try again.",
                "current_year": datetime.now().year,
            },
            status_code=401,
        )

    userinfo: dict[str, Any] = token.get("userinfo") or {}
    if not userinfo:
        # Fallback: parse id_token claims
        id_token = token.get("id_token")
        if id_token:
            userinfo = dict(oauth.authelia.parse_id_token(token, nonce=None) or {})

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
    """Clear the local session and redirect to Authelia's end-session endpoint."""
    settings = get_settings()
    request.session.clear()

    # Build Authelia logout URL — use public URLs so the browser can reach them
    authelia_base = settings.authelia_public_url or settings.oidc_issuer_url
    index_url = str(request.url_for("index"))
    if request.headers.get("x-forwarded-proto") == "https":
        index_url = index_url.replace("http://", "https://")
    authelia_logout = f"{authelia_base}/logout?redirect_uri={index_url}"
    return RedirectResponse(url=authelia_logout, status_code=302)


# ── Protected application routes ──────────────────────────────────────────────


@app.get("/", response_class=HTMLResponse)
@require_auth
async def index(request: Request) -> Any:
    """Search landing page."""
    ctx = _base_context(request)
    return templates.TemplateResponse(request, "index.html", ctx)


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
    return templates.TemplateResponse(request, "results.html", ctx)


@app.get("/chat", response_class=HTMLResponse)
@require_auth
async def chat_page(request: Request) -> Any:
    """Chat mode page (initial load)."""
    ctx = _base_context(request)
    ctx["messages"] = []
    return templates.TemplateResponse(request, "chat.html", ctx)


@app.post("/chat", response_class=HTMLResponse)
@require_auth
async def chat_query(
    request: Request,
    question: str = Form(...),
    history: str | None = Form(None),
) -> Any:
    """HTMX chat handler – sends question to RAG backend and returns answer partial."""
    rag: RAGClient = request.app.state.rag
    groups = get_user_groups(request)

    parsed_history: list[ChatMessage] = []
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
    return templates.TemplateResponse(request, "chat.html", ctx)


# ── Error handlers ────────────────────────────────────────────────────────────


@app.exception_handler(404)
async def not_found_handler(request: Request, exc: Any) -> Any:
    return templates.TemplateResponse(
        request,
        "error.html",
        {
            "status_code": 404,
            "title": "Page Not Found",
            "message": "The page you requested could not be found.",
            "current_year": datetime.now().year,
        },
        status_code=404,
    )


@app.exception_handler(500)
async def server_error_handler(request: Request, exc: Any) -> Any:
    logger.exception("Unhandled server error: %s", exc)
    return templates.TemplateResponse(
        request,
        "error.html",
        {
            "status_code": 500,
            "title": "Internal Server Error",
            "message": "Something went wrong on our end. Please try again later.",
            "current_year": datetime.now().year,
        },
        status_code=500,
    )
