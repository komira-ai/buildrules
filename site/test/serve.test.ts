import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

// eslint-disable-next-line @typescript-eslint/no-var-requires
const serve = require('../serve.js');

describe('serve.js (the local preview)', () => {
  const root = mkdtempSync(join(tmpdir(), 'serve-'));
  const outside = mkdtempSync(join(tmpdir(), 'outside-'));
  mkdirSync(join(root, 'docs'));
  writeFileSync(join(root, 'index.html'), 'home');
  writeFileSync(join(root, 'docs', 'index.html'), 'docs');
  writeFileSync(join(root, '404.html'), 'nope');
  writeFileSync(join(root, 'a.css'), 'a{}');
  writeFileSync(join(outside, 'secret.txt'), 'secret');
  symlinkSync(join(outside, 'secret.txt'), join(root, 'link.txt'));

  const status = (u: string) => serve.route(root, u).status;
  test('serves files and directory indexes', () => {
    expect(status('/')).toBe(200);
    expect(status('/docs/')).toBe(200);
    expect(status('/a.css?x=1')).toBe(200);
    expect(serve.route(root, '/docs/').file).toBe(join(root, 'docs', 'index.html'));
  });
  test('a missing path is the 404 page with status 404', () => {
    expect(serve.route(root, '/missing/')).toEqual({ status: 404, file: join(root, '404.html') });
    expect(status('/docs')).toBe(404);
  });
  test.each(['/../secret.txt', '/%2e%2e/secret.txt', '/docs/../../x', '/%00', '/%zz', '//etc/passwd'])('never leaves the root: %s', (u) => {
    const r = serve.route(root, u);
    expect(r.status).toBe(404);
    expect(r.file).toBe(join(root, '404.html'));
  });
  test('a symlink inside the root does not lead out of it', () => {
    expect(status('/link.txt')).toBe(404);
  });
  test('content types', () => {
    expect(serve.TYPES['.html']).toContain('text/html');
    expect(serve.TYPES['.css']).toContain('text/css');
    expect(serve.TYPES['.svg']).toBe('image/svg+xml');
  });
});
