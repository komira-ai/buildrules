// The content model: a page is a title and a list of blocks. Text inside blocks is "inline text": plain text, `code`,
// and [label](href) links; nothing else (inline.ts). No block carries markup, so no page can contain HTML the renderer
// did not write.

export type Block =
  | { kind: 'h2'; text: string }
  | { kind: 'h3'; text: string }
  | { kind: 'p'; text: string }
  | { kind: 'ul'; items: string[] }
  | { kind: 'ol'; items: string[] }
  | { kind: 'code'; text: string; label?: string }
  | { kind: 'table'; head: string[]; rows: string[][] }
  | { kind: 'note'; tone: 'planned' | 'limit' | 'info'; text: string };

export interface Page {
  /** The URL path: `/` or `/name/` (always a directory). */
  path: string;
  /** The h1 and the title of the page. */
  title: string;
  /** The text of the nav entry; absent for pages the nav does not list. */
  nav?: string;
  /** One sentence for the meta description and the search-result snippet. */
  description: string;
  /** One paragraph under the h1. */
  lead: string;
  blocks: Block[];
}

export const h2 = (text: string): Block => ({ kind: 'h2', text });
export const h3 = (text: string): Block => ({ kind: 'h3', text });
export const p = (text: string): Block => ({ kind: 'p', text });
export const ul = (...items: string[]): Block => ({ kind: 'ul', items });
export const ol = (...items: string[]): Block => ({ kind: 'ol', items });
export const code = (text: string, label?: string): Block => ({ kind: 'code', text, label });
export const table = (head: string[], ...rows: string[][]): Block => ({ kind: 'table', head, rows });
export const planned = (text: string): Block => ({ kind: 'note', tone: 'planned', text });
export const limit = (text: string): Block => ({ kind: 'note', tone: 'limit', text });
export const info = (text: string): Block => ({ kind: 'note', tone: 'info', text });
