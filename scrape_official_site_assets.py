#!/usr/bin/env python3
"""
Collect publicly exposed image/video asset URLs from official Josefa/Urbanista pages.
This does not bypass logins, paywalls, DRM, or robots. Review rights before reuse.
"""
from __future__ import annotations
import argparse, csv, hashlib, os, re, sys, urllib.parse
from pathlib import Path
import requests
from bs4 import BeautifulSoup
from tqdm import tqdm

ASSET_EXTS = ('.jpg','.jpeg','.png','.webp','.avif','.gif','.mp4','.webm','.mov')
HEADERS = {'User-Agent':'Mozilla/5.0 TravelOS media research bot (authorized use only)'}


def absolutize(base: str, url: str) -> str | None:
    if not url or url.startswith('data:') or url.startswith('blob:'):
        return None
    return urllib.parse.urljoin(base, url.strip())


def extract_urls(page_url: str) -> list[str]:
    r = requests.get(page_url, headers=HEADERS, timeout=30)
    r.raise_for_status()
    html = r.text
    soup = BeautifulSoup(html, 'html.parser')
    urls = set()
    attrs = ['src','href','data-src','data-lazy-src','poster']
    for tag in soup.find_all(True):
        for a in attrs:
            u = absolutize(page_url, tag.get(a))
            if u and urllib.parse.urlparse(u).path.lower().endswith(ASSET_EXTS):
                urls.add(u)
        # srcset may contain multiple candidates
        srcset = tag.get('srcset') or tag.get('data-srcset')
        if srcset:
            for part in srcset.split(','):
                candidate = part.strip().split(' ')[0]
                u = absolutize(page_url, candidate)
                if u and urllib.parse.urlparse(u).path.lower().endswith(ASSET_EXTS):
                    urls.add(u)
    # catch asset URLs embedded in scripts/css
    for m in re.findall(r'https?://[^\s"\'<>\\]+', html):
        clean = m.rstrip('),;')
        if urllib.parse.urlparse(clean).path.lower().endswith(ASSET_EXTS):
            urls.add(clean)
    return sorted(urls)


def safe_name(url: str) -> str:
    path = urllib.parse.urlparse(url).path
    name = os.path.basename(path) or hashlib.sha1(url.encode()).hexdigest()
    name = re.sub(r'[^A-Za-z0-9._-]+','_', name)
    if len(name) < 5:
        name = hashlib.sha1(url.encode()).hexdigest() + '_' + name
    return name


def download(url: str, outdir: Path) -> Path | None:
    outdir.mkdir(parents=True, exist_ok=True)
    filename = safe_name(url)
    target = outdir / filename
    if target.exists() and target.stat().st_size > 0:
        return target
    try:
        with requests.get(url, headers=HEADERS, stream=True, timeout=60) as r:
            r.raise_for_status()
            total = int(r.headers.get('content-length') or 0)
            with open(target, 'wb') as f, tqdm(total=total, unit='B', unit_scale=True, desc=filename[:28]) as bar:
                for chunk in r.iter_content(chunk_size=1024*256):
                    if chunk:
                        f.write(chunk)
                        bar.update(len(chunk))
        return target
    except Exception as e:
        print(f"WARN: failed {url}: {e}", file=sys.stderr)
        if target.exists():
            target.unlink(missing_ok=True)
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--pages', nargs='+', required=True, help='Official pages to scan')
    ap.add_argument('--out', default='JOSEFA_VIDEO/raw_official_site', help='Output folder')
    ap.add_argument('--download', action='store_true', help='Download discovered assets')
    args = ap.parse_args()
    out = Path(args.out)
    rows = []
    for page in args.pages:
        print(f"Scanning {page}")
        try:
            urls = extract_urls(page)
        except Exception as e:
            print(f"ERROR: {page}: {e}", file=sys.stderr)
            continue
        for u in urls:
            local = ''
            if args.download:
                p = download(u, out)
                local = str(p) if p else ''
            rows.append({'source_page': page, 'asset_url': u, 'local_file': local})
    out.mkdir(parents=True, exist_ok=True)
    manifest = out / 'asset_manifest.csv'
    with open(manifest, 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=['source_page','asset_url','local_file'])
        w.writeheader(); w.writerows(rows)
    print(f"Saved manifest: {manifest} ({len(rows)} assets)")
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
