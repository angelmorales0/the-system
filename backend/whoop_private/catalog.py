"""Typed catalog of the 311 private iOS API endpoint rows.

Official /developer/v2/... paths already used by integrations.py are NOT in
this catalog (they never appeared in the iOS capture list). Use
integrations.py + the public OAuth token for those.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Mapping
from urllib.parse import urlencode

from ._endpoints_data import ENDPOINTS_RAW
from .errors import WhoopDestructiveBlocked


PLACEHOLDER_RE = re.compile(r"\{([a-zA-Z0-9_]+)\}")


@dataclass(frozen=True)
class EndpointSpec:
    """One captured private-API operation."""

    method: str
    path_template: str
    query_template: Mapping[str, str] = field(default_factory=dict)
    observed_status: int | str | None = None
    destructive: bool = False
    write: bool = False

    @property
    def key(self) -> str:
        query = urlencode(sorted(self.query_template.items())) if self.query_template else ""
        suffix = f"?{query}" if query else ""
        status = "" if self.observed_status is None else f" {self.observed_status}"
        return f"{self.method}{status} {self.path_template}{suffix}"

    def render(
        self,
        path_params: Mapping[str, Any] | None = None,
        query_params: Mapping[str, Any] | None = None,
    ) -> tuple[str, dict[str, str]]:
        """Fill path placeholders and merge query values."""
        params = {str(k): str(v) for k, v in (path_params or {}).items()}
        path = self.path_template
        missing: list[str] = []

        def repl(match: re.Match[str]) -> str:
            name = match.group(1)
            if name not in params:
                missing.append(name)
                return match.group(0)
            return params[name]

        path = PLACEHOLDER_RE.sub(repl, path)
        if missing:
            raise ValueError(f"Missing path params for {self.path_template}: {missing}")

        query: dict[str, str] = {}
        for key, value in self.query_template.items():
            if PLACEHOLDER_RE.search(value):
                filled = PLACEHOLDER_RE.sub(repl, value)
                if "{" in filled:
                    # Still unresolved; let caller override via query_params.
                    continue
                query[key] = filled
            else:
                query[key] = value
        for key, value in (query_params or {}).items():
            if value is None:
                continue
            query[str(key)] = str(value)
        # Also allow leftover path_params to fill query placeholders by name.
        for key, value in params.items():
            if key in self.query_template and key not in (query_params or {}):
                tmpl = self.query_template[key]
                if PLACEHOLDER_RE.search(tmpl):
                    query[key] = value
        return path, query


def _specs_from_raw() -> tuple[EndpointSpec, ...]:
    specs: list[EndpointSpec] = []
    for row in ENDPOINTS_RAW:
        specs.append(
            EndpointSpec(
                method=str(row["method"]),
                path_template=str(row["path"]),
                query_template=dict(row.get("query_template") or {}),
                observed_status=row.get("observed_status"),
                destructive=bool(row.get("destructive")),
                write=bool(row.get("write")),
            )
        )
    return tuple(specs)


ENDPOINTS: tuple[EndpointSpec, ...] = _specs_from_raw()


def unique_callables() -> tuple[EndpointSpec, ...]:
    """Collapse status-variant rows into unique method + path + query template."""
    seen: dict[tuple[str, str, tuple[tuple[str, str], ...]], EndpointSpec] = {}
    for spec in ENDPOINTS:
        key = (spec.method, spec.path_template, tuple(sorted(spec.query_template.items())))
        existing = seen.get(key)
        if existing is None:
            seen[key] = spec
        elif spec.destructive and not existing.destructive:
            seen[key] = spec
    return tuple(seen.values())


def find_endpoints(
    *,
    method: str | None = None,
    path_contains: str | None = None,
    destructive: bool | None = None,
) -> list[EndpointSpec]:
    out: list[EndpointSpec] = []
    for spec in unique_callables():
        if method and spec.method != method.upper():
            continue
        if path_contains and path_contains not in spec.path_template:
            continue
        if destructive is not None and spec.destructive != destructive:
            continue
        out.append(spec)
    return out


def require_confirm(spec: EndpointSpec, confirm: bool) -> None:
    if spec.destructive and not confirm:
        raise WhoopDestructiveBlocked(
            f"Refusing destructive {spec.method} {spec.path_template} without confirm=True. "
            "Preview with client.preview_destructive(...) first."
        )


def is_destructive(method: str, path: str) -> bool:
    method_u = method.upper()
    if method_u == "DELETE":
        return True
    if "/autopop/" in path:
        return True
    for spec in unique_callables():
        if spec.method == method_u and _path_matches(spec.path_template, path) and spec.destructive:
            return True
    return False


def _path_matches(template: str, concrete: str) -> bool:
    pattern = re.escape(template)
    pattern = PLACEHOLDER_RE.sub(lambda _: r"[^/]+", pattern)
    return re.fullmatch(pattern, concrete.split("?")[0]) is not None
