// The pages name commands, flags, exit codes and rules. These tests read the sources they describe (the Zig usage texts of
// the command line, the contract, the .bzl files of the rules) and fail when a page and its source disagree. They are
// the reason a rename or a removed flag cannot leave the documentation behind.

import { PAGES } from '../tools/pages';
import { slug } from '../tools/inline';
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

/** The text between `pub const usage_text =` and the closing `;`, as the program prints it. */
function usageText(zig: string): string {
  const start = zig.indexOf('pub const usage_text =');
  if (start < 0) throw new Error('no usage_text');
  const end = zig.indexOf('\n;', start);
  return zig
    .slice(start, end)
    .split('\n')
    .slice(1)
    .map((l) => l.replace(/^\s*\\\\/, ''))
    .join('\n');
}

describe('CLI page against the command line', () => {
  const cliText = pageText(page('/cli/'));
  const sources = ['init', 'cargo_cmd', 'sync', 'check', 'npm_cmd', 'mojo_cmd'].map((n) => usageText(repoFile(`cli/src/${n}.zig`)));
  const main = usageText(repoFile('cli/src/main.zig'));

  test('every command in the usage text has a section', () => {
    const commands = [...main.matchAll(/^ {2}([a-z]+) {2,}\S/gm)].map((m) => m[1]);
    expect(commands.sort()).toEqual(['cargo', 'check', 'init', 'mojo', 'npm', 'sync']);
    const headings = page('/cli/').blocks.filter((b) => b.kind === 'h2').map((b) => slug((b as { text: string }).text));
    for (const c of commands) expect(headings.some((h) => h === c || h.startsWith(`${c}-`))).toBe(true);
  });

  test('every flag of every command is documented', () => {
    // `--locked` and `--unit-graph` are mopm's flags, which the mojo usage text names; they are not flags of this program.
    const mopmFlags = ['--locked', '--unit-graph'];
    const flags = new Set(sources.flatMap((s) => [...s.matchAll(/--[a-z][a-z0-9-]*/g)].map((m) => m[0])).filter((f) => !mopmFlags.includes(f)));
    expect([...flags].sort()).toEqual(
      ['--accept-changed', '--buck2', '--cargo', '--cell', '--check', '--commit', '--dir', '--git', '--lib', '--mopm', '--path', '--pins', '--rust-version', '--rustc', '--seed', '--vcs'].sort(),
    );
    for (const f of flags) expect({ flag: f, documented: cliText.includes(f) }).toEqual({ flag: f, documented: true });
  });

  test('the page documents no flag the command line does not have', () => {
    const real = new Set(sources.flatMap((s) => [...s.matchAll(/--[a-z][a-z0-9-]*/g)].map((m) => m[0])));
    real.add('--help');
    real.add('--version');
    real.add('--show-output'); // buck2's, in the getting-started page only; not on the CLI page
    for (const f of cliText.matchAll(/--[a-z][a-z0-9-]*/g)) expect({ flag: f[0], known: real.has(f[0]) }).toEqual({ flag: f[0], known: true });
  });

  test('defaults on the page are the defaults in the usage text', () => {
    const initSrc = sources[0];
    expect(initSrc).toMatch(/default 1\.95\.0/);
    expect(cliText).toContain('default `1.95.0`');
    expect(initSrc).toMatch(/default root/);
    expect(cliText).toContain('default `root`');
    expect(sources[2]).toMatch(/default buck2/);
    expect(cliText).toContain('default `buck2`');
  });

  test('the version and the exit codes are the program\'s and the contract\'s', () => {
    const mainSrc = repoFile('cli/src/main.zig');
    expect(mainSrc).toContain('pub const version = @import("buildrules_version").release;');
    expect(mainSrc).not.toMatch(/pub const version = "/);
    expect(cliText).toContain('`buildrules --version` prints the release it was built as');
    expect(cliText).toContain('`-dev`');
    expect(main).toMatch(/Exit codes: 0 ok, 1 failed or stale, 2 usage/);
    expect(repoFile('docs/contract.md')).toMatch(/`0` ok; `1` failed, stale or refused[^]*`2` usage error/);
    for (const code of ['`0`', '`1`', '`2`']) expect(cliText).toContain(code);
  });

  test('the contract\'s check conditions are all listed', () => {
    const contract = repoFile('docs/contract.md');
    expect(contract).toContain('`check` exits 1 when any of these holds');
    // The page lists seven conditions; the contract names the same seven in one sentence.
    const list = page('/cli/').blocks.find((b) => b.kind === 'ul' && b.items[0].startsWith('`rust-toolchain.toml` is missing')) as { items: string[] };
    expect(list.items).toHaveLength(7);
    for (const needle of ['missing / floating / has `path`', '`CARGO_LOCK_SHA256`', '`buildrules.bzl` differs', 'no `cargo_workspace` call', 'no `cargo_package` call']) {
      expect(contract).toContain(needle);
    }
  });
});

describe('rule pages against the rule sources', () => {
  const read = (...f: string[]) => f.map(repoFile).join('\n');
  const sources: Record<string, string> = {
    '/rules/rust/': read('rules/rust/cargo.bzl'),
    '/rules/node/': read('rules/node/modules.bzl', 'rules/node/defs.bzl', 'rules/node/npm.bzl'),
    '/rules/zig/': read('rules/zig/zig.bzl'),
    '/rules/cxx/': read('rules/cxx/defs.bzl', 'rules/cxx/archive.bzl'),
  };

  test.each(Object.keys(sources))('%s: every rule it names in the first table column or heading exists', (path) => {
    const p = page(path);
    const names = new Set<string>();
    for (const b of p.blocks) {
      if (b.kind === 'h2') for (const m of b.text.matchAll(/^`?([a-z][a-z_]+)`?$/g)) names.add(m[1]);
      if (b.kind === 'table') for (const row of b.rows) for (const m of row[0].matchAll(/`([a-z][a-z_]+)(?:\(|`)/g)) names.add(m[1]);
    }
    const known = [...names].filter((n) => n.includes('_') && !['cargo_new', 'node_modules'].includes(n));
    expect(known.length).toBeGreaterThan(2);
    for (const n of known) {
      const defined = new RegExp(`^(def )?${n}\\b|\\b${n} = |"${n}"`, 'm').test(sources[path]);
      expect({ rule: n, defined }).toEqual({ rule: n, defined: true });
    }
  });

  test('the rust macros take the arguments the page lists', () => {
    const src = sources['/rules/rust/'];
    expect(src).toMatch(/def cargo_package\(path = "\.", table = None, third_party = None, check = None, extra_srcs = \[\], refuse = fail\)/);
    expect(src).toMatch(/def cargo_workspace\(path = "\.", table = None\)/);
    const t = pageText(page('/rules/rust/'));
    expect(t).toContain('cargo_package(path = ".", table, third_party, check = None, extra_srcs = [], refuse = fail)');
    expect(t).toContain('cargo_workspace(path = ".", table)');
  });

  test('the node macros take the arguments the page lists', () => {
    const src = sources['/rules/node/'];
    const t = pageText(page('/rules/node/'));
    const sigs: [string, string][] = [
      ['_tsc_check', 'tsc_check(name, modules, srcs, data, project)'],
      ['_tsc_build', 'tsc_build(name, modules, srcs, data, project, out_dir)'],
      ['_jest_test', 'jest_test(name, modules, srcs, data, config, max_workers)'],
      ['_cdk_synth', 'cdk_synth(name, modules, srcs, app, data, context, env)'],
    ];
    for (const [fn, sig] of sigs) {
      const args = sig.slice(sig.indexOf('(') + 1, -1).split(', ');
      const params = new RegExp(`def ${fn}\\(([^)]*)\\)`).exec(src)![1].split(',').map((a) => a.trim().split(/[ =]/)[0]).filter((a) => !a.startsWith('*'));
      expect({ fn, params }).toEqual({ fn, params: args });
      expect(t).toContain(sig);
    }
    expect(src).toMatch(/def _npm_modules_macro\(name, lockfile, npm,/);
  });

  test('the toolchain pins the page states', () => {
    const rust = repoFile('rules/rust/pins.bzl');
    expect(rust).toContain('RUST_DEFAULT = "1.95.0"');
    expect(repoFile('rules/node/pins.bzl')).toContain('"version": "24.21.0"');
    const concepts = pageText(page('/concepts/'));
    expect(concepts).toContain('1.95.0');
    expect(concepts).toContain('24.21.0');
    expect(repoFile('docs/contract.md')).toContain('channel = "1.95.0"');
  });
});
