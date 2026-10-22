// docs/pins.md repeats each pin's version, size and sha256 as prose. These tests read it and the pin tables it describes (rules/rust/pins.bzl,
// rules/pins/pins.bzl, rules/mopm/pins.bzl) and fail when a figure in the page is not the figure in the table: the heading of the mopm section, the
// size of a tarball, one digit of a sha256. Each rule is also run against planted text, so a check that cannot fail is caught here.

import { readdirSync } from 'fs';
import { join } from 'path';
import { REPO_DIR, repoFile } from './helpers';

interface Pin {
  size: string;
  sha256: string;
}

const MD = repoFile('docs/pins.md');
const RUST = repoFile('rules/rust/pins.bzl');
const PINS = repoFile('rules/pins/pins.bzl');
const MOPM = repoFile('rules/mopm/pins.bzl');

const HEX64 = /^[0-9a-f]{64}$/;

/** The components of one Rust version row of rules/rust/pins.bzl: `{rustc: {size, sha256}, ...}`. */
function rustRow(src: string, version: string): Record<string, Pin> {
  const row = new RegExp(`^ {4}"${version.replace(/\./g, '\\.')}": \\{\\n([^]*?)^ {4}\\},`, 'm').exec(src);
  if (!row) throw new Error(`no row for Rust ${version}`);
  const out: Record<string, Pin> = {};
  for (const m of row[1].matchAll(/"(\w+)": \{"sha256": "([0-9a-f]{64})", "size": (\d+)\}/g)) out[m[1]] = { size: m[3], sha256: m[2] };
  return out;
}

/** One entry of a table of `"key": {"url": ..., "sha256": ..., "size": ...}` rows (rules/pins/pins.bzl PINS, rules/mopm/pins.bzl MOPM_VERSIONS). */
function entry(src: string, key: string): Pin & { url: string } {
  const m = new RegExp(`^ {4}"${key.replace(/\./g, '\\.')}": \\{([^}]*)\\}`, 'm').exec(src);
  if (!m) throw new Error(`no entry ${key}`);
  const f = (k: string): string => (new RegExp(`"${k}": "?([^",\\n]+)`).exec(m[1]) as RegExpExecArray)[1];
  return { url: f('url'), sha256: f('sha256'), size: f('size') };
}

const one = (src: string, re: RegExp): string => (re.exec(src) as RegExpExecArray)[1];

/** What the page says that the tables do not say: one string per disagreement. */
export function disagreements(md: string, rust: string, pins: string, mopm: string): string[] {
  const bad: string[] = [];
  const dflt = one(rust, /RUST_DEFAULT = "([^"]+)"/);
  const oldest = one(rust, /RUST_OLDEST = "([^"]+)"/);
  const triple = one(rust, /RUST_TRIPLE = "([^"]+)"/);
  const same = (what: string, doc: string, src: string): void => {
    if (doc !== src) bad.push(`${what}: page has ${doc}, table has ${src}`);
  };
  const short = (what: string, doc: { size: string; head: string; tail: string }, src: Pin): void => {
    same(`${what} size`, doc.size, src.size);
    if (!(src.sha256.startsWith(doc.head) && src.sha256.endsWith(doc.tail))) bad.push(`${what} sha256: page has ${doc.head}...${doc.tail}, table has ${src.sha256}`);
  };

  // The table of the default Rust, zig 0.15.2 and busybox: every row, with its version, file, size and sha256.
  const rows = md
    .split('\n')
    .map((l) => l.split('|').slice(1, -1).map((c) => c.trim()))
    .filter((c) => c.length === 4 && /^\d+$/.test(c[2]));
  const rustRows = rust.length ? rustRow(rust, dflt) : {};
  const wantRows: Record<string, { file: string | null; pin: Pin }> = {
    rustc: { file: `rustc-${dflt}-${triple}.tar.gz`, pin: rustRows.rustc },
    'rust-std': { file: `rust-std-${dflt}-${triple}.tar.gz`, pin: rustRows.rust_std },
    cargo: { file: `cargo-${dflt}-${triple}.tar.gz`, pin: rustRows.cargo },
    'zig 0.15.2': { file: 'zig-x86_64-linux-0.15.2.tar.xz', pin: entry(pins, 'zig_next') },
    'busybox 1.35.0': { file: null, pin: entry(pins, 'busybox') },
  };
  for (const [name, want] of Object.entries(wantRows)) {
    const got = rows.filter((c) => c[0] === name);
    if (got.length !== 1) {
      bad.push(`pins table: ${got.length} rows for ${name}, want 1`);
      continue;
    }
    if (want.file !== null) same(`${name} file`, got[0][1], want.file);
    same(`${name} size`, got[0][2], want.pin.size);
    same(`${name} sha256`, got[0][3], want.pin.sha256);
  }
  for (const c of rows) if (!(c[0] in wantRows)) bad.push(`pins table: row ${c[0]} is not compared with any table`);

  // The prose about the oldest Rust and llvm-tools.
  const old = rustRow(rust, oldest);
  const shortForm = '(\\d+) `([0-9a-f]{8})\\.\\.\\.([0-9a-f]{4})`';
  for (const [role, word] of [['rustc', 'rustc'], ['rust_std', 'rust-std'], ['cargo', 'cargo'], ['clippy', 'clippy']] as const) {
    const m = new RegExp(`${word} ${shortForm.replace(" `", "\\s+`")}`).exec(md.slice(md.indexOf(`The oldest`)));
    if (!m) bad.push(`oldest Rust ${word}: not in the page`);
    else short(`Rust ${oldest} ${word}`, { size: m[1], head: m[2], tail: m[3] }, old[role]);
  }
  const llvm = new RegExp(`llvm-tools-preview ${dflt.replace(/\./g, '\\.')}[^]*?${shortForm.replace(' `', ' bytes, `')}`).exec(md);
  if (!llvm) bad.push('llvm-tools: not in the page');
  else short(`Rust ${dflt} llvm-tools`, { size: llvm[1], head: llvm[2], tail: llvm[3] }, rustRow(rust, dflt).llvm_tools);

  // The mopm section: its heading, the version in every sentence, the tarball's name, its size and its sha256.
  const v = one(mopm, /MOPM_DEFAULT = "([^"]+)"/);
  const pin = entry(mopm, v);
  const sec = /^## mopm (\S+)\n([^]*?)(?=^## |$(?![^]))/m.exec(md);
  if (!sec) bad.push('no "## mopm <version>" section');
  else {
    same('mopm heading version', sec[1], v);
    for (const m of sec[2].matchAll(/\b0\.0\.\d+\b/g)) if (m[0] !== v) bad.push(`mopm section names ${m[0]}, the default is ${v}`);
    const t = /`(mopm-[^`]*-linux-x86_64\.tar\.gz)` is (\d+) bytes with sha256 `([^`]*)`/.exec(sec[2]);
    if (!t) bad.push('mopm section: no "<tarball> is N bytes with sha256 <digest>" sentence');
    else {
      same('mopm tarball', t[1], pin.url.split('/').pop() as string);
      same('mopm size', t[2], pin.size);
      same('mopm sha256', t[3], pin.sha256);
    }
    if (!sec[2].includes(`/releases/tag/v${v}`)) bad.push(`mopm section: no link to tag v${v}`);
  }
  return bad;
}

describe('docs/pins.md figures are the figures in the pin tables', () => {
  test('the real page agrees with the real tables', () => {
    expect(disagreements(MD, RUST, PINS, MOPM)).toEqual([]);
  });

  test('the tables are shaped the way the check reads them', () => {
    expect(HEX64.test(entry(MOPM, one(MOPM, /MOPM_DEFAULT = "([^"]+)"/)).sha256)).toBe(true);
    expect(HEX64.test(entry(PINS, 'zig_next').sha256)).toBe(true);
  });

  // Planted defects: each is a change to one figure of the page (or of a table) that the check must name.
  const planted = (what: string, from: string, to: string, want: RegExp, where: 'md' | 'mopm' = 'md'): void => {
    test(`planted: ${what}`, () => {
      const src = where === 'md' ? MD : MOPM;
      expect(src.split(from).length - 1).toBeGreaterThanOrEqual(1);
      const mutated = src.replace(from, to);
      const got = where === 'md' ? disagreements(mutated, RUST, PINS, MOPM) : disagreements(MD, RUST, PINS, mutated);
      expect(got.join('\n')).toMatch(want);
    });
  };
  const v = one(MOPM, /MOPM_DEFAULT = "([^"]+)"/);
  const mp = entry(MOPM, v);
  planted('the mopm heading names the previous release', `## mopm ${v}`, '## mopm 0.0.14', /mopm heading version/);
  planted('the mopm size is one more', `is ${mp.size} bytes`, `is ${Number(mp.size) + 1} bytes`, /mopm size/);
  planted('one digit of the mopm sha256 differs', mp.sha256, mp.sha256.slice(0, 20) + (mp.sha256[20] === '0' ? '1' : '0') + mp.sha256.slice(21), /mopm sha256/);
  const rs = rustRow(RUST, one(RUST, /RUST_DEFAULT = "([^"]+)"/));
  planted('the rustc size is one more', `| ${rs.rustc.size} |`, `| ${Number(rs.rustc.size) + 1} |`, /rustc size/);
  planted('the rust-std size is one more', `| ${rs.rust_std.size} |`, `| ${Number(rs.rust_std.size) + 1} |`, /rust-std size/);
  planted('one digit of the cargo sha256 differs', rs.cargo.sha256, rs.cargo.sha256.slice(0, 5) + (rs.cargo.sha256[5] === '0' ? '1' : '0') + rs.cargo.sha256.slice(6), /cargo sha256/);
  planted('the zig size is one more', '| 53733924 |', '| 53733925 |', /zig 0\.15\.2 size/);
  planted('the busybox sha256 differs', '| 6e123e7f3202', '| 7e123e7f3202', /busybox 1\.35\.0 sha256/);
  planted('the oldest rustc size is one more', 'rustc 118068031', 'rustc 118068032', /Rust 1\.85\.0 rustc size/);
  planted('the oldest cargo sha prefix differs', '`e27ffcaf...c372`', '`e27ffcae...c372`', /Rust 1\.85\.0 cargo sha256/);
  planted('the llvm-tools size is one more', '66089964 bytes', '66089965 bytes', /llvm-tools size/);
  planted('a new row nothing compares', '| busybox 1.35.0 |', '| newpin 1.0 | f | 1 | ab |\n| busybox 1.35.0 |', /row newpin 1\.0 is not compared/);
  planted('a row is deleted','| zig 0.15.2 | zig-x86_64-linux-0.15.2.tar.xz | 53733924 | 02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239 |\n', '', /0 rows for zig 0\.15\.2/);
});

// A digest copied into prose goes stale when the pin moves. Pages other than docs/pins.md (which the tests above compare row by row) point at the
// pin table instead; where a page does quote a digest, in full or as `head...tail`, it must be one a pin table holds, and a line about mopm must
// quote mopm's.
const PIN_TABLES = [RUST, PINS, MOPM, repoFile('rules/node/pins.bzl')];
const PINNED = new Set(PIN_TABLES.flatMap((t) => t.match(/\b[0-9a-f]{64}\b/g) ?? []));

/** The digests a page quotes that no pin table holds, and the digests on mopm lines that are not mopm's. */
export function strayDigests(md: string, pinned: ReadonlySet<string>, mopmDigest: string): string[] {
  const bad: string[] = [];
  const held = [...pinned];
  md.split('\n').forEach((line, i) => {
    if (line.includes('(not used)')) return; // the page says so of artifacts no table pins (the .tar.xz variants of the Rust components)
    const quoted: { text: string; ok: (d: string) => boolean }[] = [];
    for (const m of line.matchAll(/\b[0-9a-f]{64}\b/g)) quoted.push({ text: m[0], ok: (d) => d === m[0] });
    for (const m of line.matchAll(/\b([0-9a-f]{8})\.\.\.([0-9a-f]{4,5})\b/g)) quoted.push({ text: m[0], ok: (d) => d.startsWith(m[1]) && d.endsWith(m[2]) });
    for (const q of quoted) {
      if (!held.some(q.ok)) bad.push(`line ${i + 1}: ${q.text} is in no pin table`);
      else if (/\bmopm\b/i.test(line) && !q.ok(mopmDigest)) bad.push(`line ${i + 1}: ${q.text} is on a mopm line and is not mopm's pin`);
    }
  });
  return bad;
}

describe('pages quote no digest that a pin table does not hold', () => {
  const mopmDigest = entry(MOPM, one(MOPM, /MOPM_DEFAULT = "([^"]+)"/)).sha256;
  const pages = ['README.md', ...readdirSync(join(REPO_DIR, 'docs')).filter((f) => f.endsWith('.md')).map((f) => `docs/${f}`)];

  test('there are pages to read, among them the contract', () => {
    expect(pages).toContain('docs/contract.md');
    expect(pages).toContain('docs/pins.md');
  });

  for (const p of pages) {
    test(`${p} quotes only pinned digests`, () => {
      expect(strayDigests(repoFile(p), PINNED, mopmDigest)).toEqual([]);
    });
  }

  test('the contract section on the mopm pin names the table and quotes no digest', () => {
    const sec = /### 12\.5 [^\n]*\n([^]*?)(?=\n### |$(?![^]))/.exec(repoFile('docs/contract.md'));
    expect(sec).not.toBeNull();
    expect(sec![1]).toContain('rules/mopm/pins.bzl');
    expect(sec![1]).not.toMatch(/[0-9a-f]{8}\.\.\.|[0-9a-f]{64}/);
  });

  test('a stale mopm digest in prose is named', () => {
    const old = 'sha256 80ac2ed4...23dc, checked against the release\'s `SHA256SUMS`';
    expect(strayDigests(`the mopm tarball, ${old}`, PINNED, mopmDigest).join('\n')).toMatch(/80ac2ed4\.\.\.23dc is in no pin table/);
  });

  test('another pin\'s digest on a mopm line is named', () => {
    const zig = entry(PINS, 'zig_next').sha256;
    expect(strayDigests(`the mopm tarball has sha256 ${zig}`, PINNED, mopmDigest).join('\n')).toMatch(/is on a mopm line/);
  });

  test('the pinned mopm digest, in full or abbreviated, passes on a mopm line', () => {
    const d = mopmDigest;
    expect(strayDigests(`mopm sha256 ${d}\nmopm ${d.slice(0, 8)}...${d.slice(-4)}`, PINNED, mopmDigest)).toEqual([]);
  });
});
