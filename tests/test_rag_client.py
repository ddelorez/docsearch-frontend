"""Tests for app/services/rag_client.py."""

from __future__ import annotations

from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest

from app.services.rag_client import (
    RAGClient,
    SearchResult,
    unc_to_file_uri,
)


# ── SearchResult ──────────────────────────────────────────────────────────────


class TestSearchResult:
    """SearchResult.from_dict handles various backend response shapes."""

    def test_from_dict_standard_keys(self) -> None:
        data = {
            "title": "Policy Doc",
            "snippet": "This is the excerpt",
            "source_path": r"\\server\share\policy.pdf",
            "score": 0.92,
            "date_modified": "2024-01-15",
        }
        result = SearchResult.from_dict(data)
        assert result.title == "Policy Doc"
        assert result.snippet == "This is the excerpt"
        assert result.source_path == r"\\server\share\policy.pdf"
        assert result.score == pytest.approx(0.92)
        assert result.date_modified == "2024-01-15"

    def test_from_dict_alternate_keys(self) -> None:
        data = {
            "title": "Report",
            "excerpt": "Some text",     # alternate snippet key
            "path": r"\\srv\docs\r.docx",  # alternate path key
            "relevance_score": 0.75,   # alternate score key
        }
        result = SearchResult.from_dict(data)
        assert result.snippet == "Some text"
        assert result.source_path == r"\\srv\docs\r.docx"
        assert result.score == pytest.approx(0.75)

    def test_from_dict_defaults_when_missing(self) -> None:
        result = SearchResult.from_dict({})
        assert result.title == "Untitled"
        assert result.snippet == ""
        assert result.source_path == ""
        assert result.score == pytest.approx(0.0)
        assert result.date_modified is None

    def test_to_dict_round_trips(self) -> None:
        result = SearchResult(
            title="T",
            snippet="S",
            source_path=r"\\x\y\z.pdf",
            score=0.5,
            date_modified="2024-06-01",
        )
        d = result.to_dict()
        assert d["title"] == "T"
        assert d["source_path"] == r"\\x\y\z.pdf"


# ── UNC path helper ───────────────────────────────────────────────────────────


class TestUncToFileUri:
    """unc_to_file_uri converts UNC paths to file:// URIs."""

    def test_double_backslash_unc(self) -> None:
        uri = unc_to_file_uri(r"\\server\share\folder\doc.pdf")
        assert uri == "file:////server/share/folder/doc.pdf"

    def test_forward_slash_unc(self) -> None:
        uri = unc_to_file_uri("//server/share/folder/doc.pdf")
        assert uri == "file:////server/share/folder/doc.pdf"

    def test_path_with_spaces(self) -> None:
        uri = unc_to_file_uri(r"\\server\my share\my doc.pdf")
        assert uri.startswith("file://")
        assert "my share" in uri

    def test_returns_file_scheme(self) -> None:
        uri = unc_to_file_uri(r"\\s\d\f.txt")
        assert uri.startswith("file:")


# ── RAGClient.search ──────────────────────────────────────────────────────────


class TestRAGClientSearch:
    """RAGClient.search handles success and error cases."""

    @pytest.mark.asyncio
    async def test_search_returns_results_on_success(self) -> None:
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            "results": [
                {"title": "Doc A", "snippet": "Relevant text", "source_path": r"\\srv\d\a.pdf", "score": 0.9},
            ],
            "total": 1,
        }
        mock_response.raise_for_status = MagicMock()

        client = RAGClient.__new__(RAGClient)
        client._client = MagicMock()
        client._client.post = AsyncMock(return_value=mock_response)

        response = await client.search("test query")
        assert response.error is None
        assert response.total == 1
        assert response.results[0].title == "Doc A"

    @pytest.mark.asyncio
    async def test_search_returns_error_on_connect_error(self) -> None:
        client = RAGClient.__new__(RAGClient)
        client._client = MagicMock()
        client._client.post = AsyncMock(side_effect=httpx.ConnectError("refused"))

        response = await client.search("test query")
        assert response.is_error is True
        assert "reach" in response.error.lower()  # type: ignore[union-attr]

    @pytest.mark.asyncio
    async def test_search_returns_error_on_timeout(self) -> None:
        client = RAGClient.__new__(RAGClient)
        client._client = MagicMock()
        client._client.post = AsyncMock(side_effect=httpx.ReadTimeout("timeout"))

        response = await client.search("test query")
        assert response.is_error is True
        assert "long" in response.error.lower()  # type: ignore[union-attr]

    @pytest.mark.asyncio
    async def test_search_returns_friendly_message_on_500(self) -> None:
        mock_response = MagicMock()
        mock_response.status_code = 503
        mock_response.raise_for_status.side_effect = httpx.HTTPStatusError(
            "503",
            request=MagicMock(),
            response=mock_response,
        )

        client = RAGClient.__new__(RAGClient)
        client._client = MagicMock()
        client._client.post = AsyncMock(return_value=mock_response)

        response = await client.search("test query")
        assert response.is_error is True
        assert "503" in response.error or "unavailable" in response.error.lower()  # type: ignore[union-attr]

    @pytest.mark.asyncio
    async def test_search_retries_on_server_error(self) -> None:
        """On 5xx responses, the client retries up to MAX_RETRIES times."""
        from app.services.rag_client import MAX_RETRIES

        bad_response = MagicMock()
        bad_response.status_code = 503

        client = RAGClient.__new__(RAGClient)
        client._client = MagicMock()
        client._client.post = AsyncMock(return_value=bad_response)

        with patch("asyncio.sleep", new_callable=AsyncMock):
            response = await client.search("retry test")

        # All retries exhausted → error
        assert response.is_error is True
        assert client._client.post.await_count == MAX_RETRIES


# ── RAGClient.chat ────────────────────────────────────────────────────────────


class TestRAGClientChat:
    """RAGClient.chat handles success and error cases."""

    @pytest.mark.asyncio
    async def test_chat_returns_answer_on_success(self) -> None:
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            "answer": "The quarterly report shows…",
            "sources": [{"title": "Q3 Report", "source_path": r"\\srv\reports\q3.pdf"}],
        }
        mock_response.raise_for_status = MagicMock()

        client = RAGClient.__new__(RAGClient)
        client._client = MagicMock()
        client._client.post = AsyncMock(return_value=mock_response)

        response = await client.chat("Summarise the Q3 report")
        assert response.error is None
        assert "quarterly" in response.answer
        assert len(response.sources) == 1

    @pytest.mark.asyncio
    async def test_chat_returns_error_on_connect_error(self) -> None:
        client = RAGClient.__new__(RAGClient)
        client._client = MagicMock()
        client._client.post = AsyncMock(side_effect=httpx.ConnectError("refused"))

        response = await client.chat("test question")
        assert response.is_error is True
