"""Application configuration via Pydantic Settings."""

from __future__ import annotations

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """All configuration is read from environment variables or a `.env` file."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # ── Keycloak / OIDC ──────────────────────────────────────────────────────
    keycloak_url: str
    keycloak_realm: str
    keycloak_client_id: str
    keycloak_client_secret: str

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
    def oidc_issuer(self) -> str:
        """Full issuer URL for the configured Keycloak realm."""
        return f"{self.keycloak_url}/realms/{self.keycloak_realm}"

    @property
    def oidc_discovery_url(self) -> str:
        """OpenID Connect discovery document URL."""
        return f"{self.oidc_issuer}/.well-known/openid-configuration"

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
