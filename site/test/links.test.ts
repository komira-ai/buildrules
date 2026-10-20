import { checkSite, fileOf, inspectHtml, type Files } from '../tools/check-dist';
import { builtSite } from './helpers';

const real = builtSite();

describe('the built site', () => {
  test('has no broken internal link or fragment, and no orphan page', () => {
    expect(checkSite(real)).toEqual([]);
  });
  test('every internal link target exists (counted)', () => {
    let n = 0;
    for (const [file, c] of real) {
      if (!file.endsWith('.html')) continue;
      for (const l of inspectHtml(file, c.toString()).links) {
        n++;
        const path = l.split('#')[0];
        expect(path === '' || real.has(fileOf(path))).toBe(true);
      }
    }
    expect(n).toBeGreaterThan(200);
  });
});

// The checker must be able to fail: each case plants one defect into a copy of the real site.
function planted(edit: (file: string, html: string) => string | undefined): Files {
  const m = new Map(real);
  for (const [file, c] of real) {
    if (!file.endsWith('.html')) continue;
    const e = edit(file, c.toString());
    if (e !== undefined) m.set(file, e);
  }
  return m;
}
const onHome = (f: (h: string) => string) => (file: string, h: string) => (file === 'index.html' ? f(h) : undefined);

describe('planted defects are caught', () => {
  test('a link to a page that does not exist', () => {
    const p = checkSite(planted(onHome((h) => h.replace('href="/cli/"', 'href="/clii/"'))));
    expect(p.join('\n')).toMatch(/index\.html: broken link \/clii\/ \(no clii\/index\.html\)/);
  });
  test('a link to a heading that does not exist', () => {
    const p = checkSite(planted(onHome((h) => h.replace('href="/concepts/#lockfile-native"', 'href="/concepts/#no-such-section"'))));
    expect(p.join('\n')).toMatch(/has no id 'no-such-section'/);
  });
  test('a same-page fragment that does not exist', () => {
    const p = checkSite(planted(onHome((h) => h.replace('href="#main"', 'href="#mainn"'))));
    expect(p.join('\n')).toMatch(/has no id 'mainn'/);
  });
  test('a page nothing links to', () => {
    const m = new Map(real);
    m.set('lonely/index.html', real.get('faq/index.html') as string);
    expect(checkSite(m).join('\n')).toMatch(/lonely\/index\.html: no page links to it/);
  });
  test('a missing stylesheet', () => {
    const m = new Map(real);
    for (const k of [...m.keys()]) if (k.endsWith('.css')) m.delete(k);
    expect(checkSite(m).join('\n')).toMatch(/broken link \/assets\/site\.[0-9a-f]+\.css/);
  });
  test.each([
    ['a script', (h: string) => h.replace('</body>', '<script src="/x.js"></script></body>'), /contains <script>/],
    ['an inline style', (h: string) => h.replace('<body>', '<body style="color:red">'), /style attribute/],
    ['an inline style element', (h: string) => h.replace('</head>', '<style>a{}</style></head>'), /<style>/],
    ['an event handler', (h: string) => h.replace('<body>', '<body onload="x()">'), /event handler/],
    ['an image from elsewhere', (h: string) => h.replace('</main>', '<img src="https://t.example/p.gif"></main>'), /element the site does not use/],
    ['a stylesheet from elsewhere', (h: string) => h.replace('</head>', '<link rel="stylesheet" href="https://cdn.example/x.css"></head>'), /from another site/],
    ['an external link without noopener', (h: string) => h.replace('</main>', '<a href="https://example.org/">x</a></main>'), /lacks rel="noopener"/],
    ['an http URL', (h: string) => h.replace('</main>', '<p>http://example.org</p></main>'), /http:\/\//],
    ['a duplicate id', (h: string) => h.replace('<main id="main"', '<main id="main"').replace('<article>', '<article id="main">'), /duplicate id 'main'/],
    ['a second h1', (h: string) => h.replace('</main>', '<h1>again</h1></main>'), /exactly one <h1>/],
    ['no title', (h: string) => h.replace(/<title>[^<]*<\/title>/, ''), /<title>/],
  ])('%s', (_name, edit, re) => {
    expect(checkSite(planted(onHome(edit))).join('\n')).toMatch(re);
  });
  test('a sitemap that omits a page', () => {
    const m = new Map(real);
    m.set('sitemap.xml', (real.get('sitemap.xml') as string).replace('<url><loc>https://buildrules.dev/faq/</loc></url>\n', ''));
    expect(checkSite(m).join('\n')).toMatch(/sitemap\.xml lists/);
  });
});
