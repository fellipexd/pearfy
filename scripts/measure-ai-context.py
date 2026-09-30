#!/usr/bin/env python3
"""Measure Pearfy Skills-first catalog and project-context artifacts (not model tokens)."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


SCENARIOS = [
    ("Create a simple REST route", ["http"], "Use current router/controller macros; inspect target registration."),
    ("Create an entity and migration", ["data", "postgres", "transactions"], "No complete ORM/migration lifecycle; review the generated plan and approval boundary."),
    ("Implement comments in PearfySocial", ["social", "social-postgres", "data"], "Contracts/worker exist; durable content/feed PostgreSQL store is absent."),
    ("Generate a TypeScript SDK", ["connect"], "SDK generation and contract diff are not implemented."),
    ("Create a Populate plan", ["populate"], "Executor is bounded/single-target; run requires explicit approval."),
    ("Investigate a slow route", ["http", "observability", "metric"], "PearfyMetric, structured logs and distributed traces are unavailable; HTTP counters are process-lifetime."),
]


def markdown_bytes(directory: Path) -> int:
    if not directory.is_dir():
        return 0
    return sum(
        path.stat().st_size
        for path in directory.rglob("*.md")
        if path.is_file() and not path.is_symlink()
    )


def package_products(package_path: Path) -> set[str]:
    if not package_path.is_file():
        return set()
    source = package_path.read_text(encoding="utf-8")
    patterns = (
        r'\.product\s*\(\s*name\s*:\s*"([^"]+)"\s*,\s*package\s*:\s*"Pearfy"',
        r'\.library\s*\(\s*name\s*:\s*"(Pearfy[^"]*)"',
    )
    return {match for pattern in patterns for match in re.findall(pattern, source)}


def resolved_modules(registry: dict[str, Any], root: Path) -> tuple[str, list[str], str]:
    modules = {module["id"]: module for module in registry["modules"]}
    lock_path = root / ".pearfy/modules.json"
    if lock_path.is_file():
        try:
            lock = json.loads(lock_path.read_text(encoding="utf-8"))
            selected = [item for item in lock["modules"] if modules.get(item, {}).get("available")]
            discovery = "managed-lock"
        except (ValueError, KeyError, TypeError):
            return "invalid-lock", [], "invalid"
    else:
        products = package_products(root / "Package.swift")
        selected = [
            module["id"]
            for module in registry["modules"]
            if module.get("available") and set(module.get("products", [])) & products
        ]
        discovery = "package-product-inference" if selected else "no-managed-modules-detected"

    resolved: set[str] = set()
    active: set[str] = set()

    def visit(module_id: str) -> None:
        module = modules.get(module_id)
        if not module or not module.get("available") or module_id in resolved:
            return
        if module_id in active:
            return
        active.add(module_id)
        for dependency in module.get("requires", []):
            visit(dependency)
        active.remove(module_id)
        resolved.add(module_id)

    for module_id in selected:
        visit(module_id)
    return discovery, sorted(resolved), "known" if discovery == "managed-lock" else "inferred"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1], help="Pearfy project root")
    args = parser.parse_args()
    root = args.root.resolve()
    registry_path = root / "Sources/PearfyCLIKit/module-registry.json"
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
    modules = {module["id"]: module for module in registry["modules"]}
    discovery, installed, version_status = resolved_modules(registry, root)

    skill_ids = sorted({
        modules[module_id]["skill"]
        for module_id in installed
        if modules[module_id].get("skill")
    })
    source_skills_root = root / ".agents/skills"
    installed_skill_bytes = sum(markdown_bytes(source_skills_root / skill_id) for skill_id in skill_ids)
    canonical_skill_ids = sorted({
        module["skill"]
        for module in registry["modules"]
        if module.get("available") and module.get("skill")
        and (root / ".agents/skills" / module["skill"] / "SKILL.md").is_file()
    })
    all_canonical_skill_bytes = sum(markdown_bytes(source_skills_root / skill_id) for skill_id in canonical_skill_ids)

    settings_path = root / ".pearfy/ai.json"
    try:
        settings = json.loads(settings_path.read_text(encoding="utf-8")) if settings_path.is_file() else {}
    except (ValueError, OSError):
        settings = {}
    granted = sorted(set(settings.get("mcpModules", [])) & set(installed))
    potential_tools = sum(len(modules[module_id].get("mcpTools", [])) for module_id in granted)
    opencode_config_path = root / "opencode.json"
    try:
        config = json.loads(opencode_config_path.read_text(encoding="utf-8")) if opencode_config_path.is_file() else {}
        configured_enabled = config.get("mcp", {}).get("pearfy", {}).get("enabled")
    except (ValueError, OSError, AttributeError):
        configured_enabled = None
    exposed_tools = potential_tools if configured_enabled is not False else 0

    scenario_reports = []
    for name, module_ids, limitation in SCENARIOS:
        manifests = [modules[module_id] for module_id in module_ids]
        skill_set = sorted({module["skill"] for module in manifests if module.get("skill")})
        unavailable = [module["id"] for module in manifests if not module.get("available")]
        scenario_reports.append({
            "task": name,
            "modules": module_ids,
            "implemented_skills": skill_set,
            "skill_count": len(skill_set),
            "skill_reference_bytes": sum(markdown_bytes(source_skills_root / skill_id) for skill_id in skill_set),
            "unavailable_modules": unavailable,
            "boundary": limitation,
            "mcp_tool_definitions_if_enabled": sum(len(module.get("mcpTools", [])) for module in manifests),
        })

    result = {
        "measurement": "filesystem bytes and Registry tool counts; not token counts or observed LLM context",
        "project_root": str(root),
        "module_discovery": discovery,
        "module_versions": version_status,
        "catalog": {
            "entries": len(registry["modules"]),
            "available": sum(bool(module.get("available")) for module in registry["modules"]),
            "planned": sum(not bool(module.get("available")) for module in registry["modules"]),
            "canonical_skills": len(canonical_skill_ids),
            "canonical_skill_reference_bytes": all_canonical_skill_bytes,
        },
        "project": {
            "installed_modules": installed,
            "installed_skills": skill_ids,
            "installed_skill_reference_bytes": installed_skill_bytes,
            "enabled_mcp_modules": granted,
            "mcp_tool_definitions_if_client_enabled": potential_tools,
            "mcp_tool_definitions_exposed_by_project_opencode_config": exposed_tools if configured_enabled is not None else None,
        },
        "scenarios": scenario_reports,
        "unmeasured": ["actual OpenCode prompt tokens", "MCP call count per LLM task", "LLM task completion/correction quality"],
    }
    print(json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
