// Checks on a built site, as a map of path (`index.html`, `rules/rust/index.html`, `assets/site.<hash>.css`) to its
// contents. The build runs it on what it is about to write and the tests run it on the same map, so a broken link
// fails both. It returns the problems as text; an empty list means the site is sound.

export type Files = ReadonlyMap<string, string | Buffer>;

const text = (v: string | Buffer): string => (typeof v === 'string' ? v : v.toString('utf8'));

/** The file a URL path names: `/` -> index.html, `/x/` -> x/index.html, `/a.css` -> a.css. */
export function fileOf(urlPath: string): string {
  const rel = urlPath.replace(/^\//, '');
  return rel === '' || rel.endsWith('/') ? `${rel}index.html` : rel;
}

function attrs(tag: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const m of tag.matchAll(/\s([a-zA-Z-]+)="([^"]*)"/g)) out.set(m[1], m[2]);
  return out;
}

export interface PageFacts {
  ids: string[];
  /** Every internal link target of the page: `a href`, `link href`, `src`, as written. */
  links: string[];
  problems: string[];
}

export function inspectHtml(file: string, html: string): PageFacts {
  const problems: string[] = [];
  const bad = (msg: string) => problems.push(`${file}: ${msg}`);
  if (!html.startsWith('<!doctype html>')) bad('does not start with <!doctype html>');
  if (!/<html lang="[a-z-]+">/.test(html)) bad('<html> has no lang');
  if (!/<meta charset="utf-8">/.test(html)) bad('no <meta charset>');
  if (!/<meta name="viewport" content="[^"]+">/.test(html)) bad('no viewport meta');
  if ((html.match(/<title>[^<]+<\/title>/g) ?? []).length !== 1) bad('needs exactly one non-empty <title>');
  if ((html.match(/<meta name="description" content="[^"]+">/g) ?? []).length !== 1) bad('needs exactly one meta description');
  if ((html.match(/<h1[ >]/g) ?? []).length !== 1) bad('needs exactly one <h1>');
  if ((html.match(/<main[ >]/g) ?? []).length !== 1) bad('needs exactly one <main>');
  // The site is served with a Content-Security-Policy that allows no inline script or style, and it promises no tracking.
  if (/<script\b/i.test(html)) bad('contains <script>');
  if (/<style\b/i.test(html)) bad('contains <style>');
  if (/\sstyle="/i.test(html)) bad('contains a style attribute');
  if (/\son[a-z]+=/i.test(html)) bad('contains an event handler attribute');
  if (/<(iframe|img|video|audio|embed|object|form|input)\b/i.test(html)) bad('contains an element the site does not use');
  if (/http:\/\//.test(html)) bad('contains an http:// URL');

  const ids: string[] = [];
  for (const m of html.matchAll(/\sid="([^"]*)"/g)) ids.push(m[1]);
  const dup = ids.filter((id, i) => ids.indexOf(id) !== i);
  for (const d of new Set(dup)) bad(`duplicate id '${d}'`);

  const links: string[] = [];
  for (const m of html.matchAll(/<(a|link)\b[^>]*>/g)) {
    const a = attrs(m[0]);
    const href = a.get('href');
    if (href === undefined) {
      if (m[1] === 'a') bad(`<a> without href: ${m[0]}`);
      continue;
    }
    if (href.startsWith('https://')) {
      if (m[1] === 'link' && a.get('rel') !== 'canonical') bad(`<link> loads ${href} from another site`);
      if (m[1] === 'a' && a.get('rel') !== 'noopener') bad(`external link ${href} lacks rel="noopener"`);
      continue;
    }
    if (!href.startsWith('/') && !href.startsWith('#')) {
      bad(`link '${href}' is neither absolute-path, fragment nor https`);
      continue;
    }
    links.push(href);
  }
  return { ids, links, problems };
}

export function checkSite(files: Files): string[] {
  const problems: string[] = [];
  const facts = new Map<string, PageFacts>();
  for (const [file, content] of files) {
    if (!file.endsWith('.html')) continue;
    const f = inspectHtml(file, text(content));
    problems.push(...f.problems);
    facts.set(file, f);
  }
  if (!facts.has('index.html')) problems.push('index.html is missing');
  if (!facts.has('404.html')) problems.push('404.html is missing');

  const reached = new Set<string>(['404.html']);
  const queue = ['index.html'];
  reached.add('index.html');
  while (queue.length > 0) {
    const file = queue.shift() as string;
    const page = facts.get(file);
    if (page === undefined) continue;
    for (const link of page.links) {
      const hash = link.indexOf('#');
      const path = hash < 0 ? link : link.slice(0, hash);
      const frag = hash < 0 ? '' : link.slice(hash + 1);
      const target = path === '' ? file : fileOf(path);
      if (!files.has(target)) {
        problems.push(`${file}: broken link ${link} (no ${target})`);
        continue;
      }
      if (frag !== '') {
        const t = facts.get(target);
        if (t === undefined) problems.push(`${file}: link ${link} names a fragment in ${target}, which is not a page`);
        else if (!t.ids.includes(frag)) problems.push(`${file}: broken link ${link} (${target} has no id '${frag}')`);
      }
      if (facts.has(target) && !reached.has(target)) {
        reached.add(target);
        queue.push(target);
      }
    }
  }
  for (const file of facts.keys()) {
    if (!reached.has(file)) problems.push(`${file}: no page links to it`);
  }

  // sitemap.xml lists exactly the pages (404.html excluded).
  const sitemap = files.get('sitemap.xml');
  if (sitemap === undefined) problems.push('sitemap.xml is missing');
  else {
    const listed = [...text(sitemap).matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]).sort();
    const pages = [...facts.keys()]
      .filter((f) => f !== '404.html')
      .map((f) => `https://buildrules.dev/${f === 'index.html' ? '' : f.replace(/index\.html$/, '')}`)
      .sort();
    if (JSON.stringify(listed) !== JSON.stringify(pages)) problems.push(`sitemap.xml lists ${listed.join(' ')}; the pages are ${pages.join(' ')}`);
  }
  return problems;
}
