import { mkdtempSync, readdirSync, readFileSync, statSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { buildSite } from '../tools/build';
import { PAGES } from '../tools/pages';
import { SITE_DIR } from './helpers';

function listing(dir: string, rel = ''): string[] {
  return readdirSync(join(dir, rel)).flatMap((n) => {
    const r = rel === '' ? n : `${rel}/${n}`;
    return statSync(join(dir, r)).isDirectory() ? listing(dir, r) : [r];
  });
}

describe('the build', () => {
  const a = mkdtempSync(join(tmpdir(), 'site-a-'));
  const b = mkdtempSync(join(tmpdir(), 'site-b-'));

  test('writes every page, the assets, robots.txt and sitemap.xml', () => {
    expect(buildSite(join(SITE_DIR, 'static'), a)).toEqual([]);
    const files = listing(a);
    expect(files).toEqual(expect.arrayContaining(['index.html', '404.html', 'robots.txt', 'sitemap.xml', 'assets/icon.svg']));
    expect(files.filter((f) => /^assets\/site\.[0-9a-f]{12}\.css$/.test(f))).toHaveLength(1);
    expect(files.filter((f) => f.endsWith('index.html'))).toHaveLength(PAGES.length);
    expect(files).toHaveLength(PAGES.length + 5);
  });
  test('is deterministic: a second build is byte-identical', () => {
    expect(buildSite(join(SITE_DIR, 'static'), b)).toEqual([]);
    expect(listing(b)).toEqual(listing(a));
    for (const f of listing(a)) expect(readFileSync(join(b, f)).equals(readFileSync(join(a, f)))).toBe(true);
  });
  test('the 404 page is not indexed or canonical', () => {
    const t = readFileSync(join(a, '404.html'), 'utf8');
    expect(t).toContain('<meta name="robots" content="noindex">');
    expect(t).not.toContain('rel="canonical"');
  });
  test('the stylesheet name is the hash of its bytes', () => {
    const css = listing(a).find((f) => f.endsWith('.css')) as string;
    const { createHash } = require('crypto');
    const h = createHash('sha256').update(readFileSync(join(a, css))).digest('hex').slice(0, 12);
    expect(css).toBe(`assets/site.${h}.css`);
  });
});
