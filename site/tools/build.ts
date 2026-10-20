// Builds dist/: the prerendered pages, the stylesheet and icon (the stylesheet's name carries a hash of its bytes, so a
// URL never serves two contents), robots.txt and sitemap.xml. Then it checks the tree (check-dist.ts) and refuses to
// write anything if a check fails. The same inputs give the same bytes: no clock and no commit go into a page.
//
//   node build/tools/tools/build.js        from the site/ directory; reads static/, writes dist/

import { createHash } from 'crypto';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';
import { checkSite, fileOf, type Files } from './check-dist';
import { NAV, PAGES } from './pages';
import { renderNotFound, renderPage, SITE_URL, type Assets } from './render';

export const STYLESHEET = 'site.css';
export const ICON = 'icon.svg';

export function siteFiles(css: Buffer, icon: Buffer): Map<string, string | Buffer> {
  const hash = createHash('sha256').update(css).digest('hex').slice(0, 12);
  const assets: Assets = { css: `/assets/site.${hash}.css`, icon: '/assets/icon.svg' };
  const files = new Map<string, string | Buffer>();
  files.set(fileOf(assets.css), css);
  files.set(fileOf(assets.icon), icon);
  for (const page of PAGES) files.set(fileOf(page.path), renderPage(page, NAV, assets).html);
  files.set('404.html', renderNotFound(NAV, assets));
  files.set('robots.txt', `User-agent: *\nAllow: /\nSitemap: ${SITE_URL}/sitemap.xml\n`);
  files.set(
    'sitemap.xml',
    `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n` +
      PAGES.map((p) => `<url><loc>${SITE_URL}${p.path}</loc></url>\n`).join('') +
      `</urlset>\n`,
  );
  return files;
}

export function writeSite(files: Files, outDir: string): void {
  rmSync(outDir, { recursive: true, force: true });
  for (const [file, content] of files) {
    const path = join(outDir, file);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, content);
  }
}

export function buildSite(staticDir: string, outDir: string): string[] {
  const files = siteFiles(readFileSync(join(staticDir, STYLESHEET)), readFileSync(join(staticDir, ICON)));
  const problems = checkSite(files);
  if (problems.length > 0) return problems;
  writeSite(files, outDir);
  return [];
}

if (require.main === module) {
  const problems = buildSite('static', 'dist');
  if (problems.length > 0) {
    console.error(`site: ${problems.length} problem(s), dist/ not written:\n- ${problems.join('\n- ')}`);
    process.exit(1);
  }
  console.log(`site: wrote dist/ (${PAGES.length} pages)`);
}
