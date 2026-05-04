"""Tests for app/middleware/auth.py."""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest

from app.middleware.auth import (
    extract_ad_groups,
    get_current_user,
    get_user_groups,
    is_group_allowed,
    require_auth,
)


class TestExtractAdGroups:
    """extract_ad_groups correctly parses the `groups` claim."""

    def test_returns_list_when_groups_is_list(self) -> None:
        userinfo = {"groups": ["/docsearch-users", "/docsearch-admins"]}
        result = extract_ad_groups(userinfo)
        assert result == ["/docsearch-users", "/docsearch-admins"]

    def test_returns_list_when_groups_is_space_separated_string(self) -> None:
        userinfo = {"groups": "/docsearch-users /docsearch-admins"}
        result = extract_ad_groups(userinfo)
        assert result == ["/docsearch-users", "/docsearch-admins"]

    def test_returns_empty_when_no_groups_claim(self) -> None:
        assert extract_ad_groups({}) == []

    def test_returns_empty_when_groups_is_none(self) -> None:
        assert extract_ad_groups({"groups": None}) == []

    def test_returns_empty_when_groups_is_empty_list(self) -> None:
        assert extract_ad_groups({"groups": []}) == []

    def test_non_string_group_entries_are_cast_to_str(self) -> None:
        userinfo = {"groups": [1, 2, "admins"]}
        result = extract_ad_groups(userinfo)
        assert result == ["1", "2", "admins"]


class TestIsGroupAllowed:
    """is_group_allowed enforces group membership correctly."""

    def test_allows_all_when_allowed_list_empty(self) -> None:
        assert is_group_allowed(groups=[], allowed=[]) is True
        assert is_group_allowed(groups=["any-group"], allowed=[]) is True

    def test_allows_when_user_has_matching_group(self) -> None:
        assert is_group_allowed(
            groups=["/docsearch-users"],
            allowed=["docsearch-users"],
        ) is True

    def test_denies_when_user_has_no_matching_group(self) -> None:
        assert is_group_allowed(
            groups=["/finance"],
            allowed=["docsearch-users"],
        ) is False

    def test_case_insensitive_comparison(self) -> None:
        assert is_group_allowed(
            groups=["DocSearch-Users"],
            allowed=["docsearch-users"],
        ) is True

    def test_leading_slash_stripped(self) -> None:
        assert is_group_allowed(
            groups=["/docsearch-users"],
            allowed=["docsearch-users"],
        ) is True

    def test_allows_if_any_group_matches(self) -> None:
        assert is_group_allowed(
            groups=["finance", "docsearch-users"],
            allowed=["docsearch-users"],
        ) is True


class TestGetCurrentUser:
    """get_current_user reads from request.session."""

    def test_returns_none_when_not_logged_in(self) -> None:
        request = MagicMock()
        request.session = {}
        assert get_current_user(request) is None

    def test_returns_user_dict_when_logged_in(self) -> None:
        user = {"sub": "abc123", "name": "Test User"}
        request = MagicMock()
        request.session = {"user": user}
        assert get_current_user(request) == user


class TestGetUserGroups:
    """get_user_groups reads from request.session."""

    def test_returns_empty_list_when_no_groups(self) -> None:
        request = MagicMock()
        request.session = {}
        assert get_user_groups(request) == []

    def test_returns_groups_list(self) -> None:
        request = MagicMock()
        request.session = {"groups": ["/docsearch-users"]}
        assert get_user_groups(request) == ["/docsearch-users"]


class TestRequireAuth:
    """require_auth decorator redirects unauthenticated requests."""

    @pytest.mark.asyncio
    async def test_redirects_when_no_session(self) -> None:
        request = MagicMock()
        request.session = {}
        request.url.path = "/protected"
        request.url.__str__ = lambda s: "http://localhost/protected"

        @require_auth
        async def handler(req: MagicMock) -> str:
            return "secret"  # type: ignore[return-value]

        response = await handler(request)
        # Should be a RedirectResponse to /login
        assert response.status_code == 302
        assert "/login" in response.headers["location"]

    @pytest.mark.asyncio
    async def test_calls_handler_when_authenticated(self) -> None:
        from unittest.mock import patch

        request = MagicMock()
        request.session = {
            "user": {"sub": "abc", "name": "Test"},
            "groups": [],
        }

        called = []

        @require_auth
        async def handler(req: MagicMock) -> str:
            called.append(True)
            return "ok"  # type: ignore[return-value]

        # Patch settings to have no allowed groups so group check passes
        with patch("app.middleware.auth.get_settings") as mock_settings:
            mock_settings.return_value.allowed_groups_list = []
            result = await handler(request)

        assert called == [True]
        assert result == "ok"
