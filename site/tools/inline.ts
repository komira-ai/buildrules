// Inline text to HTML. The grammar is three things: `code`, [label](href) and everything else, which is escaped.
// An href is a path of this site (`/x/`, `/x/#id`, `#id`) or an https URL; anything else is an error at build time,
// so no page can carry a javascript: or data: link.

export function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

const HREF_SITE = /^(\/[a-z0-9/_-]*)?(#[a-z0-9-]+)?$/;
const HREF_HTTPS = /^https:\/\/[a-z0-9.-]+(\/[A-Za-z0-9._~\/%+-]*)?(#[A-Za-z0-9._-]+)?$/;

export function checkHref(href: string): string {
  if (href === '' || !(HREF_SITE.test(href) || HREF_HTTPS.test(href))) {
    throw new Error(`href '${href}' is neither a path of this site nor an https URL`);
  }
  return href;
}

export function inline(text: string): string {
  let out = '';
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === '`') {
      const end = text.indexOf('`', i + 1);
      if (end < 0) throw new Error(`unterminated code span in: ${text}`);
      out += `<code>${escapeHtml(text.slice(i + 1, end))}</code>`;
      i = end + 1;
    } else if (c === '[') {
      const close = text.indexOf('](', i + 1);
      const end = close < 0 ? -1 : text.indexOf(')', close + 2);
      if (close < 0 || end < 0) throw new Error(`unterminated link in: ${text}`);
      const label = text.slice(i + 1, close);
      if (label.includes('`') || label.includes('[')) throw new Error(`a link label is plain text: ${label}`);
      const href = checkHref(text.slice(close + 2, end));
      const external = href.startsWith('https://');
      out += `<a href="${escapeHtml(href)}"${external ? ' rel="noopener"' : ''}>${escapeHtml(label)}</a>`;
      i = end + 1;
    } else {
      let j = i;
      while (j < text.length && text[j] !== '`' && text[j] !== '[') j++;
      out += escapeHtml(text.slice(i, j));
      i = j;
    }
  }
  return out;
}

/** The text a heading or link label shows, without the inline syntax (for ids and the TOC). */
export function plain(text: string): string {
  return text.replace(/`([^`]*)`/g, '$1');
}

export function slug(text: string): string {
  return plain(text).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
}
