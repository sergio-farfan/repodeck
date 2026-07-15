#!/usr/bin/env python3
"""Push dev-to-article.md to the published dev.to article.

Usage:
    DEVTO_API_KEY=xxxx python3 Scripts/update-devto-article.py

The key comes from the environment only — never hardcode it, never paste it
into a chat or commit it. Generate one at https://dev.to/settings/extensions
and revoke it there after use if in doubt (note: generating a new key does
NOT invalidate old ones on dev.to; each needs its own explicit Revoke).

dev.to sits behind Cloudflare, which 403s default python/curl user agents —
hence the browser-like User-Agent below. The PUT sends body_markdown only,
so the article's title, tags, cover image, and SEO description are preserved.
"""

import json
import os
import sys
import urllib.request

ARTICLE_ID = 4101979
ARTICLE_SOURCE = os.path.join(os.path.dirname(__file__), "..", "dev-to-article.md")

api_key = os.environ.get("DEVTO_API_KEY")
if not api_key:
    sys.exit("DEVTO_API_KEY is not set. Usage: DEVTO_API_KEY=xxxx python3 Scripts/update-devto-article.py")

with open(ARTICLE_SOURCE, encoding="utf-8") as f:
    body = f.read()

request = urllib.request.Request(
    f"https://dev.to/api/articles/{ARTICLE_ID}",
    method="PUT",
    data=json.dumps({"article": {"body_markdown": body}}).encode(),
    headers={
        "api-key": api_key,
        "Content-Type": "application/json",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
    },
)

try:
    with urllib.request.urlopen(request) as response:
        result = json.load(response)
        print(f"Updated: {result['url']} (edited {result.get('edited_at', 'n/a')})")
except urllib.error.HTTPError as error:
    sys.exit(f"HTTP {error.code}: {error.read().decode()[:500]}")
