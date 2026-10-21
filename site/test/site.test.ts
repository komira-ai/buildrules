import { PAGES, NAV } from '../tools/pages';
import { fileOf } from '../tools/check-dist';
import { builtSite, html, textOf } from './helpers';

const files = builtSite();

describe('the page list', () => {
  test('is exactly the pages the site promises', () => {
    expect(PAGES.map((p) => p.path)).toEqual([
      '/',
      '/why/',
      '/getting-started/',
      '/how/',
      '/how/configure/',
      '/how/examples/',
      '/concepts/',
      '/rules/',
      '/rules/rust/',
      '/rules/node/',
      '/rules/zig/',
      '/rules/cxx/',
      '/rules/mojo/',
      '/rules/python/',
      '/cli/',
      '/remote-execution/',
      '/faq/',
    ]);
  });
  test('paths are unique directories and titles are unique', () => {
    expect(new Set(PAGES.map((p) => p.path)).size).toBe(PAGES.length);
    expect(new Set(PAGES.map((p) => p.title)).size).toBe(PAGES.length);
    for (const p of PAGES) expect(p.path).toMatch(/^\/([a-z-]+\/)*$/);
  });
  test('every page has a description of a sentence and a lead', () => {
    for (const p of PAGES) {
      expect(p.description.length).toBeGreaterThan(30);
      expect(p.description.length).toBeLessThan(300);
      expect(p.lead.length).toBeGreaterThan(20);
    }
  });
  test('the nav lists Home and the eight top pages, in order', () => {
    expect(NAV.map((n) => n.label)).toEqual(['Home', 'Why', 'Getting started', 'How', 'Concepts', 'Rules', 'CLI', 'Remote execution', 'FAQ']);
  });
  test('every page is written to its own index.html', () => {
    for (const p of PAGES) expect(files.has(fileOf(p.path))).toBe(true);
    expect(files.has('404.html')).toBe(true);
  });
});

describe('what is not built is marked planned', () => {
  test.each(['rules/python/index.html'])('%s opens with a planned note', (f) => {
    expect(html(files, f)).toMatch(/<div class="note planned" role="note"><strong>Planned\.<\/strong>/);
  });
  test('the rules index and the home page say built for Mojo and planned for Python', () => {
    for (const f of ['index.html', 'rules/index.html']) {
      const t = html(files, f);
      expect(t).toMatch(/Mojo<\/a><\/td><td>built<\/td>/);
      expect(t).toMatch(/Python<\/a><\/td><td>planned<\/td>/);
    }
  });
  test('the Node front door is described as existing', () => {
    const t = textOf(html(files, 'rules/node/index.html'));
    expect(t).toMatch(/The npm_package front door/);
    expect(t).toMatch(/buildrules npm sync PATH/);
    expect(t).not.toMatch(/Planned\. A buildrules npm command/);
  });
  test('the platforms and releases that are not built say planned', () => {
    const t = html(files, 'rules/index.html');
    for (const what of ['macOS', 'Windows', 'CPU levels armv8.0-a to armv8.4-a']) {
      expect({ what, planned: new RegExp(`<td>${what}</td><td>planned`).test(t) }).toEqual({ what, planned: true });
    }
    expect(t).not.toMatch(/Published releases are planned/);
    expect(t).toMatch(/mopm 0.0.15 is released and pinned/);
    expect(t).not.toMatch(/mopm release is still pending/);
    const mojo = html(files, 'rules/mojo/index.html');
    expect(mojo).toMatch(/<strong>Planned\.<\/strong> Building one package for two Mojo versions is planned/);
    expect(mojo).toMatch(/mopm 0.0.15 is released and pinned/);
    expect(mojo).not.toMatch(/stand-in|release is pending/);
  });
});

describe('the pages keep the site\'s promises', () => {
  test('no internal names, hosts, accounts or paths', () => {
    const banned: [RegExp, string][] = [
      [/\bk\u0062f\b/i, "the name of the farm software"],
      [new RegExp('kom' + 'ira(?!-ai\\/(buildrules|mopm))', 'i'), 'the origin project (only the public repository paths are allowed)'],
      [new RegExp('tho' + 'rium', 'i'), 'a retired project name'],
      [/\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/, 'an IPv4 address'],
      [/\b\d{12}\b/, 'a 12-digit number (an account id)'],
      [/\/home\/|\/Users\//, 'a home path'],
      [new RegExp('amazonaws\\.com|\\.inter' + 'nal\\b|\\.co' + 'rp\\b', 'i'), 'a host'],
      [/AKIA[0-9A-Z]{12}/, 'an access key'],
    ];
    for (const [file, content] of files) {
      if (!file.endsWith('.html')) continue;
      const t = textOf(content.toString());
      for (const [re, what] of banned) expect({ file, what, hit: re.test(t) }).toEqual({ file, what, hit: false });
    }
  });
  test('claims that sound like marketing are not made', () => {
    const t = [...files].filter(([f]) => f.endsWith('.html')).map(([, c]) => textOf(c.toString())).join(' ');
    for (const w of ['blazing', 'revolutionary', 'seamless', 'effortless', 'best-in-class', 'game-chang', 'next-generation', 'world-class']) {
      expect(t.toLowerCase()).not.toContain(w);
    }
  });
  test('the home page says what buildrules is, in its first paragraph', () => {
    const t = textOf(html(files, 'index.html'));
    expect(t).toMatch(/Buck2 rules/);
    expect(t).toMatch(/pins every toolchain by hash/);
    expect(t).toMatch(/caches each dependency separately/);
  });
  test('every page links to the CSS and icon of the site only', () => {
    for (const [file, c] of files) {
      if (!file.endsWith('.html')) continue;
      expect(c.toString()).toMatch(/<link rel="stylesheet" href="\/assets\/site\.[0-9a-f]{12}\.css">/);
    }
  });
  test('light and dark are both styled, and focus is visible', () => {
    const css = files.get([...files.keys()].find((k) => k.endsWith('.css')) as string)!.toString();
    expect(css).toContain('prefers-color-scheme: dark');
    expect(css).toContain(':focus-visible');
    expect(css).not.toMatch(/url\(\s*['"]?https?:/);
  });
});
