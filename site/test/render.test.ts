import { checkHref, escapeHtml, inline, slug } from '../tools/inline';
import type { Page } from '../tools/model';
import { renderPage } from '../tools/render';

const assets = { css: '/assets/site.abc.css', icon: '/assets/icon.svg' };
const page = (blocks: Page['blocks']): Page => ({ path: '/x/', title: 'T', description: 'D', lead: 'L', blocks });
const render = (blocks: Page['blocks']) => renderPage(page(blocks), [{ path: '/', label: 'Home' }], assets).html;

describe('inline text', () => {
  test('escapes everything that is not code or a link', () => {
    expect(inline('a <b> & "c" \'d\'')).toBe('a &lt;b&gt; &amp; &quot;c&quot; &#39;d&#39;');
  });
  test('code spans are escaped and keep brackets', () => {
    expect(inline('`[a] <x>`')).toBe('<code>[a] &lt;x&gt;</code>');
  });
  test('links to this site and to https URLs', () => {
    expect(inline('[a](/x/#y)')).toBe('<a href="/x/#y">a</a>');
    expect(inline('[a](https://example.org/p)')).toBe('<a href="https://example.org/p" rel="noopener">a</a>');
  });
  test.each(['javascript:alert(1)', 'data:text/html,x', 'http://example.org/', '//evil.example/x', '../x', 'x/y', '', '/x" onclick="y'])(
    'refuses the href %j',
    (h) => expect(() => checkHref(h)).toThrow(/href/),
  );
  test('refuses an unterminated code span or link', () => {
    expect(() => inline('`a')).toThrow(/unterminated/);
    expect(() => inline('[a](/x/')).toThrow(/unterminated/);
  });
  test('slug', () => {
    expect(slug('rust-toolchain.toml is required')).toBe('rust-toolchain-toml-is-required');
    expect(slug('`cargo_package`')).toBe('cargo-package');
  });
  test('escapeHtml leaves plain text alone', () => expect(escapeHtml('abc 123')).toBe('abc 123'));
});

describe('page rendering', () => {
  test('script-looking text in any block is inert', () => {
    const evil = '<script>alert(1)</script>';
    const out = render([
      { kind: 'h2', text: evil },
      { kind: 'p', text: evil },
      { kind: 'ul', items: [evil] },
      { kind: 'code', text: evil, label: evil },
      { kind: 'table', head: [evil], rows: [[evil]] },
      { kind: 'note', tone: 'info', text: evil },
    ]);
    expect(out).not.toMatch(/<script/i);
    expect(out).toContain('&lt;script&gt;');
  });
  test('headings get unique ids, repeated titles get a suffix', () => {
    const out = render([
      { kind: 'h2', text: 'Same' },
      { kind: 'h2', text: 'Same' },
    ]);
    expect(out).toContain('id="same"');
    expect(out).toContain('id="same-2"');
  });
  test('a table row of the wrong width is an error', () => {
    expect(() => render([{ kind: 'table', head: ['a', 'b'], rows: [['x']] }])).toThrow(/cells/);
  });
  test('tables are scrollable regions with a name, code blocks are focusable', () => {
    const out = render([
      { kind: 'h2', text: 'Rules' },
      { kind: 'table', head: ['a'], rows: [['x']] },
      { kind: 'code', text: 'x' },
    ]);
    expect(out).toContain('role="region" aria-label="Rules, table" tabindex="0"');
    expect(out).toContain('<pre tabindex="0">');
  });
  test('the current page is marked in the nav', () => {
    const out = renderPage(page([]), [{ path: '/x/', label: 'X' }, { path: '/y/', label: 'Y' }], assets).html;
    expect(out).toContain('<a href="/x/" aria-current="page">X</a>');
    expect(out).toContain('<a href="/y/">Y</a>');
  });
  test('a table of contents appears from three sections', () => {
    const three = render(['a', 'b', 'c'].map((t) => ({ kind: 'h2' as const, text: t })));
    const two = render(['a', 'b'].map((t) => ({ kind: 'h2' as const, text: t })));
    expect(three).toContain('class="toc"');
    expect(two).not.toContain('class="toc"');
  });
});
