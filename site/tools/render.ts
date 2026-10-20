// Pages to HTML strings. Every string that reaches the output goes through escapeHtml (inline.ts) or is written here.
// There is no script, no inline style and no external resource: the stylesheet and the icon are files of the site.

import { escapeHtml, inline, plain, slug } from './inline';
import type { Block, Page } from './model';

export const SITE_URL = 'https://buildrules.dev';
export const SITE_NAME = 'buildrules';
export const REPO_URL = 'https://github.com/komira-ai/buildrules';

export interface Assets {
  /** The stylesheet's URL path, with its content hash. */
  css: string;
  icon: string;
}

export interface Rendered {
  html: string;
  /** The ids of the page's headings, in order. */
  ids: string[];
}

function headingIds(blocks: Block[]): Map<Block, string> {
  const used = new Set<string>();
  const ids = new Map<Block, string>();
  for (const b of blocks) {
    if (b.kind !== 'h2' && b.kind !== 'h3') continue;
    const base = slug(b.text);
    if (base === '') throw new Error(`heading '${b.text}' has an empty id`);
    let id = base;
    for (let n = 2; used.has(id); n++) id = `${base}-${n}`;
    used.add(id);
    ids.set(b, id);
  }
  return ids;
}

const NOTE_LABEL = { planned: 'Planned', limit: 'Limit', info: 'Note' } as const;

function renderBlocks(blocks: Block[], title: string): string {
  const ids = headingIds(blocks);
  let heading = title;
  const out: string[] = [];
  for (const b of blocks) {
    switch (b.kind) {
      case 'h2':
      case 'h3': {
        heading = plain(b.text);
        const id = ids.get(b) as string;
        out.push(`<${b.kind} id="${id}">${inline(b.text)} <a class="anchor" href="#${id}" aria-label="Link to this section">#</a></${b.kind}>`);
        break;
      }
      case 'p':
        out.push(`<p>${inline(b.text)}</p>`);
        break;
      case 'ul':
      case 'ol':
        out.push(`<${b.kind}>${b.items.map((i) => `<li>${inline(i)}</li>`).join('')}</${b.kind}>`);
        break;
      case 'code':
        out.push(
          `<div class="codeblock">${b.label ? `<div class="codelabel">${escapeHtml(b.label)}</div>` : ''}` +
            `<pre tabindex="0"><code>${escapeHtml(b.text)}</code></pre></div>`,
        );
        break;
      case 'table': {
        for (const r of b.rows) {
          if (r.length !== b.head.length) throw new Error(`table under '${heading}': a row has ${r.length} cells, the head ${b.head.length}`);
        }
        out.push(
          `<div class="table-wrap" role="region" aria-label="${escapeHtml(heading)}, table" tabindex="0"><table>` +
            `<thead><tr>${b.head.map((h) => `<th scope="col">${inline(h)}</th>`).join('')}</tr></thead>` +
            `<tbody>${b.rows.map((r) => `<tr>${r.map((c) => `<td>${inline(c)}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`,
        );
        break;
      }
      case 'note':
        out.push(`<div class="note ${b.tone}" role="note"><strong>${NOTE_LABEL[b.tone]}.</strong> ${inline(b.text)}</div>`);
        break;
    }
  }
  return out.join('\n');
}

function toc(blocks: Block[]): string {
  const ids = headingIds(blocks);
  const h2s = blocks.filter((b): b is Extract<Block, { kind: 'h2' }> => b.kind === 'h2');
  if (h2s.length < 3) return '';
  return (
    `<nav class="toc" aria-labelledby="toc-title"><p id="toc-title" class="toc-title">On this page</p><ul>` +
    h2s.map((b) => `<li><a href="#${ids.get(b)}">${escapeHtml(plain(b.text))}</a></li>`).join('') +
    `</ul></nav>`
  );
}

export interface NavItem {
  path: string;
  label: string;
}

function isCurrent(item: NavItem, page: Page): boolean {
  return item.path === '/' ? page.path === '/' : page.path === item.path || page.path.startsWith(item.path);
}

export function renderPage(page: Page, nav: NavItem[], assets: Assets): Rendered {
  const title = page.path === '/' ? `${SITE_NAME}: hermetic multi-language builds for Buck2` : `${page.title} | ${SITE_NAME}`;
  const navHtml = nav
    .map((n) => `<li><a href="${n.path}"${isCurrent(n, page) ? ' aria-current="page"' : ''}>${escapeHtml(n.label)}</a></li>`)
    .join('');
  const body = renderBlocks(page.blocks, page.title);
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<meta name="description" content="${escapeHtml(page.description)}">
<meta name="color-scheme" content="light dark">
<link rel="canonical" href="${SITE_URL}${page.path}">
<link rel="icon" href="${assets.icon}" type="image/svg+xml">
<link rel="stylesheet" href="${assets.css}">
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="site-header"><div class="wrap">
<a class="brand" href="/">${SITE_NAME}</a>
<nav aria-label="Main"><ul>${navHtml}</ul></nav>
</div></header>
<main id="main" class="wrap">
<article>
<h1>${escapeHtml(page.title)}</h1>
<p class="lead">${inline(page.lead)}</p>
${toc(page.blocks)}
${body}
</article>
</main>
<footer class="site-footer"><div class="wrap">
<p>buildrules is open source under the Apache-2.0 license. <a href="${REPO_URL}" rel="noopener">Source and issues on GitHub</a>.</p>
<p>This site sets no cookies, runs no scripts and loads nothing from other sites.</p>
</div></footer>
</body>
</html>
`;
  const ids = [...headingIds(page.blocks).values()];
  return { html, ids };
}

export function renderNotFound(nav: NavItem[], assets: Assets): string {
  const page: Page = {
    path: '/404.html',
    title: 'Page not found',
    description: 'There is no page at this address.',
    lead: 'There is no page at this address. It may have moved, or the link may be mistyped.',
    blocks: [{ kind: 'p', text: 'Start from the [home page](/) or the [getting started guide](/getting-started/).' }],
  };
  return renderPage(page, nav, assets).html.replace(`<link rel="canonical" href="${SITE_URL}/404.html">\n`, '<meta name="robots" content="noindex">\n');
}
