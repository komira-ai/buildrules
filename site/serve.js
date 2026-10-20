// A static file server for previewing dist/ on your own machine: `buck2 run //site:preview`, or `node serve.js dist`.
// It serves files from one directory, answers a directory with its index.html, a missing path with 404.html and the
// status 404, and nothing outside the directory. It listens on 127.0.0.1 only. Serving is not a build.

'use strict';
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.xml': 'application/xml; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
};

/** The file a request path names inside `root`, or null if it escapes the root or is not a file. */
function resolve(root, urlPath) {
  let p;
  try {
    p = decodeURIComponent(urlPath.split('?')[0].split('#')[0]);
  } catch {
    return null;
  }
  if (p.includes('\0')) return null;
  if (p.endsWith('/')) p += 'index.html';
  const base = path.resolve(root);
  const file = path.resolve(base, '.' + p);
  if (file !== base && !file.startsWith(base + path.sep)) return null;
  try {
    // A symlink inside the root must not lead out of it.
    const real = fs.realpathSync(file);
    const realBase = fs.realpathSync(base);
    if (real !== realBase && !real.startsWith(realBase + path.sep)) return null;
    return fs.statSync(real).isFile() ? file : null;
  } catch {
    return null;
  }
}

/** { status, file } for a request path. */
function route(root, urlPath) {
  const file = resolve(root, urlPath);
  if (file !== null) return { status: 200, file };
  return { status: 404, file: resolve(root, '/404.html') };
}

function handler(root) {
  return (req, res) => {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405, { Allow: 'GET, HEAD' }).end();
      return;
    }
    const { status, file } = route(root, req.url || '/');
    if (file === null) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }).end('not found\n');
      return;
    }
    const type = TYPES[path.extname(file)] || 'application/octet-stream';
    res.writeHead(status, { 'Content-Type': type, 'X-Content-Type-Options': 'nosniff' });
    if (req.method === 'HEAD') res.end();
    else fs.createReadStream(file).pipe(res);
  };
}

module.exports = { resolve, route, handler, TYPES };

if (require.main === module) {
  const root = process.argv[2];
  const port = Number(process.argv[3] || 8080);
  if (!root || !fs.existsSync(path.join(root, 'index.html'))) {
    console.error('usage: node serve.js DIST_DIR [PORT]   (DIST_DIR must hold index.html)');
    process.exit(2);
  }
  http.createServer(handler(root)).listen(port, '127.0.0.1', () => {
    console.log(`serving ${root} at http://127.0.0.1:${port}/ (Ctrl-C to stop)`);
  });
}
