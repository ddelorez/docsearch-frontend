"""Async HTTP client for the RAG backend service.

Provides a thin async wrapper around ``httpx.AsyncClient`` with:
- Configurable timeouts (5 s connect, 30 s read).
- Simple exponential-backoff retry for transient 5xx / network errors.
- Structured error translation to user-friendly messages.
- Forwards the caller's AD groups to the backend so it can apply
  document-level access filters (future use; sent as X-AD-Groups header).
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any, Dict, List, Optional

import httpx

from app.config import get_settings

logger = logging.getLogger(__name__)

# ── Constants ────────────────────────────────────────────────────────────────

CONNECT_TIMEOUT = 5.0   # seconds
READ_TIMEOUT = 30.0     # seconds
MAX_RETRIES = 3
RETRY_BACKOFF_BASE = 0.5  # seconds – backoff = base * 2^attempt


# ── Payload / result types ───────────────────────────────────────────────────


class SearchResult:
    """Represents a single document result returned by the RAG backend."""

    __slots__ = ("title", "snippet", "source_path", "score", "date_modified", "extra")

    def __init__(
        self,
        title: str,
        snippet: str,
        source_path: str,
        score: float = 0.0,
        date_modified: Optional[str] = None,
        extra: Optional[Dict[str, Any]] = None,
    ) -> None:
        self.title = title
        self.snippet = snippet
        self.source_path = source_path
        self.score = score
        self.date_modified = date_modified
        self.extra = extra or {}

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "SearchResult":
        return cls(
            title=data.get("title", "Untitled"),
            snippet=data.get("snippet", data.get("excerpt", "")),
            source_path=data.get("source_path", data.get("path", "")),
            score=float(data.get("score", data.get("relevance_score", 0.0))),
            date_modified=data.get("date_modified"),
            extra={k: v for k, v in data.items() if k not in {"title", "snippet", "excerpt", "source_path", "path", "score", "relevance_score", "date_modified"}},
        )

    def to_dict(self) -> Dict[str, Any]:
        return {
            "title": self.title,
            "snippet": self.snippet,
            "source_path": self.source_path,
            "score": self.score,
            "date_modified": self.date_modified,
            **self.extra,
        }


class RAGResponse:
    """Aggregated response from the RAG service."""

    __slots__ = ("results", "total", "query", "error")

    def __init__(
        self,
        results: List[SearchResult],
        total: int,
        query: str,
        error: Optional[str] = None,
    ) -> None:
        self.results = results
        self.total = total
        self.query = query
        self.error = error

    @property
    def is_error(self) -> bool:
        return self.error is not None


class ChatMessage:
    """A single turn in a chat conversation."""

    __slots__ = ("role", "content")

    def __init__(self, role: str, content: str) -> None:
        self.role = role  # "user" | "assistant"
        self.content = content


class ChatResponse:
    """Response from the RAG chat endpoint."""

    __slots__ = ("answer", "sources", "error")

    def __init__(
        self,
        answer: str,
        sources: Optional[List[Dict[str, Any]]] = None,
        error: Optional[str] = None,
    ) -> None:
        self.answer = answer
        self.sources = sources or []
        self.error = error

    @property
    def is_error(self) -> bool:
        return self.error is not None


# ── Client ───────────────────────────────────────────────────────────────────


class RAGClient:
    """Async client for the RAG backend.

    Intended to be used as a singleton attached to the FastAPI ``app.state``:

    .. code-block:: python

        @asynccontextmanager
        async def lifespan(app: FastAPI):
            app.state.rag = RAGClient()
            await app.state.rag.__aenter__()
            yield
            await app.state.rag.__aexit__(None, None, None)
    """

    def __init__(self) -> None:
        settings = get_settings()
        timeout = httpx.Timeout(connect=CONNECT_TIMEOUT, read=READ_TIMEOUT, write=10.0, pool=5.0)
        self._client = httpx.AsyncClient(
            base_url=settings.rag_service_url,
            timeout=timeout,
            headers={"Content-Type": "application/json"},
        )

    async def __aenter__(self) -> "RAGClient":
        return self

    async def __aexit__(self, *_: Any) -> None:
        await self.close()

    async def close(self) -> None:
        await self._client.aclose()

    # ── Internal retry helper ─────────────────────────────────────────────

    async def _post_with_retry(
        self,
        path: str,
        payload: Dict[str, Any],
        ad_groups: Optional[List[str]] = None,
    ) -> httpx.Response:
        """POST *payload* to *path* with retry on transient errors."""
        headers: Dict[str, str] = {}
        if ad_groups:
            headers["X-AD-Groups"] = ",".join(ad_groups)

        last_exc: Optional[Exception] = None
        for attempt in range(MAX_RETRIES):
            try:
                response = await self._client.post(path, json=payload, headers=headers)
                if response.status_code < 500:
                    return response
                logger.warning(
                    "RAG backend returned %s on attempt %d/%d",
                    response.status_code,
                    attempt + 1,
                    MAX_RETRIES,
                )
                last_exc = httpx.HTTPStatusError(
                    f"Server error: {response.status_code}",
                    request=response.request,
                    response=response,
                )
            except (httpx.ConnectError, httpx.ReadTimeout, httpx.ConnectTimeout) as exc:
                logger.warning(
                    "Network error on attempt %d/%d: %s",
                    attempt + 1,
                    MAX_RETRIES,
                    exc,
                )
                last_exc = exc

            if attempt < MAX_RETRIES - 1:
                backoff = RETRY_BACKOFF_BASE * (2**attempt)
                await asyncio.sleep(backoff)

        raise last_exc or RuntimeError("Exhausted retries")

    # ── Public API ────────────────────────────────────────────────────────

    async def search(
        self,
        query: str,
        page: int = 1,
        page_size: int = 10,
        ad_groups: Optional[List[str]] = None,
    ) -> RAGResponse:
        """Forward a keyword/semantic search to the RAG backend.

        Parameters
        ----------
        query:
            The user's search query.
        page:
            1-based page number for pagination.
        page_size:
            Number of results per page.
        ad_groups:
            The caller's AD groups (sent as a header for backend filtering).

        Returns
        -------
        RAGResponse
            Parsed results, or an error response on failure.
        """
        payload: Dict[str, Any] = {
            "query": query,
            "page": page,
            "page_size": page_size,
        }
        try:
            response = await self._post_with_retry("/query", payload, ad_groups)
            response.raise_for_status()
            data = response.json()
            raw_results = data.get("results", data.get("documents", []))
            return RAGResponse(
                results=[SearchResult.from_dict(r) for r in raw_results],
                total=data.get("total", len(raw_results)),
                query=query,
            )
        except httpx.HTTPStatusError as exc:
            logger.error("RAG backend HTTP error: %s", exc)
            return RAGResponse(
                results=[],
                total=0,
                query=query,
                error=_http_error_message(exc.response.status_code),
            )
        except (httpx.ConnectError, httpx.ConnectTimeout):
            logger.error("Cannot connect to RAG backend at %s", get_settings().rag_service_url)
            return RAGResponse(results=[], total=0, query=query, error="Cannot reach the search service. Please try again later.")
        except httpx.ReadTimeout:
            return RAGResponse(results=[], total=0, query=query, error="The search service took too long to respond. Please try again.")
        except Exception as exc:  # noqa: BLE001
            logger.exception("Unexpected error querying RAG backend: %s", exc)
            return RAGResponse(results=[], total=0, query=query, error="An unexpected error occurred. Please try again.")

    async def chat(
        self,
        question: str,
        history: Optional[List[ChatMessage]] = None,
        ad_groups: Optional[List[str]] = None,
    ) -> ChatResponse:
        """Send an analytical question to the RAG chat endpoint.

        Parameters
        ----------
        question:
            The user's analytical question.
        history:
            Prior conversation turns (optional).
        ad_groups:
            The caller's AD groups.

        Returns
        -------
        ChatResponse
            The assistant's answer and source citations.
        """
        payload: Dict[str, Any] = {
            "question": question,
            "history": [{"role": m.role, "content": m.content} for m in (history or [])],
        }
        try:
            response = await self._post_with_retry("/chat", payload, ad_groups)
            response.raise_for_status()
            data = response.json()
            return ChatResponse(
                answer=data.get("answer", data.get("response", "")),
                sources=data.get("sources", []),
            )
        except httpx.HTTPStatusError as exc:
            logger.error("RAG chat HTTP error: %s", exc)
            return ChatResponse(answer="", error=_http_error_message(exc.response.status_code))
        except (httpx.ConnectError, httpx.ConnectTimeout):
            return ChatResponse(answer="", error="Cannot reach the search service. Please try again later.")
        except httpx.ReadTimeout:
            return ChatResponse(answer="", error="The service took too long to respond. Please try again.")
        except Exception as exc:  # noqa: BLE001
            logger.exception("Unexpected error in RAG chat: %s", exc)
            return ChatResponse(answer="", error="An unexpected error occurred. Please try again.")


# ── Helpers ──────────────────────────────────────────────────────────────────


def _http_error_message(status_code: int) -> str:
    messages = {
        400: "The query was invalid. Please check your input.",
        401: "The search service rejected the request (authentication error).",
        403: "You do not have permission to access this resource.",
        404: "The search endpoint was not found. Please contact support.",
        429: "Too many requests. Please wait a moment and try again.",
        503: "The search service is temporarily unavailable.",
    }
    return messages.get(status_code, f"The search service returned an error (HTTP {status_code}).")


def unc_to_file_uri(unc_path: str) -> str:
    """Convert a Windows UNC path to a ``file:///`` URI suitable for browser links.

    Parameters
    ----------
    unc_path:
        A path like ``\\\\server\\share\\folder\\doc.pdf`` or
        ``//server/share/folder/doc.pdf``.

    Returns
    -------
    str
        A ``file:////server/share/folder/doc.pdf`` URI.

    Notes
    -----
    Modern browsers may block ``file://`` links to network paths for security
    reasons.  Users on Windows with Internet Explorer / Edge Legacy can allow
    this via Intranet Zone settings.  For other browsers, administrators can
    configure the ``security.fileuri.strict_origin_policy`` flag (Firefox) or
    deploy a registry-based whitelist (Chrome).  As a fallback the raw UNC path
    is displayed as copy-able plain text.
    """
    # Normalise backslashes to forward slashes
    normalised = unc_path.replace("\\", "/")
    # Ensure leading // for UNC
    if not normalised.startswith("//"):
        normalised = "//" + normalised.lstrip("/")
    # file: URIs for UNC paths use four slashes: file:////server/share/...
    return "file:" + normalised
