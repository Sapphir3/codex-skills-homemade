#!/usr/bin/env python3
"""Structural validator for handwritten-labnote-to-markdown outputs."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import date
from pathlib import Path


HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$", re.MULTILINE)
PLACEHOLDER_RE = re.compile(r"<[^>\n]+>")
UNCERTAINTY_RE = re.compile(r"⟦(U\d{3,})⟧")
REPORT_ID_RE = re.compile(r"(?:^|\|)\s*(U\d{3,})\s*(?=\|)", re.MULTILINE)


def read_text(path: Path, label: str) -> str:
    if not path.is_file():
        raise ValueError(f"{label} file does not exist: {path}")
    text = path.read_text(encoding="utf-8-sig")
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


def section_lines(text: str):
    section = ''
    for line in text.splitlines():
        if HEADING_RE.fullmatch(line):
            # Placeholder H1 changes; its metadata section remains comparable.
            section = '' if line.startswith('# ') else line.strip()
        else:
            yield section, line


def prompts(text: str):
    result = []
    for section, line in section_lines(text):
        match = re.match(r'^\s*[-*]\s+(.+?[：:])', line)
        if match:
            result.append((section, match.group(1)))
    return result


def table_cells(line: str):
    return [x.strip() for x in re.split(r'(?<!\\)\|', line.strip().strip('|'))]


def tables(text: str):
    lines = list(section_lines(text))
    headers = []
    errors = []
    for i, (section, line) in enumerate(lines[:-1]):
        if not line.strip().startswith('|'):
            continue
        sep = lines[i+1][1]
        if not sep.strip().startswith('|') or not all(re.fullmatch(r':?-{3,}:?', c) for c in table_cells(sep)):
            continue
        cells = table_cells(line)
        headers.append((section, tuple(cells)))
        if len(table_cells(sep)) != len(cells):
            errors.append(f'table separator column mismatch at line {i+2}')
        for j in range(i+2, len(lines)):
            row = lines[j][1]
            if not row.strip().startswith('|'):
                break
            if len(table_cells(row)) != len(cells):
                errors.append(f'table row column mismatch at line {j+1}')
    return headers, errors


def template_contract(template, override=None):
    modes = re.findall(r'<!--\s*labnote:mode=([^>]*?)\s*-->', template)
    errors = []
    if len(modes) > 1 or any(m not in {'strict','guided'} for m in modes):
        errors.append('invalid or duplicate template mode directive')
    mode = override or (modes[0] if modes else 'strict')
    dates = re.findall(r'<!--\s*labnote:run-date-field=([^>]*?)\s*-->', template)
    if len(dates) > 1 or (dates and not dates[0].strip()):
        errors.append('invalid or duplicate run-date-field directive')
    if mode == 'guided':
        template = re.sub(r'<!--\s*labnote:(?:guide\b|mode=|run-date-field=).*?-->', '', template, flags=re.DOTALL)
        if re.search(r'<!--\s*labnote:', template):
            errors.append('unrecognized or unclosed labnote guidance directive')
    return template, mode, dates[0].strip() if dates else None, errors


def validate(template, final, uncertainties, traceability, evidence=None, template_mode=None, run_date=None):
    template, mode, date_field, errors = template_contract(template, template_mode)
    errors.extend(check_heading_order(template, final))
    if mode == 'guided' and re.search(r'<!--\s*labnote:', final):
        errors.append('template guidance/directives leaked into final note')
    if date_field:
        values = re.findall(r'(?m)^\s*[-*]\s*'+re.escape(date_field)+r'[：:]\s*([^\r\n]*)', final)
        try:
            if len(values) != 1 or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', values[0]):
                raise ValueError
            date.fromisoformat(values[0])
            if run_date is not None and values[0] != run_date:
                errors.append('conversion date does not match recorded --run-date')
        except ValueError:
            errors.append('conversion date field must contain one valid YYYY-MM-DD value')
    actual = prompts(final)
    cursor = 0
    for item in prompts(template):
        try:
            cursor = actual.index(item, cursor)+1
        except ValueError:
            errors.append(f'missing, moved or reordered template prompt: {item}')
    expected_tables, _ = tables(template)
    actual_tables, table_errors = tables(final)
    errors.extend(table_errors)
    cursor = 0
    for item in expected_tables:
        try:
            cursor = actual_tables.index(item, cursor)+1
        except ValueError:
            errors.append(f'missing, moved or changed template table: {item}')
    # Only placeholders actually present in the runtime template; HTML and
    # mathematical inequalities in evidence must not be rejected as placeholders.
    for token in set(PLACEHOLDER_RE.findall(template)):
        if token in final:
            errors.append('unresolved template placeholder: '+token)
    inline = set(UNCERTAINTY_RE.findall(final+'\n'+traceability))
    queue = REPORT_ID_RE.findall(uncertainties)
    reported = set(queue)
    if len(queue) != len(reported):
        errors.append('duplicate uncertainty IDs in review queue')
    if inline - reported:
        errors.append('uncertainty markers missing from queue: '+', '.join(sorted(inline-reported)))
    if reported - inline:
        errors.append('orphan uncertainty rows: '+', '.join(sorted(reported-inline)))
    if '# Traceability' not in traceability:
        errors.append("traceability.md is missing '# Traceability'")
    for label in ('Source', 'Pages inspected', 'Template'):
        if not re.search(r'(?m)^- '+label+r':\s*\S', traceability):
            errors.append('missing source-manifest field: '+label)
    if evidence is not None:
        try:
            count = evidence['page_count']
            inspected = evidence['inspected_pages']
            items = evidence['evidence']
            if type(count) is not int or count < 1 or not isinstance(items, list):
                raise ValueError('invalid page count or evidence list')
            expected = set(range(1,count+1))
            if any(type(p) is not int for p in inspected) or set(inspected) != expected or len(inspected) != count:
                errors.append('evidence inspected_pages does not cover every source page exactly once')
            seen = set()
            covered = set()
            by_id = {}
            for item in items:
                if item['id'] in seen:
                    errors.append('duplicate evidence ID: '+item['id'])
                seen.add(item['id'])
                by_id[item['id']] = item
                if type(item['page']) is not int or item['page'] not in expected:
                    errors.append('invalid evidence page: '+str(item['page']))
                covered.add(item['page'])
                if item['status'] not in {'confirmed','uncertain','crossed out','revised','unmapped','user-confirmed','blank'}:
                    errors.append('invalid evidence status: '+item['status'])
                if not item['text'].strip() or not item['region'].strip() or not item['destination'].strip():
                    errors.append('empty evidence text, region, or destination')
                for uid in UNCERTAINTY_RE.findall(item['text']):
                    if uid not in reported:
                        errors.append('evidence uncertainty missing from queue: '+uid)
                if 'role' in item and item['role'] not in {'objective','plan','object','parameter','operation','observation','calculation','problem','hypothesis','next_step','data','correction','other'}:
                    errors.append('invalid evidence role: '+str(item['role']))
                if 'required_in_final' in item and type(item['required_in_final']) is not bool:
                    errors.append('required_in_final must be boolean')
                if item.get('required_in_final') is True and not re.search(r'<!--\s*evidence:'+re.escape(item['id'])+r'\s*-->',final):
                    errors.append('required evidence missing from final: '+item['id'])
                if 'links' in item and (not isinstance(item['links'],list) or not all(isinstance(x,str) for x in item['links'])):
                    errors.append('evidence links must be a list of IDs')
            for eid,item in by_id.items():
                related = item.get('links', [])
                if not isinstance(related,list):
                    related = []
                for target in ([item['parent_id']] if item.get('parent_id') is not None else [])+related:
                    if not isinstance(target,str) or target not in by_id:
                        errors.append('unknown evidence relation target: '+str(target))
                visited = {eid}
                parent = item.get('parent_id')
                while isinstance(parent,str) and parent in by_id:
                    if parent in visited:
                        errors.append('cycle in evidence parents: '+eid)
                        break
                    visited.add(parent)
                    parent = by_id[parent].get('parent_id')
            if covered != expected:
                errors.append('evidence ledger has missing or unexpected source pages')
        except (KeyError, TypeError, ValueError, AttributeError) as exc:
            errors.append('invalid evidence JSON: '+str(exc))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--final", required=True, type=Path)
    parser.add_argument("--uncertainties", required=True, type=Path)
    parser.add_argument("--traceability", required=True, type=Path)
    parser.add_argument("--evidence", type=Path, help="Optional page-level evidence JSON")
    parser.add_argument('--template-mode', choices=['strict','guided'])
    parser.add_argument('--run-date', help='Recorded local conversion date, YYYY-MM-DD')
    args = parser.parse_args()

    errors: list[str] = []
    warnings: list[str] = []
    try:
        template = read_text(args.template, "template")
        final = read_text(args.final, "final")
        uncertainties = read_text(args.uncertainties, "uncertainties")
        traceability = read_text(args.traceability, "traceability")
        evidence = json.loads(read_text(args.evidence, 'evidence')) if args.evidence else None
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    errors.extend(validate(template, final, uncertainties, traceability, evidence, args.template_mode, args.run_date))
    final_ids = set(UNCERTAINTY_RE.findall(final+'\n'+traceability))

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
        "OK: headings, prompts, tables, and uncertainty references checked; "
        f"{len(final_ids)} unresolved uncertainty ID(s). Structural checks do not verify handwriting accuracy."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
