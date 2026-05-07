"""Application configuration via Pydantic Settings."""

from __future__ import annotations

import warnings
from functools import lru_cache
from typing import Any

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """All configuration is read from environment variables or a `.env` file."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # ── OIDC / Authelia ──────────────────────────────────────────────────────
    # Public-facing issuer URL (HTTPS). Used for browser-facing OIDC redirects
    # and as the base for token/userinfo endpoints.
    # e.g. "https://sgisearch.sgi01.local/authelia"
    oidc_issuer_url: str

    oidc_client_id: str
    oidc_client_secret: str

    # Whether to verify SSL certificates when contacting the OIDC provider.
    # Set to false when using self-signed certificates in internal environments.
    oidc_verify_ssl: bool = True

    # Internal Docker-network URL for Authelia (HTTP, no TLS). Used for
    # server-to-server OIDC discovery metadata fetches. When set, this
    # bypasses SSL verification issues with self-signed certificates.
    # e.g. "http://authelia:9091"
    authelia_internal_url: str = ""

    # Public-facing URL for Authelia (used for browser redirects to the
    # OIDC authorization endpoint). Must be reachable from the user's browser,
    # e.g. "https://sgisearch.sgi01.local/authelia".
    # If left empty, OIDC login redirects will point to the internal
    # Docker hostname and users will NOT see the login page.
    authelia_public_url: str = ""

    def model_post_init(self, __context: Any) -> None:
        """Validate critical production settings."""
        if not self.authelia_public_url:
            warnings.warn(
                "AUTHELIA_PUBLIC_URL is not set. OIDC login redirects will "
                "use the internal Docker hostname and will fail in production. "
                "Set AUTHELIA_PUBLIC_URL=https://sgisearch.sgi01.local/authelia",
                RuntimeWarning,
                stacklevel=2,
            )
        if not self.authelia_internal_url:
            warnings.warn(
                "AUTHELIA_INTERNAL_URL is not set. Server-to-server OIDC "
                "discovery will use OIDC_ISSUER_URL (%s). If Authelia uses a "
                "self-signed certificate, set AUTHELIA_INTERNAL_URL to the "
                "internal Docker HTTP URL (e.g. http://authelia:9091).",
                RuntimeWarning,
                stacklevel=2,
            )

    # ── Backend RAG service ──────────────────────────────────────────────────
    rag_service_url: str = "http://rag-01:8000"

    # ── Application ──────────────────────────────────────────────────────────
    secret_key: str
    # Comma-separated list of AD groups that are allowed access.
    # Empty string means all authenticated users are allowed.
    allowed_ad_groups: str = ""

    # ── Server ───────────────────────────────────────────────────────────────
    host: str = "0.0.0.0"
    port: int = 8000

    # ── Derived / computed properties ────────────────────────────────────────

    @property
    def oidc_discovery_url(self) -> str:
        """OpenID Connect discovery document URL.

        Uses the internal Docker URL when available to avoid SSL
        certificate verification issues with self-signed certificates.
        Falls back to the public issuer URL for external deployments.
        """
        base = self.authelia_internal_url or self.oidc_issuer_url
        return f"{base}/.well-known/openid-configuration"

    @property
    def allowed_groups_list(self) -> list[str]:
        """Return allowed AD groups as a list, ignoring whitespace."""
        if not self.allowed_ad_groups:
            return []
        return [g.strip() for g in self.allowed_ad_groups.split(",") if g.strip()]


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Return a cached Settings instance (singleton)."""
    return Settings()  # type: ignore[call-arg]
