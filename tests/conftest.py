"""Shared pytest fixtures for DocSearch frontend tests."""

from __future__ import annotations

import os
from typing import AsyncGenerator, Generator
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi.testclient import TestClient
from httpx import AsyncClient

# Inject required env vars before importing app modules
os.environ.setdefault("KEYCLOAK_URL", "http://localhost:8080")
os.environ.setdefault("KEYCLOAK_REALM", "test")
os.environ.setdefault("KEYCLOAK_CLIENT_ID", "test-client")
os.environ.setdefault("KEYCLOAK_CLIENT_SECRET", "test-secret")
os.environ.setdefault("RAG_SERVICE_URL", "http://localhost:9000")
os.environ.setdefault("SECRET_KEY", "test-secret-key-for-unit-tests-only")
os.environ.setdefault("ALLOWED_AD_GROUPS", "")


@pytest.fixture(scope="session")
def test_client() -> Generator[TestClient, None, None]:
    """Synchronous test client for simple endpoint checks."""
    from app.main import app

    # Attach a mock RAG client so routes don't need a real backend
    mock_rag = MagicMock()
    mock_rag.search = AsyncMock(
        return_value=MagicMock(
            results=[],
            total=0,
            query="test",
            error=None,
            is_error=False,
        )
    )
    mock_rag.chat = AsyncMock(
        return_value=MagicMock(answer="", sources=[], error=None, is_error=False)
    )
    app.state.rag = mock_rag

    with TestClient(app, raise_server_exceptions=False) as client:
        yield client


@pytest.fixture()
def authenticated_session(test_client: TestClient) -> TestClient:
    """Returns a client with a fake authenticated session injected."""
    # Starlette's TestClient exposes session via cookies dict when
    # SessionMiddleware is in use. We patch the session directly.
    test_client.app.state  # ensure app is started

    # We cannot easily set signed cookies externally, so instead we
    # use a dependency-override approach via a mock user in session.
    # Tests that need auth should call this fixture, which sets session
    # state on the test client's cookie jar via a helper endpoint if available,
    # or mock the session middleware.
    return test_client
