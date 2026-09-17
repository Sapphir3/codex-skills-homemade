#!/usr/bin/env python3
"""Structural validator for handwritten-labnote-to-markdown outputs."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$", re.MULTILINE)
PLACEHOLDER_RE = re.compile(r"<[^>\n]+>")
UNCERTAINTY_RE = re.compile(r"⟦(U\d{3,})⟧")
REPORT_ID_RE = re.compile(r"(?:^|\|)\s*(U\d{3,})\s*(?=\|)", re.MULTILINE)


def read_text(path: Path, label: str) -> str:
    if not path.is_file():
        raise ValueError(f"{label} file does not exist: {path}")
    text = path.read_text(encoding="utf-8")
    if not text.strip():
        raise ValueError(f"{label} file is empty: {path}")
    return text


def literal_template_headings(template: str) -> list[tuple[int, str]]:
    headings: list[tuple[int, str]] = []
    for marks, title in HEADING_RE.findall(template):
        if not PLACEHOLDER_RE.search(title):
            headings.append((len(marks), title.strip()))
    return headings


def final_headings(final: str) -> list[tuple[int, str]]:
    return [(len(marks), title.strip()) for marks, title in HEADING_RE.findall(final)]


def check_heading_order(template: str, final: str) -> list[str]:
    expected = literal_template_headings(template)
    actual = final_headings(final)
    errors: list[str] = []
    cursor = 0
    for heading in expected:
        try:
            index = actual.index(heading, cursor)
        except ValueError:
            errors.append(f"missing or reordered template heading: {'#' * heading[0]} {heading[1]}")
        else:
            cursor = index + 1
    if not any(level == 1 for level, _ in actual):
        errors.append("final.md has no level-1 heading")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--final", required=True, type=Path)
    parser.add_argument("--uncertainties", required=True, type=Path)
    parser.add_argument("--traceability", required=True, type=Path)
    args = parser.parse_args()

    errors: list[str] = []
    warnings: list[str] = []
    try:
        template = read_text(args.template, "template")
        final = read_text(args.final, "final")
        uncertainties = read_text(args.uncertainties, "uncertainties")
        traceability = read_text(args.traceability, "traceability")
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    errors.extend(check_heading_order(template, final))

    placeholders = sorted(set(PLACEHOLDER_RE.findall(final)))
    if placeholders:
        errors.append("unresolved template placeholders in final.md: " + ", ".join(placeholders))

    final_ids = set(UNCERTAINTY_RE.findall(final))
    report_ids = set(REPORT_ID_RE.findall(uncertainties))
    missing = sorted(final_ids - report_ids)
    if missing:
        errors.append("uncertainty markers missing from uncertainties.md: " + ", ".join(missing))

    if "# Traceability" not in traceability:
        errors.append("traceability.md is missing '# Traceability'")
    if "Source" not in traceability or "Pages inspected" not in traceability or "Template" not in traceability:
        errors.append("traceability.md is missing source-manifest fields")

    for token in ("TODO", "[TODO", "TBD"):
        if token in final:
            warnings.append(f"final.md contains scaffold-like token: {token}")

    if re.search(r"(?im)^\s*(?:[-*]\s*)?(?:N/?A|not provided|未记录)\s*$", final):
        warnings.append("final.md may use a fill-in phrase where a blank field is preferred")

    for warning in warnings:
        print(f"WARNING: {warning}")
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(
        "OK: required files are readable; template headings are preserved; "
        f"{len(final_ids)} inline uncertainty marker(s) are synchronized."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
