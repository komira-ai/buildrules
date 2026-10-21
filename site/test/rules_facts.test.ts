// What the rule pages say about rules, versions, CPU levels, the CI matrix, Mojo and npm, compared with the sources.
// facts.test.ts covers the command line and the first-column rule names; this file covers the arguments of rules, the
// version tables and the targets. A claim is checked against the file that makes it true, not against another page.

import { PAGES } from '../tools/pages';
import type { Block, Page } from '../tools/model';
import { repoFile } from './helpers';

const page = (path: string): Page => PAGES.find((p) => p.path === path) as Page;

function blockTexts(b: Block): string[] {
  switch (b.kind) {
    case 'h2':
    case 'h3':
    case 'p':
    case 'note':
    case 'code':
      return [b.text];
    case 'ul':
    case 'ol':
      return b.items;
    case 'table':
      return [...b.head, ...b.rows.flat()];
  }
}
const pageText = (p: Page): string => [p.lead, ...p.blocks.flatMap(blockTexts)].join('\n');
const allText = (): string => PAGES.map(pageText).join('\n');
const squash = (s: string): string => s.replace(/\s+/g, ' ');
const unticked = (s: string): string => s.replace(/`/g, '');

/** Every `code span` in the prose and the tables of every page. */
function spans(): string[] {
  const out: string[] = [];
  for (const p of PAGES) {
    for (const b of [{ kind: 'p', text: p.lead } as Block, ...p.blocks]) {
      if (b.kind === 'code') {
        if (b.label === 'signature') out.push(b.text);
        continue;
      }
      for (const t of blockTexts(b)) for (const m of t.matchAll(/`([^`]+)`/g)) out.push(m[1]);
    }
  }
  return out;
}

// ---- reading Starlark -------------------------------------------------------------------------------------------

const SOURCES = [
  'rules/rust/cargo.bzl',
  'rules/rust/toolchain.bzl',
  'rules/node/modules.bzl',
  'rules/node/defs.bzl',
  'rules/node/npm.bzl',
  'rules/zig/zig.bzl',
  'rules/cxx/defs.bzl',
  'rules/cxx/archive.bzl',
  'rules/mojo/defs.bzl',
  'rules/mopm/toolchain.bzl',
  'rules/isa.bzl',
  'rules/matrix.bzl',
];
const src = SOURCES.map(repoFile).join('\n');

/** Split `a, b = [1, 2], c` at the commas that are not inside brackets or quotes. */
function splitTop(s: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let quote = '';
  let cur = '';
  for (const ch of s) {
    if (quote) {
      if (ch === quote) quote = '';
    } else if (ch === '"' || ch === "'") quote = ch;
    else if ('([{'.includes(ch)) depth++;
    else if (')]}'.includes(ch)) depth--;
    if (ch === ',' && depth === 0 && !quote) {
      out.push(cur);
      cur = '';
    } else cur += ch;
  }
  if (cur.trim()) out.push(cur);
  return out.map((a) => a.trim()).filter((a) => a !== '');
}

const argName = (a: string): string => /^[*]*([A-Za-z_][A-Za-z0-9_]*)/.exec(a)![1];

/** The attributes of the `rule(...)` assigned to `var`: the keys of its `attrs` dict. */
function ruleAttrs(var_: string): string[] | undefined {
  const start = new RegExp(`^${var_} = (?:_on_linux\\()?rule\\(`, 'm').exec(src);
  if (!start) return undefined;
  const rest = src.slice(start.index);
  const end = rest.search(/\n\)/);
  return [...rest.slice(0, end < 0 ? rest.length : end).matchAll(/"([a-z_][a-z_0-9]*)": attrs\./g)].map((m) => m[1]);
}

const ALL_ATTRS = new Set([...src.matchAll(/"([a-z][a-z_0-9]*)": attrs\./g)].map((m) => m[1]));
const GENERIC = ['name', 'visibility', 'exec_compatible_with', 'target_compatible_with', 'labels', 'tests'];

/** The arguments `name` takes, from the `def` or `rule` it resolves to; undefined if the sources do not define it. */
function paramsOf(name: string, seen: string[] = []): string[] | undefined {
  if (seen.includes(name)) return undefined;
  const def = new RegExp(`^def ${name}\\(([^)]*)\\)`, 'm').exec(src);
  if (def) {
    const args = splitTop(def[1]);
    const names = args.filter((a) => !a.startsWith('*')).map(argName);
    return args.some((a) => a.startsWith('**')) ? [...names, ...GENERIC, ...ALL_ATTRS] : names;
  }
  const alias = new RegExp(`^${name} = (?:_on_linux\\()?([A-Za-z_][A-Za-z0-9_]*)\\)?\\s*$`, 'm').exec(src);
  if (alias) return paramsOf(alias[1], [...seen, name]);
  for (const v of [name, `_${name}`, `${name}_rule`, `_${name}_rule`]) {
    const a = ruleAttrs(v);
    if (a) return [...a, ...GENERIC];
  }
  const own = new RegExp(`^_${name}\\b`, 'm').test(src);
  return own ? paramsOf(`_${name}`, [...seen, name]) : undefined;
}

// ---- rule arguments ---------------------------------------------------------------------------------------------

describe('rule arguments on the pages are the arguments the rules take', () => {
  const calls = spans()
    .map((s) => /^([a-z][a-z_0-9]*)\((.*)\)$/s.exec(s))
    .filter((m): m is RegExpExecArray => m !== null)
    .map((m) => ({ name: m[1], args: splitTop(m[2]).map(argName), text: m[0] }));
  const known = calls.filter((c) => paramsOf(c.name) !== undefined);

  test('the pages show the calls of at least the rules that matter', () => {
    const names = new Set(known.map((c) => c.name));
    for (const n of ['cargo_package', 'cargo_workspace', 'npm_package', 'mojo_package', 'npm_modules', 'tsc_check', 'node_tree_build', 'rust_toolchains']) {
      expect({ rule: n, shown: names.has(n) }).toEqual({ rule: n, shown: true });
    }
  });

  test.each([...new Set(known.map((c) => c.text))])('%s', (text) => {
    const c = known.find((k) => k.text === text)!;
    const params = paramsOf(c.name)!;
    for (const a of c.args) expect({ call: c.text, arg: a, taken: params.includes(a) }).toEqual({ call: c.text, arg: a, taken: true });
  });

  test('every argument of the front-door macros is documented on the page of its family', () => {
    const doc: [string, string][] = [
      ['cargo_package', '/rules/rust/'],
      ['cargo_workspace', '/rules/rust/'],
      ['npm_package', '/rules/node/'],
      ['mojo_package', '/rules/mojo/'],
    ];
    for (const [rule, path] of doc) {
      const t = pageText(page(path));
      for (const a of paramsOf(rule)!) expect({ rule, arg: a, documented: new RegExp(`\\b${a}\\b`).test(t) }).toEqual({ rule, arg: a, documented: true });
    }
  });

  test('the Argument table of cargo_package lists only its arguments', () => {
    const t = page('/rules/rust/').blocks.find((b) => b.kind === 'table' && b.head[0] === 'Argument') as { rows: string[][] };
    const params = paramsOf('cargo_package')!;
    expect(t.rows.length).toBeGreaterThan(3);
    for (const r of t.rows) expect({ arg: unticked(r[0]), taken: params.includes(unticked(r[0])) }).toEqual({ arg: unticked(r[0]), taken: true });
  });

  test('the Key arguments column of the Zig table lists attributes the rules have', () => {
    const t = page('/rules/zig/').blocks.find((b) => b.kind === 'table' && b.head[1] === 'Key arguments') as { rows: string[][] };
    for (const r of t.rows) {
      const rule = unticked(r[0]);
      const params = paramsOf(rule);
      expect({ rule, defined: params !== undefined }).toEqual({ rule, defined: true });
      for (const m of r[1].matchAll(/`([a-z_]+)`/g)) expect({ rule, arg: m[1], taken: params!.includes(m[1]) }).toEqual({ rule, arg: m[1], taken: true });
    }
  });

  test('the hand-written Rust rules take the arguments the prose lists', () => {
    const t = pageText(page('/rules/rust/'));
    const sentence = /`rust_library`, `rust_binary` and `rust_test` take ([^.]*)\./.exec(t)![1];
    const rs = repoFile('rules/rust/rust.bzl');
    for (const lib of ['rust_library', 'rust_binary', 'rust_test']) expect({ lib, defined: new RegExp(`^_${lib} = rule\\(`, 'm').test(rs) }).toEqual({ lib, defined: true });
    const listed = [...sentence.matchAll(/`([a-z_]+)`/g)].map((m) => m[1]);
    expect(listed).toEqual(['srcs', 'crate_root', 'crate_name', 'edition', 'deps', 'rustc_flags']);
    for (const a of listed) expect({ arg: a, taken: new RegExp(`"${a}": attrs\\.`).test(rs) }).toEqual({ arg: a, taken: true });
    const gate = /A library or binary can list `(\w+)`/.exec(t)![1];
    expect(rs).toMatch(new RegExp(`_rust_library = rule\\([^]*?${gate} = attrs\\.`));
    expect(rs).toMatch(new RegExp(`_rust_binary = rule\\([^]*?${gate} = attrs\\.`));
  });
});

// ---- Rust versions ----------------------------------------------------------------------------------------------

describe('the Rust version table on the pages is the table in pins.bzl', () => {
  const pins = repoFile('rules/rust/pins.bzl');
  const versions = [...pins.matchAll(/^ {4}"(\d+\.\d+\.\d+)": \{/gm)].map((m) => m[1]);
  const dflt = /RUST_DEFAULT = "([^"]+)"/.exec(pins)![1];
  const oldest = /RUST_OLDEST = "([^"]+)"/.exec(pins)![1];
  const vname = (v: string): string => v.replace(/\./g, '_');
  const rust = pageText(page('/rules/rust/'));

  test('the table has the versions the claims need', () => {
    expect(versions.length).toBeGreaterThanOrEqual(2);
    expect(versions).toContain(dflt);
    expect(versions).toContain(oldest);
  });

  test('every pinned version is a row of the Rust page, with its role', () => {
    const t = page('/rules/rust/').blocks.find((b) => b.kind === 'table' && b.head[0] === 'Version') as { rows: string[][] };
    expect(t.rows.map((r) => unticked(r[0])).sort()).toEqual([...versions].sort());
    for (const r of t.rows) {
      const v = unticked(r[0]);
      if (v === dflt) expect(r[1]).toContain('default');
      else if (v === oldest) expect(r[1]).toContain('oldest');
      else expect(r[1]).not.toMatch(/default|oldest/);
    }
  });

  test('the other pages name the same versions', () => {
    const concepts = pageText(page('/concepts/'));
    const faq = pageText(page('/faq/'));
    for (const v of versions) {
      expect({ v, concepts: concepts.includes(v) }).toEqual({ v, concepts: true });
      expect({ v, faq: faq.includes(v) }).toEqual({ v, faq: true });
    }
    expect(concepts).toContain(`${dflt} (the default)`);
    expect(concepts).toContain(`${oldest} (the oldest supported)`);
  });

  test('no page names a Rust release that is not pinned as if it were', () => {
    // Releases that appear as the example of a user pin (docs/contract.md section 6) are allowed; every other `N.N.N` in
    // backticks on the Rust, Concepts, FAQ and Getting started pages must be pinned.
    const example = /\[rust\."(\d+\.\d+\.\d+)"\]/.exec(repoFile('docs/contract.md'))![1];
    const text = ['/rules/rust/', '/concepts/', '/faq/', '/getting-started/'].map((p) => pageText(page(p))).join('\n');
    for (const m of text.matchAll(/`(\d+\.\d+\.\d+)`/g)) {
      expect({ v: m[1], pinned: versions.includes(m[1]) || m[1] === example }).toEqual({ v: m[1], pinned: true });
    }
  });

  test('the toolchain targets named on the page are the ones rust_toolchains declares', () => {
    const tc = repoFile('rules/rust/toolchain.bzl');
    for (const role of ['sysroot', 'cargo', 'clippy']) {
      expect(tc).toContain(`name = "${role}_" + n`);
      expect(rust).toContain(`:${role}_${vname(oldest)}`);
    }
    expect(tc).toMatch(/rust_toolchain\(\s*name = "rust_" \+ n/);
    expect(rust).toContain(`toolchains//:rust_${vname(oldest)}`);
    expect(repoFile('docs/contract.md')).toContain(`buildrules//platforms:linux_x86_64_rust_${vname(oldest)}`);
    expect(rust).toContain(`buildrules//platforms:linux_x86_64_rust_${vname(oldest)}`);
  });

  test('a version of your own is described the way buildrules-pins.toml reads it', () => {
    const toml = repoFile('cli/src/pins_toml.zig');
    const comps = /pub const components = \[_\]\[\]const u8\{([^}]*)\}/.exec(toml)![1].match(/"([a-z-]+)"/g)!.map((s) => s.replace(/"/g, ''));
    expect(comps).toEqual(['rustc', 'rust-std', 'cargo', 'clippy']);
    for (const c of comps) expect({ c, shown: rust.includes(c) }).toEqual({ c, shown: true });
    expect(rust).toContain('[rust."1.86.0"]');
    expect(rust).not.toContain('date = "');
    expect(rust).toContain('sha256 = "');
    expect(rust).toContain('size = ');
    expect(repoFile('rules/rust/toolchain.bzl')).toContain('rust_toolchains(extra = {})');
    expect(rust).toContain('rust_toolchains(extra = EXTRA_RUST_VERSIONS)');
  });

  test('the override keys on the Rust page are the keys the generator reads', () => {
    const keys = /const override_keys = \[_\]\[\]const u8\{([^}]*)\}/.exec(repoFile('cli/src/buckgen.zig'))![1].match(/"([a-z_]+)"/g)!.map((s) => s.replace(/"/g, ''));
    expect(keys.sort()).toEqual(['cfgs', 'drop_build_script', 'native_deps', 'patch', 'why']);
    for (const k of keys) expect({ k, shown: rust.includes(k) }).toEqual({ k, shown: true });
    expect(repoFile('cli/src/buckgen.zig')).toContain('third_party/buildrules/overrides.json');
    expect(rust).toContain('third_party/buildrules/overrides.json');
  });

  test('the Rust page claims no shipped example of an override', () => {
    // The unit tests of the generator exercise the override keys; no example in the repository has an overrides.json.
    expect(rust).toContain('no shipped example uses `drop_build_script` or `native_deps`');
    expect(allText()).not.toMatch(/aws-lc-sys/);
  });
});

// ---- CPU levels -------------------------------------------------------------------------------------------------

describe('the CPU level tables are the table in isa.bzl', () => {
  const isa = repoFile('rules/isa.bzl');
  const levels = [...isa.matchAll(/^ {4}"([^"]+)": \{"id": "(\w+)", "family": "(\w+)", "property": "([^"]+)", "rustc": \[([^\]]*)\], "zig": "([^"]+)"/gm)].map((m) => ({
    level: m[1],
    id: m[2],
    family: m[3],
    property: m[4],
    rustc: (m[5].match(/"([^"]+)"/g) ?? []).map((s) => s.replace(/"/g, '')).join(' '),
    zig: m[6],
  }));
  const rules = page('/rules/');
  const levelTable = rules.blocks.find((b) => b.kind === 'table' && b.head[0] === 'Level') as { rows: string[][] };

  test('isa.bzl is read: x86-64 v1 to v4 and Arm v8.0 to v8.4', () => {
    expect(levels.map((l) => l.level)).toEqual(['x86-64-v1', 'x86-64-v2', 'x86-64-v3', 'x86-64-v4', 'armv8.0-a', 'armv8.1-a', 'armv8.2-a', 'armv8.3-a', 'armv8.4-a']);
  });

  test('each level is a row, with its ISA property, its rustc flags and its zig flag', () => {
    expect(levelTable.rows).toHaveLength(levels.length);
    levels.forEach((l, i) => {
      const r = levelTable.rows[i].map(unticked);
      expect(r.slice(0, 4)).toEqual([l.level, l.property, l.rustc, l.zig]);
    });
  });

  test('only the x86-64 levels are marked built; the Arm levels are planned', () => {
    levels.forEach((l, i) => expect({ level: l.level, status: levelTable.rows[i][4] }).toEqual({ level: l.level, status: l.family === 'x86_64' ? 'built' : 'planned' }));
    const platforms = rules.blocks.find((b) => b.kind === 'table' && b.head[0] === 'Platform') as { rows: string[][] };
    const arm = platforms.rows.find((r) => r[0].includes('armv8'))!;
    expect(arm[1]).toMatch(/^planned/);
    expect(isa).toContain('Arm has none');
  });

  test('the execution platforms the page describes are the levels isa.bzl registers', () => {
    expect(isa).toMatch(/def test_levels\(\):[^]*?l != "x86-64-v1"/);
    expect(isa).toMatch(/def exec_levels\(\):[^]*?\["family"\] == "x86_64"/);
    const withPlatform = levels.filter((l) => l.family === 'x86_64' && l.level !== 'x86-64-v1').map((l) => l.level);
    expect(withPlatform).toEqual(['x86-64-v2', 'x86-64-v3', 'x86-64-v4']);
    const t = pageText(rules);
    expect(t).toContain('one such platform for each of v2, v3 and v4; v1 needs none');
    expect(pageText(page('/remote-execution/'))).toContain('`x86-64-v2`, `x86-64-v3` and `x86-64-v4`');
  });

  test('pages that discuss where actions run name the local mode that docs/contract.md section 14 defines', () => {
    expect(repoFile('docs/contract.md')).toContain('`-c buildrules_re.mode=local`');
    for (const path of ['/', '/faq/', '/remote-execution/', '/getting-started/']) {
      expect({ path, names: pageText(page(path)).includes('buildrules_re.mode=local') }).toEqual({ path, names: true });
    }
    for (const path of ['/', '/remote-execution/', '/getting-started/']) {
      expect(pageText(page(path))).not.toMatch(/Remote only|only on a remote execution farm/);
    }
  });

  test('the test run is a separate target with the exec requirement, and the refusal says what the page quotes', () => {
    expect(isa).toContain('def test_exec_compatible_with()');
    expect(repoFile('rules/rust/test_run.bzl')).toContain('built for ISA {} but its execution platform reports ISA={}');
    expect(pageText(rules)).toContain('built for ISA x86-64-v3 but its execution platform reports ISA=x86-64');
    expect(pageText(rules)).toContain('exec_compatible_with = test_exec_compatible_with()');
  });

  test('native is never passed, and no level flag is native', () => {
    for (const l of levels) expect(`${l.rustc} ${l.zig}`).not.toContain('native');
    expect(pageText(rules)).toContain('`native` is never passed');
  });
});

// ---- the CI matrix ----------------------------------------------------------------------------------------------

describe('the CI matrix on the Rules page is ci/BUCK', () => {
  const buck = repoFile('ci/BUCK');
  const defined = [...buck.matchAll(/^(?:group|rust_at|isa_at)\(\s*name = "(\w+)"/gm)].map((m) => m[1]);
  const matrixDeps = [...(/group\(name = "matrix", deps = \[([^\]]*)\]/.exec(buck)![1].matchAll(/":(\w+)"/g))].map((m) => m[1]);
  const table = page('/rules/').blocks.find((b) => b.kind === 'table' && b.head[0] === 'Target') as { rows: string[][] };
  const shown = [...table.rows.map((r) => r[0]).join(' ').matchAll(/`\/\/ci:(\w+)`/g)].map((m) => m[1]);

  test('every target the page names exists in ci/BUCK', () => {
    expect(shown.length).toBeGreaterThan(5);
    for (const t of shown) expect({ target: t, defined: defined.includes(t) }).toEqual({ target: t, defined: true });
  });

  test('every cell of //ci:matrix is on the page, and the page has no cell the matrix lacks', () => {
    expect(matrixDeps.length).toBeGreaterThan(5);
    for (const t of matrixDeps) expect({ cell: t, shown: shown.includes(t) }).toEqual({ cell: t, shown: true });
    for (const t of shown.filter((s) => s !== 'matrix')) expect({ cell: t, inMatrix: matrixDeps.includes(t) }).toEqual({ cell: t, inMatrix: true });
  });

  test('the Mojo cell is stated to be outside the matrix, as it is', () => {
    expect(defined).toContain('mojo');
    expect(matrixDeps).not.toContain('mojo');
    expect(pageText(page('/rules/'))).toContain('It is not part of `//ci:matrix`');
  });

  test('the oldest-Rust and CPU-level cells use the transitions the page names', () => {
    expect(buck).toMatch(/rust_at\(name = "rust_oldest", version = RUST_OLDEST/);
    expect(buck).toMatch(/isa_at\(name = "isa_v3", level_id = "x86_64_v3"/);
    const m = repoFile('rules/matrix.bzl');
    expect(m).toContain('def rust_at(');
    expect(m).toContain('def isa_at(');
    const t = pageText(page('/rules/'));
    expect(t).toContain('(`rust_at`)');
    expect(t).toContain('(`isa_at`)');
  });

  test('the refusal cells are the refusals the page lists', () => {
    expect(buck).toContain('unpinned_builtin_is_refused');
    expect(buck).toContain('recorded_hashes_must_be_the_pinned_ones');
    expect(buck).toContain('pinned_version_with_user_origin_is_refused');
  });

  test('a Rust version in the table needs a line in matrix.bzl, as the page says', () => {
    expect(repoFile('rules/matrix.bzl')).toContain('rules/matrix.bzl has no transition for Rust');
    expect(pageText(page('/rules/'))).toContain('needs its line in `rules/matrix.bzl`');
  });
});

// ---- Mojo and mopm ----------------------------------------------------------------------------------------------

describe('the Mojo page against the Mojo rules, mopm\'s pins and the contract', () => {
  const mojo = pageText(page('/rules/mojo/'));
  const defs = repoFile('rules/mojo/defs.bzl');
  const mopm = repoFile('rules/mopm/pins.bzl');
  const contract = squash(repoFile('docs/contract.md'));

  test('every target in the table is a target mojo_package declares', () => {
    const t = page('/rules/mojo/').blocks.find((b) => b.kind === 'table' && b.head[0] === 'Target') as { rows: string[][] };
    const names = t.rows.map((r) => unticked(r[0]).replace(/^:/, ''));
    expect(names).toEqual(['lib', 'test', 'build', 'coverage', 'ci', 'check']);
    for (const n of names) expect({ target: n, declared: defs.includes(`name_once("${n}")`) }).toEqual({ target: n, declared: true });
    expect(defs).toContain('stem + "__bin"');
    expect(mojo).toContain(':<stem>__bin');
  });

  test('mopm-toolchain.toml has the keys the page writes, and mojo sync reads them', () => {
    const cmd = repoFile('cli/src/mojo_cmd.zig');
    expect(cmd).toContain('quotedValue(line, "mopm")');
    expect(cmd).toContain('quotedValue(line, "mojo")');
    expect(mojo).toContain('[toolchain]');
    expect(cmd).toContain('there is no default. Create it, for example');
    expect(cmd).toContain('[toolchain]\\nmopm = \\"0.0.15\\"');
    const dflt = /MOPM_DEFAULT = "([^"]+)"/.exec(mopm)![1];
    expect(mojo).toContain(`mopm = "${dflt}"`);
  });

  test('the mopm version table has the keys a user pin must give, and the page says the same', () => {
    const row = /MOPM_VERSIONS = \{[^]*?\n {4}\},/.exec(mopm)![0];
    for (const k of ['url', 'sha256', 'size']) expect(row).toContain(`"${k}"`);
    expect(mojo).toContain('`url`, `sha256` and `size`');
    expect(mojo).toContain('[mopm."0.0.2"]');
    expect(repoFile('cli/src/mojo_cmd.zig')).toContain('[mopm.\\"{s}\\"]');
    expect(repoFile('rules/mopm/toolchain.bzl')).toContain('name = "mopm_" + vname(v)');
    expect(mojo).toContain('toolchains//:mopm_<version>');
  });

  test('the pinned mopm is the published 0.0.15 release: its asset digest and size, no release_pending, and the page says released', () => {
    const row = /MOPM_VERSIONS = \{[^]*?\n {4}\},/.exec(mopm)![0];
    expect(row).toContain('"url": "https://github.com/komira-ai/mopm/releases/download/v0.0.15/mopm-0.0.15-linux-x86_64.tar.gz"');
    expect(row).toContain('"sha256": "5f021430b118cc217124ebb2dd43146614204a1835730b2597d4bbdff1d62b50"');
    expect(row).toContain('"size": 980650');
    expect(row).toContain('"dir": "mopm-0.0.15-linux-x86_64"');
    expect(mopm).not.toContain('release_pending');
    expect(mojo).toContain('mopm 0.0.15 is released and pinned');
    expect(mojo).not.toContain('stand-in');
    expect(mojo).not.toContain('release is pending');
    expect(mojo).toContain('`url_map`');
  });

  test('one Mojo version is pinned, and the page says so', () => {
    const one = /mopm pins one \(`(\d+\.\d+\.\d+)`\)/.exec(contract)![1];
    expect(mojo).toContain(`mopm pins one Mojo today (${one})`);
    expect(mojo).toContain(`mojo = "${one}"`);
    expect(contract).toContain('so no package here builds for two Mojo versions');
  });

  test('the checks the page lists are the checks the contract lists', () => {
    for (const f of ['mopm.toml', 'mopm.lock', 'mopm-toolchain.toml', 'toolchains/mojo_pins.bzl']) {
      expect({ f, page: mojo.includes(f), contract: contract.includes(f) }).toEqual({ f, page: true, contract: true });
    }
    expect(defs).toContain('mojo_group(name = name_once("ci"), deps = [":build", ":test"]');
  });
});

// ---- npm_package ------------------------------------------------------------------------------------------------

describe('the npm_package front door and the renamed rule', () => {
  const npm = repoFile('rules/node/npm.bzl');
  const defs = repoFile('rules/node/defs.bzl');
  const node = pageText(page('/rules/node/'));

  test('npm_package is the front door in npm.bzl; the single-tarball rule is npm_tarball in defs.bzl', () => {
    expect(npm).toMatch(/^def npm_package\(/m);
    expect(defs).toMatch(/^npm_tarball = /m);
    expect(defs).not.toMatch(/npm_package/);
    expect(node).toContain('`npm_tarball`');
    expect(node).toContain('This is the rule that `npm_package` used to be called');
  });

  test('the steps are the steps npm.bzl declares', () => {
    const steps = /_STEPS = \[([^\]]*)\]/.exec(npm)![1].match(/"([a-z]+)"/g)!.map((s) => s.replace(/"/g, ''));
    expect(steps).toEqual(['typecheck', 'lint', 'test', 'build']);
    for (const s of steps) expect({ s, shown: node.includes(`\`:${s}\``) }).toEqual({ s, shown: true });
  });

  test('the policy keys are the ones npm.bzl reads', () => {
    for (const k of ['steps', 'actions', 'dist']) {
      expect({ k, read: npm.includes(`policy.get("${k}")`) || npm.includes(`"${k}"`) }).toEqual({ k, read: true });
      expect({ k, shown: node.includes(`\`${k}\``) }).toEqual({ k, shown: true });
    }
  });

  test('the table targets exist', () => {
    for (const t of ['node_modules', 'check', 'dist']) expect({ t, declared: npm.includes(`name = "${t}"`) }).toEqual({ t, declared: true });
    expect(node).toContain('`:node_modules`');
    expect(node).toContain('`:check`');
    expect(node).toContain('`:dist`');
  });

  test('the generated glue the page shows is the glue the command writes', () => {
    const cmd = repoFile('cli/src/npm_cmd.zig');
    expect(cmd).toContain('def npm_package(**kwargs):');
    expect(cmd).toContain('_npm_package(table = TABLE, **kwargs)');
    expect(node).toContain('load(":buildrules.bzl", "npm_package")');
  });
});

// ---- the C/C++ page ---------------------------------------------------------------------------------------------

describe('the AWS-LC example on the C/C++ page', () => {
  const buck = repoFile('third_party/aws-lc/BUCK');
  const cxx = pageText(page('/rules/cxx/'));

  test('the three gates it names are rules the library uses', () => {
    for (const rule of ['prefixed_archive_check', 'c_check', 'glibc_floor_check']) {
      expect({ rule, used: new RegExp(`^${rule}\\(`, 'm').test(buck) }).toEqual({ rule, used: true });
    }
    expect(cxx).toContain('Three gates must pass');
    expect(cxx).toContain('`crypto[static-pic]`');
    expect(buck).toContain('static-pic');
  });
});

// ---- what the command-line examples run -------------------------------------------------------------------------

describe('every `buildrules` command in a code block is a verb the program has, with flags it has', () => {
  const usage = (n: string): string => {
    const zig = repoFile(`cli/src/${n}.zig`);
    const start = zig.indexOf('pub const usage_text =');
    return zig.slice(start, zig.indexOf('\n;', start));
  };
  const byVerb: Record<string, string> = {
    init: usage('init'),
    cargo: usage('cargo_cmd'),
    sync: usage('sync'),
    check: usage('check'),
    npm: usage('npm_cmd'),
    mojo: usage('mojo_cmd'),
    autopin: usage('autopin'),
  };
  const lines: { line: string; verb: string; sub: string; flags: string[] }[] = [];
  for (const p of PAGES) {
    for (const b of p.blocks) {
      if (b.kind !== 'code') continue;
      for (const l of b.text.split('\n')) {
        const m = /^buildrules\s+(.*)$/.exec(l.trim());
        if (!m) continue;
        const words = m[1].split(/\s+/);
        if (!/^[a-z]+$/.test(words[0])) continue;
        const sub = ['cargo', 'npm', 'mojo', 'autopin'].includes(words[0]) && /^[a-z]+$/.test(words[1] ?? '') ? words[1] : '';
        lines.push({ line: l.trim(), verb: words[0], sub, flags: [...l.matchAll(/\s(--[a-z][a-z0-9-]*)/g)].map((f) => f[1]) });
      }
    }
  }

  test('the pages show commands of every verb', () => {
    expect([...new Set(lines.map((l) => l.verb))].sort()).toEqual(['autopin', 'cargo', 'check', 'init', 'mojo', 'npm', 'sync']);
    expect(lines.some((l) => l.verb === 'npm' && l.sub === 'sync')).toBe(true);
    expect(lines.some((l) => l.verb === 'mojo' && l.sub === 'check')).toBe(true);
  });

  test.each([...new Set(lines.map((l) => l.line))])('%s', (line) => {
    const l = lines.find((x) => x.line === line)!;
    const text = byVerb[l.verb];
    expect({ line, verb: l.verb, known: text !== undefined }).toEqual({ line, verb: l.verb, known: true });
    if (l.sub) expect({ line, sub: l.sub, known: text.includes(`buildrules ${l.verb} ${l.sub}`) }).toEqual({ line, sub: l.sub, known: true });
    for (const f of l.flags) expect({ line, flag: f, known: text.includes(f) }).toEqual({ line, flag: f, known: true });
  });
});

// ---- Zig versions -----------------------------------------------------------------------------------------------

describe('the Zig releases the Concepts page names are pinned', () => {
  test('0.12.0 and 0.15.2', () => {
    const pins = repoFile('rules/pins/pins.bzl');
    const cell = pageText(page('/concepts/')).split('\n').find((l) => l.startsWith('pinned releases, '))!;
    for (const v of /pinned releases, (\d+\.\d+\.\d+) and (\d+\.\d+\.\d+)/.exec(cell)!.slice(1)) {
      expect({ v, pinned: pins.includes(`zig-x86_64-linux-${v}`) || pins.includes(`zig-linux-x86_64-${v}`) }).toEqual({ v, pinned: true });
    }
  });
});

describe('the Releases section against RELEASING.md, the release tool and the release workflow', () => {
  const rulesText = pageText(page('/rules/'));
  const releasing = repoFile('RELEASING.md');
  const workflow = repoFile('.github/workflows/release.yml');
  const cmds = repoFile('tools/release/cmds.zig');
  const versionZig = repoFile('tools/release/version.zig');

  test('MAJOR.MINOR is the VERSION file, and a tag is v<MAJOR>.<MINOR>.<PATCH>', () => {
    expect(repoFile('VERSION')).toMatch(/^\d+\.\d+\n$/);
    expect(rulesText).toContain('`MAJOR.MINOR` is the `VERSION` file');
    expect(rulesText).toContain('`vMAJOR.MINOR.PATCH`');
    expect(releasing).toContain('v<MAJOR>.<MINOR>.<PATCH>');
    // the tool's rule: a leading v and three numbers
    expect(versionZig).toContain("name[0] != 'v'");
    expect(versionZig).toContain('const patch = number(body[d2 + 1 ..])');
  });

  test('the files a release holds are the ones the tool writes', () => {
    expect(cmds).toContain('"buildrules-{s}.tar.gz"');
    expect(cmds).toContain('pub const sums_name = "SHA256SUMS"');
    expect(rulesText).toContain('`buildrules-<version>.tar.gz`');
    expect(rulesText).toContain('`SHA256SUMS`');
    expect(workflow).toContain('actions/attest-build-provenance@');
    expect(rulesText).toContain('build provenance attestation');
  });

  test('every push to main, no human action, with the command line: the workflow, RELEASING.md and the page agree', () => {
    // a push to main releases; a pull request does not run this workflow at all (it runs ci.yml: build and unit tests); nothing else triggers it
    expect(workflow).toMatch(/\non:\n {2}push:\n {4}branches: \[main\]\n\npermissions: \{\}\n/);
    expect(workflow).not.toMatch(/\n {2}pull_request:/);
    expect(workflow).not.toMatch(/\n {2}(workflow_dispatch|schedule|workflow_run|pull_request_target):/);
    expect(squash(releasing)).toContain('released with no human action');
    expect(rulesText).toContain('Every push to `main` is built and tested');
    expect(rulesText).toContain('with no human action');
    // the release carries the command line for three platforms, and says which were run by a user beta
    for (const target of ['linux-x86_64', 'linux-aarch64', 'macos-arm64']) {
      expect(rulesText).toContain(target);
      expect(releasing).toContain(target);
    }
    expect(rulesText).toContain('`buildrules-cli-<version>-<target>.tar.gz`');
    expect(releasing).toContain('buildrules-cli-<version>-<target>.tar.gz');
    expect(releasing).not.toContain('There are no binaries');
    expect(rulesText).not.toContain('There are no binaries');
  });

  test('the page points at RELEASING.md, which exists and says how to pin', () => {
    expect(rulesText).toContain('https://github.com/komira-ai/buildrules/blob/main/RELEASING.md');
    expect(releasing).toContain('## Pinning a release');
    expect(releasing).toContain('sha256sum --check SHA256SUMS');
  });

  test('no page says that nothing is released, or that releases are only planned', () => {
    expect(allText()).not.toMatch(/nothing is released|Nothing is released|Published releases are planned|no release binaries yet/);
  });
});

describe('the stages of the release: the page, RELEASING.md, beta.yml and release.yml agree', () => {
  const rulesText = pageText(page('/rules/'));
  const releasing = repoFile('RELEASING.md');
  const release = repoFile('.github/workflows/release.yml');
  const beta = repoFile('.github/workflows/beta.yml');
  const checkZig = repoFile('beta/check.zig');

  test('the order is gate -> plan -> build-cli -> beta -> gamma -> archive -> attest -> verify -> tag -> publish, in the workflow and in RELEASING.md', () => {
    expect(release).toMatch(/\n {2}plan:\n {4}needs: \[gate, tool\]\n/);
    expect(release).toMatch(/\n {2}build-cli:\n {4}needs: \[plan, tool\]\n/);
    expect(release).toMatch(/\n {2}beta:\n {4}needs: \[plan, build-cli\]\n/);
    expect(release).toMatch(/\n {2}gamma:\n {4}needs: \[plan, beta, tool\]\n/);
    expect(release).toMatch(/\n {2}archive:\n {4}needs: \[plan, build-cli, beta, gamma, tool\]\n/);
    expect(release).toMatch(/\n {2}attest:\n {4}needs: \[plan, archive, tool\]\n/);
    expect(release).toMatch(/\n {2}verify:\n {4}needs: \[plan, attest, tool\]\n/);
    expect(release).toMatch(/\n {2}tag:\n {4}needs: \[plan, verify, tool\]\n/);
    expect(release).toMatch(/\n {2}publish:\n {4}needs: \[plan, tag, verify, tool\]\n/);
    expect(squash(releasing)).toContain('The order is `gate`, `plan`, `build-cli`, `beta`, `gamma`, `archive`, `attest`, `verify`, `tag`, `publish`');
    expect(squash(releasing)).toContain('leaves no tag behind');
  });

  test('the languages of the beta stage are the beta directories, the beta matrix, RELEASING.md and the page', () => {
    const dirs = /expected_langs = \[_\]\[\]const u8\{([^}]*)\}/.exec(checkZig)![1].match(/"([a-z]+)"/g)!.map((s) => s.replace(/"/g, ''));
    const matrix = /\n {2}beta:[\s\S]*?lang: \[([^\]]*)\]/.exec(beta)![1].split(',').map((s) => s.trim());
    expect([...matrix, 'mojo'].sort()).toEqual([...dirs].sort());
    for (const lang of dirs) expect(releasing).toContain('| `' + lang + '` |');
    expect(rulesText).toContain('hello-world repositories (Rust, C and C++, Zig, Node, and one that mixes them)');
  });

  test('arm and macos run natively up to the build, and say they do not build; the Mojo leg runs', () => {
    expect(beta).toMatch(/\n {2}beta_mojo:\n/);
    expect(beta).toContain('runs-on: ubuntu-24.04-arm');
    expect(beta).toContain('runs-on: macos-14');
    // no job of beta.yml is skipped any more, and the two native ones say in their names that they do not build
    expect(beta).not.toContain("github.event_name == 'planned'");
    expect(beta.match(/native, no build yet/g)!.length).toBe(2);
    expect(releasing).toContain('**No build**');
    expect(rulesText).toContain('The Mojo leg builds a Mojo package with the pinned mopm 0.0.15 release, the same way, and two native legs run the command line the release ships for Arm Linux and for macOS');
    expect(rulesText).toContain('They do not build, because no toolchain of the rules runs on those hosts yet.');
    expect(rulesText).not.toContain("Mojo leg is planned");
    // the Mojo leg is not waiting for anything: no pending pin, no planned-until line, and RELEASING.md lists it as running
    expect(repoFile('rules/mopm/pins.bzl')).not.toContain('release_pending');
    expect(repoFile('beta/mojo/STEPS')).not.toContain('planned-until');
    expect(releasing).toMatch(/\| `mojo` \|[^\n]*\| ubuntu x86_64 \|/);
  });

  test('every repository variable the workflows read is documented in RELEASING.md, and every documented one is read', () => {
    const used = new Set<string>();
    for (const wf of [release, beta]) for (const m of wf.matchAll(/vars\.([A-Z][A-Z0-9_]+)/g)) used.add(m[1]);
    const section = releasing.slice(releasing.indexOf('## The gamma stage'), releasing.indexOf('## The release page'));
    const documented = new Set<string>();
    for (const line of section.split('\n')) {
      if (!line.startsWith('| `')) continue;
      for (const m of line.split('|')[1].matchAll(/`([A-Z][A-Z0-9_]+)`/g)) documented.add(m[1]);
    }
    expect([...used].sort()).toEqual([...documented].sort());
  });

  test('gamma fails without a farm, and says so in the workflow, the tool and RELEASING.md', () => {
    expect(squash(releasing)).toContain('**With no farm configured gamma fails**');
    expect(release).toContain('tool/stage gamma-vars ');
    expect(repoFile('tools/stage/gamma.zig')).toContain('the farm is not configured, so our own repositories were not built with this candidate. A release is not made without it.');
    const gammaJob = release.slice(release.indexOf('\n  gamma:\n'), release.indexOf('\n  archive:\n'));
    expect(gammaJob).toContain('tool/stage gamma ');
    // it runs for every commit the plan released and for no narrower condition (a farm variable in it would let an unconfigured farm pass)
    expect(gammaJob).toMatch(/\n {4}if: \$\{\{ needs\.plan\.outputs\.released == 'true' \}\}\n/);
    expect(gammaJob.match(/\n {4}if:/g)!.length).toBe(1);
  });

  test('the release page is made by the site job from the verified files and is only an artifact', () => {
    expect(release).toMatch(/\n {2}site:\n/);
    expect(release).toContain('tool/release site ');
    expect(release).toContain('name: release-site');
    expect(squash(releasing)).toContain('The workflow `site` (see "The site") uploads it with the rest of the site.');
    expect(rulesText).toContain('Each release also gets a page with the tag, the commit to pin, the archive URL and its sha256.');
    // the page holds what RELEASING.md says it holds
    const page_zig = repoFile('tools/release/page.zig');
    for (const w of ['commit_hash', 'sha256sum --check SHA256SUMS', 'gh attestation verify']) expect(page_zig).toContain(w);
  });
});
