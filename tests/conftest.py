"""Shared pytest fixtures for DocSearch frontend tests."""

from __future__ import annotations

import os
from collections.abc import Generator
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi.testclient import TestClient

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
    return test_client
