import { readFileSync } from 'fs';
import { join, resolve } from 'path';
import { ICON, siteFiles, STYLESHEET } from '../tools/build';

export const SITE_DIR = resolve(__dirname, '..');
/** The repository root: the tests read the rule sources and the contract at their paths there. */
export const REPO_DIR = resolve(SITE_DIR, '..');

export const repoFile = (rel: string): string => readFileSync(join(REPO_DIR, rel), 'utf8');

export function builtSite(): Map<string, string | Buffer> {
  return siteFiles(readFileSync(join(SITE_DIR, 'static', STYLESHEET)), readFileSync(join(SITE_DIR, 'static', ICON)));
}

export const html = (files: ReadonlyMap<string, string | Buffer>, file: string): string => {
  const v = files.get(file);
  if (v === undefined) throw new Error(`no ${file}`);
  return v.toString();
};

/** The visible text of a page: tags removed, entities decoded. */
export function textOf(page: string): string {
  return page
    .replace(/<[^>]*>/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ');
}
