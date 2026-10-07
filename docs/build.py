#!/usr/bin/env python3
"""docs/build.py — build the documentation site. Stdlib only, like msbctl.

    python3 docs/build.py                  # writes docs/_site
    python3 docs/build.py --out DIR        # somewhere else
    python3 docs/build.py --check          # and fail on a broken internal link,
                                           # a missing anchor or an undocumented
                                           # msbctl subcommand
    python3 docs/build.py --base /repo/    # absolute base, for 404.html only
    python3 docs/build.py --site-url URL   # where it is published (default: the
                                           # repo's github.io address)

Pages are docs/content/*.md, each opening with a small front-matter block:

    ---
    title: Install
    section: Start here
    order: 20
    ---

CHANGELOG.md is added as one more page, so the site never carries a second copy
of it.

The Markdown is a deliberate SUBSET — headings, paragraphs, lists, fenced code,
tables, `>` callouts, and inline code, bold, italic and links — because that is
all these pages use, and a converter small enough to read in one sitting beats a
dependency to pin, audit and keep current. That is the same stance msbctl takes,
and the reason this is not MkDocs. If a page needs more, extend this file.

Every link is RELATIVE, so the output works under any path GitHub Pages serves it
from and straight off the disk (open _site/index.html). The one exception is
404.html, which GitHub serves at whatever depth the missing URL had; it gets a
<base> from --base.

Search engines and agents get what they look for, all generated from the same
pages: a canonical URL, Open Graph and Twitter card tags (with a social card
image) and JSON-LD on every page; sitemap.xml; and for agents, llms.txt (the
llmstxt.org index), llms-full.txt (every page in one file) and a Markdown copy
of each page beside its HTML (install.md beside install.html), linked from the
page as rel=alternate. Those are the only absolute URLs, so they come from
--site-url. There is no robots.txt: for a project site it would sit under
/<repo>/, and crawlers only read the one at the root of the host.
"""

import argparse
import html
import json
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CONTENT = os.path.join(HERE, "content")
ASSETS = os.path.join(HERE, "assets")
BRAND = os.path.join(ROOT, "assets")      # the logo files, shared with the repo

REPO = os.environ.get("GITHUB_REPOSITORY") or "naerymdan/sandbox-manager"
REPO_URL = f"https://github.com/{REPO}"
_OWNER, _, _NAME = REPO.partition("/")
SITE_URL = f"https://{_OWNER.lower()}.github.io/{_NAME}/"
TAGLINE = ("Run coding agents in per-project microVMs with deny-by-default egress, "
           "and credentials and SSH keys that never enter the VM.")
SECTIONS = ["Start here", "Guides", "Reference", "Project"]
GENERATED = ("llms.txt", "llms-full.txt", "sitemap.xml")   # written beside the pages


def esc(text):
    return html.escape(text, quote=True)


def slugify(text):
    text = re.sub(r"<[^>]+>", "", text).lower()
    text = re.sub(r"[^a-z0-9\s-]", "", text)
    return re.sub(r"[\s-]+", "-", text).strip("-")


# ---------------------------------------------------------------- inline

class Page:
    """One page: its metadata, and what rendering it found (links, anchors)."""

    def __init__(self, slug, title, section, order, source, edit_url, description=""):
        self.slug, self.title, self.section, self.order = slug, title, section, order
        self.source, self.edit_url, self.description = source, edit_url, description
        self.links, self.anchors, self.toc = [], set(), []

    @property
    def href(self):
        return f"{self.slug}.html"


def rewrite_href(url, page):
    """`other.md#x` -> `other.html#x`, recorded for --check. External links pass."""
    if re.match(r"[a-z]+:", url) or url.startswith("//"):
        return url
    target, _, anchor = url.partition("#")
    if target.endswith(".md"):
        target = target[:-3] + ".html"
    page.links.append((target or page.href, anchor))
    return target + ("#" + anchor if anchor else "")


def inline(text, page):
    """Inline Markdown to HTML. Code spans and links are swapped out for
    placeholders first, so nothing later can reach inside them."""
    kept = []

    def keep(fragment):
        kept.append(fragment)
        return f"\x00{len(kept) - 1}\x00"

    text = re.sub(r"`([^`]+)`", lambda m: keep(f"<code>{esc(m.group(1))}</code>"), text)
    text = re.sub(r"<(https?://[^>\s]+)>",
                  lambda m: keep(f'<a href="{esc(m.group(1))}">{esc(m.group(1))}</a>'), text)

    def link(m):
        label, url = m.group(1), m.group(2)
        href = rewrite_href(url, page)
        external = re.match(r"https?:", href) is not None
        rel = ' rel="noopener"' if external else ""
        return keep(f'<a href="{esc(href)}"{rel}>{emphasis(esc(label))}</a>')

    text = re.sub(r"!\[([^\]]*)\]\(([^)\s]+)\)",
                  lambda m: keep(f'<img src="{esc(m.group(2))}" alt="{esc(m.group(1))}">'), text)
    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, text)
    text = emphasis(esc(text))
    while "\x00" in text:
        text = re.sub(r"\x00(\d+)\x00", lambda m: kept[int(m.group(1))], text)
    return text


def emphasis(text):
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    return re.sub(r"(?<![\w*])\*([^*\s][^*]*?)\*(?![\w*])", r"<em>\1</em>", text)


# ------------------------------------------------------------- code blocks

def split_comment(line):
    """(code, comment) — the first # that starts a word and is outside quotes."""
    quote = None
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i], line[i:]
    return line, ""


def highlight(lang, line):
    """Just enough colour to read by: comments dimmed, TOML tables and keys,
    strings. Anything fancier would be a lexer, and this is not that file."""
    if lang in ("text", "", "output"):
        return esc(line)
    code, comment = split_comment(line)
    if lang == "toml" and re.match(r"\s*\[", code):
        out = f'<span class="t-tbl">{esc(code)}</span>'
    elif lang == "toml" and re.match(r"\s*[\w.\"-]+\s*=", code):
        key, eq, rest = code.partition("=")
        out = f'<span class="t-key">{esc(key)}</span>{eq}{strings(rest)}'
    else:
        out = strings(code)
    if comment:
        out += f'<span class="t-com">{esc(comment)}</span>'
    return out


def strings(code):
    parts = re.split(r'("[^"]*"|\'[^\']*\')', code)
    return "".join(f'<span class="t-str">{esc(p)}</span>' if i % 2 else esc(p)
                   for i, p in enumerate(parts))


def code_block(lang, title, lines):
    lang = lang or "text"
    rows = []
    for line in lines:
        if lang == "console":
            if line.startswith("$ "):
                rows.append(f'<span class="t-prompt">$ </span>'
                            f'<span class="t-cmd">{highlight("sh", line[2:])}</span>')
            else:
                rows.append(f'<span class="t-out">{esc(line)}</span>')
        else:
            rows.append(highlight(lang, line))
    label = title or {"console": "terminal", "sh": "sh", "text": "output"}.get(lang, lang)
    return (f'<div class="term" data-lang="{esc(lang)}">'
            f'<div class="term-bar"><span class="dots" aria-hidden="true"><i></i><i></i><i></i></span>'
            f'<span class="term-title">{esc(label)}</span>'
            f'<button class="copy" type="button" aria-label="Copy to clipboard">copy</button></div>'
            f'<pre><code>{chr(10).join(rows)}</code></pre></div>')


# ------------------------------------------------------------------ blocks

FENCE = re.compile(r"^(\s*)```([\w-]*)\s*(?:title=\"([^\"]*)\")?\s*$")
HEADING = re.compile(r"^(#{2,4})\s+(.*?)\s*#*\s*$")
LIST_ITEM = re.compile(r"^(\s*)([-*]|\d+\.)\s+(.*)$")
TABLE_RULE = re.compile(r"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$")
CALLOUT = re.compile(r"^<p><strong>(Note|Tip|Warning|Important)[:.]?</strong>:?\s*", re.I)


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def starts_block(lines, i):
    line = lines[i]
    return bool(FENCE.match(line) or HEADING.match(line) or LIST_ITEM.match(line)
                or line.lstrip().startswith(">") or re.match(r"^\s*-{3,}\s*$", line)
                or (line.lstrip().startswith("|") and i + 1 < len(lines)
                    and TABLE_RULE.match(lines[i + 1])))


def render_blocks(lines, page, depth=0):
    out, i, n = [], 0, len(lines)
    while i < n:
        line = lines[i]
        if not line.strip():
            i += 1
            continue

        m = FENCE.match(line)
        if m:
            pad, body, i = len(m.group(1)), [], i + 1
            while i < n and not re.match(r"^\s*```\s*$", lines[i]):
                body.append(lines[i][pad:] if lines[i][:pad].isspace() else lines[i].lstrip())
                i += 1
            out.append(code_block(m.group(2), m.group(3), body))
            i += 1
            continue

        m = HEADING.match(line)
        if m:
            level, text = len(m.group(1)), m.group(2)
            ident = slugify(inline(text, page))
            base, k = ident, 2
            while ident in page.anchors:
                ident, k = f"{base}-{k}", k + 1
            page.anchors.add(ident)
            if level <= 3 and depth == 0:
                page.toc.append((level, ident, re.sub(r"<[^>]+>", "", inline(text, page))))
            out.append(f'<h{level} id="{ident}">{inline(text, page)}'
                       f'<a class="anchor" href="#{ident}" aria-label="Link to this section">#</a></h{level}>')
            i += 1
            continue

        if re.match(r"^\s*-{3,}\s*$", line):
            out.append("<hr>")
            i += 1
            continue

        if line.lstrip().startswith("|") and i + 1 < n and TABLE_RULE.match(lines[i + 1]):
            def cells(row):
                # `\|` is a literal pipe inside a cell.
                parts = re.split(r"(?<!\\)\|", row.strip().strip("|"))
                return [c.strip().replace("\\|", "|") for c in parts]
            head, i = cells(line), i + 2
            body = []
            while i < n and lines[i].lstrip().startswith("|"):
                body.append(cells(lines[i]))
                i += 1
            th = "".join(f"<th>{inline(c, page)}</th>" for c in head)
            trs = "".join("<tr>" + "".join(f"<td>{inline(c, page)}</td>" for c in row) + "</tr>"
                          for row in body)
            out.append(f'<div class="table-wrap"><table><thead><tr>{th}</tr></thead>'
                       f"<tbody>{trs}</tbody></table></div>")
            continue

        if line.lstrip().startswith(">"):
            quoted = []
            while i < n and lines[i].lstrip().startswith(">"):
                quoted.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            inner = render_blocks(quoted, page, depth + 1)
            m = CALLOUT.match(inner)
            if m:
                kind = m.group(1).lower()
                inner = "<p>" + inner[m.end():]
                out.append(f'<aside class="callout callout-{kind}" data-label="{kind}">{inner}</aside>')
            else:
                out.append(f"<blockquote>{inner}</blockquote>")
            continue

        m = LIST_ITEM.match(line)
        if m:
            html_list, i = render_list(lines, i, page, depth)
            out.append(html_list)
            continue

        para = [line.strip()]
        i += 1
        while i < n and lines[i].strip() and not starts_block(lines, i):
            para.append(lines[i].strip())
            i += 1
        body = inline(" ".join(para), page)
        # A paragraph that is only an image is a figure, styled as such.
        hero = ' class="hero"' if re.fullmatch(r"<img [^>]*>", body) else ""
        out.append(f"<p{hero}>{body}</p>")
    return "\n".join(out)


def render_list(lines, i, page, depth):
    first = LIST_ITEM.match(lines[i])
    base = len(first.group(1))
    ordered = first.group(2)[0].isdigit()
    items, n = [], len(lines)
    while i < n:
        m = LIST_ITEM.match(lines[i])
        if not m or len(m.group(1)) != base or m.group(2)[0].isdigit() != ordered:
            break
        content_at = m.start(3)
        body = [m.group(3)]
        i += 1
        while i < n:
            line = lines[i]
            if not line.strip():
                j = i
                while j < n and not lines[j].strip():
                    j += 1
                if j < n and indent_of(lines[j]) > base:
                    body.extend([""] * (j - i))
                    i = j
                    continue
                break
            if indent_of(line) > base:
                body.append(line[min(content_at, indent_of(line)):])
                i += 1
                continue
            if not starts_block(lines, i):          # a lazy continuation line
                body.append(line.strip())
                i += 1
                continue
            break
        inner = render_blocks(body, page, depth + 1)
        if inner.startswith("<p>"):                  # tight: no <p> around the first line
            end = inner.index("</p>")
            inner = inner[3:end] + inner[end + 4:]
        items.append(f"<li>{inner}</li>")
        # Blank lines between two items of the same list do not end it.
        j = i
        while j < n and not lines[j].strip():
            j += 1
        if j < n and j != i and (m2 := LIST_ITEM.match(lines[j])) and len(m2.group(1)) == base:
            i = j
    tag = "ol" if ordered else "ul"
    return f"<{tag}>{''.join(items)}</{tag}>", i


# ------------------------------------------------------------------ pages

def read_page(path, slug=None, defaults=None):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    meta = dict(defaults or {})
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if m:
        for line in m.group(1).splitlines():
            key, _, value = line.partition(":")
            meta[key.strip()] = value.strip()
        text = text[m.end():]
    slug = slug or os.path.splitext(os.path.basename(path))[0]
    rel = os.path.relpath(path, ROOT)
    page = Page(slug, meta.get("title", slug), meta.get("section", "Guides"),
                int(meta.get("order", 999)), text, f"{REPO_URL}/blob/main/{rel}",
                meta.get("description", ""))
    if page.section not in SECTIONS:
        sys.exit(f"build.py: {rel}: unknown section {page.section!r} (one of {SECTIONS})")
    return page


def load_pages():
    pages = [read_page(os.path.join(CONTENT, f))
             for f in sorted(os.listdir(CONTENT)) if f.endswith(".md")]
    # The changelog is the repo's own file, not a copy; its H1 is the page title.
    changelog = read_page(os.path.join(ROOT, "CHANGELOG.md"), "changelog",
                          {"title": "Changelog", "section": "Project", "order": "90",
                           "description": "Every user-visible change to msb-manager, by release."})
    changelog.source = re.sub(r"^# .*\n", "", changelog.source, count=1)
    pages.append(changelog)
    pages.sort(key=lambda p: (SECTIONS.index(p.section), p.order, p.title))
    return pages


def plain(markdown):
    """Searchable text: the words, without the Markdown around them."""
    text = re.sub(r"^```.*$", " ", markdown, flags=re.M)
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", " ", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"[`*>|#]", " ", text)
    text = re.sub(r"^\s*-{3,}\s*$", " ", text, flags=re.M)
    return re.sub(r"\s+", " ", text).strip()


def search_entries(page):
    """One entry per H2/H3 section (and the page's own intro), so a hit lands
    on the part of the page that matched rather than on its top."""
    entries, heading, anchor, buf = [], "", "", []

    def flush():
        text = plain("\n".join(buf))
        if text or heading:
            entries.append({"p": page.title, "h": heading,
                            "u": page.href + (f"#{anchor}" if anchor else ""),
                            "t": text[:2400]})

    in_fence = False
    seen = {}
    for line in page.source.splitlines():
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
        m = None if in_fence else re.match(r"^(#{2,3})\s+(.*?)\s*$", line)
        if m:
            flush()
            heading = re.sub(r"[`*]", "", re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", m.group(2)))
            ident = slugify(heading)
            seen[ident] = seen.get(ident, 0) + 1
            anchor = ident if seen[ident] == 1 else f"{ident}-{seen[ident]}"
            buf = []
        else:
            buf.append(line)
    flush()
    return entries


def nav_html(pages, current):
    out = []
    for section in SECTIONS:
        members = [p for p in pages if p.section == section]
        if not members:
            continue
        rows = []
        for k, p in enumerate(members):
            branch = "└──" if k == len(members) - 1 else "├──"
            active = ' class="active" aria-current="page"' if p is current else ""
            rows.append(f'<li><span class="branch" aria-hidden="true">{branch}</span>'
                        f'<a href="{p.href}"{active}>{esc(p.title)}</a></li>')
        out.append(f'<div class="nav-group"><div class="nav-dir">{esc(slugify(section))}/</div>'
                   f'<ul>{"".join(rows)}</ul></div>')
    return "\n".join(out)


def toc_html(page):
    if len(page.toc) < 2:
        return ""
    rows = "".join(f'<li class="toc-l{level}"><a href="#{ident}">{esc(text)}</a></li>'
                   for level, ident, text in page.toc)
    return f'<nav class="toc" aria-label="On this page"><div class="toc-title">on this page</div><ul>{rows}</ul></nav>'


def pager_html(pages, page):
    k = pages.index(page)
    prev = pages[k - 1] if k > 0 else None
    nxt = pages[k + 1] if k + 1 < len(pages) else None
    left = (f'<a class="prev" href="{prev.href}"><span class="dim">cd ..</span> {esc(prev.title)}</a>'
            if prev else "<span></span>")
    right = (f'<a class="next" href="{nxt.href}"><span class="dim">next:</span> {esc(nxt.title)} →</a>'
             if nxt else "<span></span>")
    return f'<nav class="pager" aria-label="Pages">{left}{right}</nav>'


def markdown_copy(page):
    """The page as Markdown, for agents: its title as the H1, the front matter
    dropped. Its relative links (other.md, assets/...) resolve against the other
    copies, so it reads correctly on its own."""
    lead = f"> {page.description}\n\n" if page.description else ""
    return f"# {page.title}\n\n{lead}{page.source.strip()}\n"


def json_ld(data):
    # `</` would end the <script> early; JSON allows it escaped.
    return ('<script type="application/ld+json">'
            + json.dumps(data, separators=(",", ":")).replace("</", "<\\/") + "</script>")


def meta_html(page, site_url, ver):
    url = site_url + ("" if page.slug == "index" else page.href)
    title = "msb-manager" if page.slug == "index" else f"{page.title} · msb-manager docs"
    desc = page.description or TAGLINE
    image = site_url + "assets/social-card.png"
    website = {"@type": "WebSite", "@id": site_url + "#website", "name": "msb-manager docs",
               "url": site_url, "inLanguage": "en"}
    if page.slug == "index":
        graph = [website, {
            "@type": "SoftwareSourceCode", "name": "msb-manager", "description": TAGLINE,
            "url": site_url, "codeRepository": REPO_URL, "programmingLanguage": "Python",
            "runtimePlatform": "Linux", "license": "https://opensource.org/licenses/MIT",
            "version": ver}]
    else:
        graph = [website, {
            "@type": "TechArticle", "headline": page.title, "description": desc, "url": url,
            "isPartOf": {"@id": site_url + "#website"}, "inLanguage": "en",
            "about": {"@type": "SoftwareSourceCode", "name": "msb-manager",
                      "codeRepository": REPO_URL}},
            {"@type": "BreadcrumbList", "itemListElement": [
                {"@type": "ListItem", "position": 1, "name": "msb-manager docs", "item": site_url},
                {"@type": "ListItem", "position": 2, "name": page.title, "item": url}]}]
    tags = [
        f'<link rel="canonical" href="{esc(url)}">',
        f'<link rel="alternate" type="text/markdown" href="{page.slug}.md" title="This page as Markdown">',
        '<meta name="theme-color" content="#0b0e0c" media="(prefers-color-scheme: dark)">',
        '<meta name="theme-color" content="#fbfaf4" media="(prefers-color-scheme: light)">',
        '<meta property="og:type" content="website">' if page.slug == "index"
        else '<meta property="og:type" content="article">',
        '<meta property="og:site_name" content="msb-manager docs">',
        f'<meta property="og:title" content="{esc(title)}">',
        f'<meta property="og:description" content="{esc(desc)}">',
        f'<meta property="og:url" content="{esc(url)}">',
        f'<meta property="og:image" content="{esc(image)}">',
        '<meta property="og:image:width" content="1200">',
        '<meta property="og:image:height" content="630">',
        '<meta property="og:image:alt" content="msb-manager: coding agents in per-project microVMs">',
        '<meta name="twitter:card" content="summary_large_image">',
        json_ld({"@context": "https://schema.org", "@graph": graph}),
    ]
    return "\n".join(tags)


def llms_txt(pages, site_url):
    """llmstxt.org: an H1, a one-line summary, then sections of links to the
    Markdown copies. The changelog goes under "Optional", the part an agent
    with little room may skip."""
    out = ["# msb-manager", "", f"> {TAGLINE}", "",
           "msb-manager is a single-file, dependency-free Python CLI (`msbctl`) around "
           "microsandbox (`msb`). The Markdown pages below are the full documentation; "
           f"`{site_url}llms-full.txt` is all of them in one file. Source: {REPO_URL}", ""]
    optional = [p for p in pages if p.slug == "changelog"]
    for section in SECTIONS:
        members = [p for p in pages if p.section == section and p not in optional]
        if members:
            out.append(f"## {section}\n")
            out += [f"- [{p.title}]({site_url}{p.slug}.md)"
                    + (f": {p.description}" if p.description else "") for p in members]
            out.append("")
    if optional:
        out.append("## Optional\n")
        out += [f"- [{p.title}]({site_url}{p.slug}.md): {p.description}" for p in optional]
        out.append("")
    return "\n".join(out)


def llms_full_txt(pages, site_url):
    parts = [f"# msb-manager documentation\n\n> {TAGLINE}\n\nSource: {REPO_URL}\n"]
    for p in pages:
        parts.append(f"<!-- {site_url}{p.href} -->\n" + markdown_copy(p))
    return "\n---\n\n".join(parts)


def sitemap_xml(pages, site_url):
    urls = "".join(f"<url><loc>{esc(site_url + ('' if p.slug == 'index' else p.href))}</loc></url>"
                   for p in pages)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">{urls}</urlset>\n')


def render_template(**values):
    with open(os.path.join(HERE, "template.html"), encoding="utf-8") as fh:
        text = fh.read()
    for key, value in values.items():
        text = text.replace("{{%s}}" % key, value)
    left = re.findall(r"\{\{(\w+)\}\}", text)
    if left:
        sys.exit(f"build.py: template.html: unfilled placeholders: {', '.join(sorted(set(left)))}")
    return text


def version():
    try:
        with open(os.path.join(ROOT, "VERSION"), encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return "dev"


def build(out, base="", site_url=SITE_URL):
    site_url = site_url.rstrip("/") + "/"
    pages = load_pages()
    bodies = {p.slug: render_blocks(p.source.splitlines(), p) for p in pages}

    if os.path.isdir(out):
        shutil.rmtree(out)
    shutil.copytree(ASSETS, os.path.join(out, "assets"))
    shutil.copytree(BRAND, os.path.join(out, "assets", "brand"))
    with open(os.path.join(out, ".nojekyll"), "w") as fh:
        fh.write("")                                  # serve the files as they are

    ver = version()
    common = dict(VERSION=esc(ver), REPO_URL=esc(REPO_URL), BASE="")
    for page in pages:
        page_html = render_template(
            **common,
            TITLE=esc(page.title if page.slug != "index" else "msb-manager"),
            HEADING=esc(page.title),
            DESCRIPTION=esc(page.description or TAGLINE),
            META=meta_html(page, site_url, ver),
            NAV=nav_html(pages, page),
            TOC=toc_html(page),
            BODY=bodies[page.slug],
            PAGER=pager_html(pages, page),
            EDIT_URL=esc(page.edit_url))
        with open(os.path.join(out, page.href), "w", encoding="utf-8") as fh:
            fh.write(page_html)
        with open(os.path.join(out, f"{page.slug}.md"), "w", encoding="utf-8") as fh:
            fh.write(markdown_copy(page))

    for name, text in zip(GENERATED, (llms_txt(pages, site_url),
                                      llms_full_txt(pages, site_url),
                                      sitemap_xml(pages, site_url))):
        with open(os.path.join(out, name), "w", encoding="utf-8") as fh:
            fh.write(text)

    missing = render_template(
        **{**common, "BASE": f'<base href="{esc(base)}">' if base else ""},
        TITLE="not found", HEADING="command not found",
        DESCRIPTION="Page not found",
        META='<meta name="robots" content="noindex">',
        NAV=nav_html(pages, None), TOC="",
        BODY=('<div class="term"><div class="term-bar"><span class="dots" aria-hidden="true">'
              '<i></i><i></i><i></i></span><span class="term-title">terminal</span></div>'
              '<pre><code><span class="t-prompt">$ </span><span class="t-cmd">cat this-page</span>\n'
              '<span class="t-out">cat: this-page: No such file or directory</span></code></pre></div>'
              '<p>That page does not exist. Try the search above, or start at the '
              '<a href="index.html">overview</a>.</p>'),
        PAGER="", EDIT_URL=esc(REPO_URL))
    with open(os.path.join(out, "404.html"), "w", encoding="utf-8") as fh:
        fh.write(missing)

    index = [e for p in pages for e in search_entries(p)]
    with open(os.path.join(out, "assets", "search-index.js"), "w", encoding="utf-8") as fh:
        # A script, not JSON: fetch() refuses file:// in most browsers, and the
        # site should work opened straight off the disk.
        fh.write("window.MSB_SEARCH = " + json.dumps(index, separators=(",", ":")) + ";\n")
    return pages


# ------------------------------------------------------------------- check

def msbctl_commands():
    """Every user-facing subcommand, read from msbctl's argparse setup."""
    with open(os.path.join(ROOT, "msbctl"), encoding="utf-8") as fh:
        src = fh.read()
    names = set(re.findall(r'sub\.add_parser\("([a-z][a-z-]*)"', src))
    names |= set(re.findall(r'^\s*\("([a-z][a-z-]*)", cmd_\w+, "', src, re.M))
    return sorted(names)


def check(pages):
    problems = []
    by_href = {p.href: p for p in pages}
    for page in pages:
        for target, anchor in page.links:
            dest = by_href.get(target)
            if dest is None and target not in GENERATED:
                problems.append(f"{page.slug}: link to missing page {target}")
            elif anchor and anchor not in dest.anchors:
                problems.append(f"{page.slug}: link to missing anchor {target}#{anchor}")
        if not page.description:
            problems.append(f"{page.slug}: no description (search results and link previews show it)")
    commands = by_href.get("commands.html")
    if commands is None:
        problems.append("no commands page")
    else:
        for name in msbctl_commands():
            if f"msbctl-{name}" not in commands.anchors:
                problems.append(f"commands: `msbctl {name}` has no section (### `msbctl {name}`)")
    return problems


def main():
    parser = argparse.ArgumentParser(description="Build the msb-manager documentation site.")
    parser.add_argument("--out", default=os.path.join(HERE, "_site"))
    parser.add_argument("--base", default="", help="absolute site path, e.g. /sandbox-manager/")
    parser.add_argument("--site-url", default=SITE_URL,
                        help=f"the published address, for canonical links, the sitemap "
                             f"and llms.txt (default {SITE_URL})")
    parser.add_argument("--check", action="store_true",
                        help="fail on broken links, anchors or undocumented commands")
    args = parser.parse_args()
    pages = build(args.out, args.base, args.site_url)
    if args.check:
        problems = check(pages)
        if problems:
            for p in problems:
                print(f"  {p}", file=sys.stderr)
            sys.exit(f"build.py: {len(problems)} problem(s)")
    shown = os.path.relpath(args.out)
    print(f"built {len(pages)} pages into {args.out if shown.startswith('..') else shown}")


if __name__ == "__main__":
    main()
