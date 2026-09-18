#!/usr/bin/env python3
"""Prepare color page previews, a source manifest, and reproducible detail crops.

Requires pypdfium2. No OCR, network calls, or scientific interpretation.
Cache keys include source bytes, render settings, renderer version and schema.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
import platform
import time
from importlib.metadata import version
from pathlib import Path

SCHEMA = 1

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def positive(value):
    value = int(value)
    if not 36 <= value <= 600:
        raise argparse.ArgumentTypeError('DPI must be between 36 and 600')
    return value

def crop_box(value):
    try:
        box = tuple(float(x) for x in value.split(','))
        if len(box) != 4 or not all(math.isfinite(x) for x in box):
            raise ValueError
        x0, y0, x1, y1 = box
        if not (0 <= x0 < x1 <= 1 and 0 <= y0 < y1 <= 1):
            raise ValueError
        return box
    except ValueError:
        raise argparse.ArgumentTypeError('Use normalized x0,y0,x1,y1 within 0..1')

def prepare(sources, output, dpi=144, page_number=None, box=None):
    import pypdfium2 as pdfium
    if (page_number is None) != (box is None):
        raise ValueError('--page and --crop must be supplied together')
    if box and len(sources) != 1:
        raise ValueError('Detail mode requires exactly one source')
    sources = [Path(p).resolve(strict=True) for p in sources]
    output = Path(output).resolve()
    if any(p.suffix.lower() != '.pdf' for p in sources):
        raise ValueError('This helper accepts PDF files; inspect image inputs directly')
    output.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    renderer = version('pypdfium2')
    settings = {'schema': SCHEMA, 'renderer': renderer, 'dpi': dpi,
                'page': page_number, 'crop': box, 'color': 'RGB', 'format': 'PNG'}
    records = []
    for order, source in enumerate(sources, 1):
        t = time.perf_counter()
        sha = digest(source)
        key = hashlib.sha256(json.dumps([sha, settings], sort_keys=True).encode()).hexdigest()
        cache = output / 'pages' / key
        cache.mkdir(parents=True, exist_ok=True)
        doc = pdfium.PdfDocument(str(source))
        try:
            count = len(doc)
            if page_number is not None and not 1 <= page_number <= count:
                raise ValueError(f'Page out of range for {source.name}: {page_number}')
            selected = [page_number - 1] if page_number else range(count)
            pages = []
            for i in selected:
                dest = cache / f'p{i+1:04}.png'
                stamp = dest.with_suffix('.json')
                cached = False
                if dest.is_file() and stamp.is_file():
                    try:
                        saved = json.loads(stamp.read_text(encoding='utf-8'))
                        cached = (saved['sha256'] == digest(dest)
                                  and all(type(saved[k]) is int and saved[k] > 0 for k in ('width','height')))
                    except (ValueError, KeyError, OSError, TypeError):
                        pass
                if not cached:
                    page = doc[i]
                    bitmap = None
                    try:
                        bitmap = page.render(scale=dpi / 72)
                        im = bitmap.to_pil().convert('RGB')
                        if box:
                            x0,y0,x1,y1 = box
                            im = im.crop((int(x0*im.width),int(y0*im.height),
                                          math.ceil(x1*im.width),math.ceil(y1*im.height)))
                        saved = {'sha256': None, 'width': im.width, 'height': im.height}
                        im.save(dest)
                        im.close()
                        saved['sha256'] = digest(dest)
                        stamp.write_text(json.dumps(saved), encoding='utf-8')
                    finally:
                        if bitmap is not None:
                            bitmap.close()
                        page.close()
                pages.append({'page': i+1, 'image': dest.relative_to(output).as_posix(),
                              **saved, 'cache_hit': cached})
        finally:
            doc.close()
        records.append({'source_id': f'S{order:03}', 'source': str(source),
                        'filename': source.name, 'sha256': sha, 'page_count': count,
                        'pages': pages, 'seconds': time.perf_counter()-t})
    return {'schema': SCHEMA, 'settings': settings, 'python': platform.python_version(),
            'sources': records, 'seconds': time.perf_counter()-started,
            'notice': 'Rendered pages are prepared, NOT visually inspected or transcribed.'}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, nargs='+', required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--dpi', type=positive, default=144)
    parser.add_argument('--page', type=int)
    parser.add_argument('--crop', type=crop_box)
    parser.add_argument('--manifest', type=Path)
    args = parser.parse_args()
    try:
        result = prepare(args.source, args.output_dir, args.dpi, args.page, args.crop)
        manifest = args.manifest or args.output_dir / 'manifest.json'
        if manifest.resolve() in [p.resolve() for p in args.source]:
            raise ValueError('Manifest must not overwrite a source')
        manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps({'manifest': str(manifest), 'seconds': result['seconds'],
                          'pages': sum(len(s['pages']) for s in result['sources']),
                          'cache_hits': sum(p['cache_hit'] for s in result['sources'] for p in s['pages'])}))
        return 0
    except (OSError, ValueError, ImportError) as exc:
        parser.error(str(exc))

if __name__ == '__main__':
    raise SystemExit(main())
