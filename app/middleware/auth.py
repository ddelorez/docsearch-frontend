"""OIDC authentication middleware and utilities.

Responsibilities
----------------
- Session management via Starlette's signed cookie session middleware.
- `@require_auth` decorator: redirects unauthenticated requests to /login.
- `extract_ad_groups`: parses the `groups` claim from an OIDC id_token or
  userinfo dict and stores them in the session for later access filtering.
- `check_group_membership`: enforces ALLOWED_AD_GROUPS when configured.
"""

from __future__ import annotations

import functools
import logging
from collections.abc import Callable
from typing import Any

from fastapi import Request
from fastapi.responses import RedirectResponse

logger = logging.getLogger(__name__)


# ── Session helpers ──────────────────────────────────────────────────────────


def get_current_user(request: Request) -> dict[str, Any] | None:
    """Return the user dict stored in the session, or None if not logged in."""
    return request.session.get("user")


def get_user_groups(request: Request) -> list[str]:
    """Return the list of AD groups from the current session."""
    return request.session.get("groups", [])


def extract_ad_groups(userinfo: dict[str, Any]) -> list[str]:
    """Extract AD groups from an OIDC userinfo or id_token payload.

    The OIDC provider typically maps group memberships to a ``groups`` claim.
    Falls back to an empty list if the claim is absent.

    Parameters
    ----------
    userinfo:
        The decoded token payload or userinfo endpoint response dict.

    Returns
    -------
    list[str]
        Group names, e.g. ``["/docsearch-users", "/docsearch-admins"]``.
    """
    raw: Any = userinfo.get("groups", [])
    if isinstance(raw, list):
        return [str(g) for g in raw]
    if isinstance(raw, str):
        # Some configurations encode groups as a space-separated string
        return [g for g in raw.split() if g]
    return []


def is_group_allowed(groups: list[str], allowed: list[str]) -> bool:
    """Return True if *any* of ``groups`` appears in ``allowed``.

    If ``allowed`` is empty, all authenticated users are permitted.
    Group names are compared case-insensitively, and leading slashes
    (OIDC path format) are stripped before comparison.

    Parameters
    ----------
    groups:
        Groups the user belongs to.
    allowed:
        Configured ALLOWED_AD_GROUPS list.
    """
    if not allowed:
        return True

    def normalise(g: str) -> str:
        return g.lstrip("/").lower()

    normalised_allowed = {normalise(g) for g in allowed}
    return any(normalise(g) in normalised_allowed for g in groups)


# ── Route decorator ──────────────────────────────────────────────────────────


def require_auth(func: Callable) -> Callable:
    """Decorator that protects a FastAPI route handler.

    Redirects unauthenticated requests to ``/login``.
    If ``ALLOWED_AD_GROUPS`` is configured, also enforces group membership
    and returns a 403 error page if the user is not in an allowed group.

    Usage
    -----
    ::

        @app.get("/protected")
        @require_auth
        async def protected_route(request: Request):
            ...
    """
    from app.config import get_settings  # local import to avoid circular deps

    @functools.wraps(func)
    async def wrapper(request: Request, *args: Any, **kwargs: Any) -> Any:
        user = get_current_user(request)
        if user is None:
            logger.debug("Unauthenticated request to %s – redirecting to /login", request.url.path)
            # Preserve original destination so we can redirect back after login
            request.session["next"] = str(request.url)
            return RedirectResponse(url="/login", status_code=302)

        settings = get_settings()
        allowed = settings.allowed_groups_list
        if allowed:
            groups = get_user_groups(request)
            if not is_group_allowed(groups, allowed):
                logger.warning(
                    "User %s has groups %s but none match ALLOWED_AD_GROUPS %s",
                    user.get("sub"),
                    groups,
                    allowed,
                )
                import os as _os  # noqa: PLC0415
                from datetime import datetime  # noqa: PLC0415

                from fastapi.templating import Jinja2Templates  # noqa: PLC0415

                templates_dir = _os.path.join(
                    _os.path.dirname(_os.path.dirname(__file__)), "templates"
                )
                templates = Jinja2Templates(directory=templates_dir)
                return templates.TemplateResponse(
                    request,
                    "error.html",
                    {
                        "status_code": 403,
                        "title": "Access Denied",
                        "message": "Your account does not belong to a group authorised to use DocSearch.",
                        "current_year": datetime.now().year,
                    },
                    status_code=403,
                )

        return await func(request, *args, **kwargs)

    return wrapper
