// The Why and How pages (and docs/why.md, docs/how.md, which they repeat) state facts about pins, gates, platforms, the release pipeline
// and what is planned. These tests read the sources those facts come from and fail when a page and its source disagree. A claim that is
// conditional on the repository (the mopm pin being a stand-in) is tested in both states, so the pages cannot go stale when the pin moves.

import { PAGES } from '../tools/pages';
import type { Block, Page } from '../tools/model';
import { repoFile } from './helpers';

const page = (path: string): Page => PAGES.find((p) => p.path === path) as Page;

function blockTexts(b: Block): string[] {
  switch (b.kind) {
    case 'h2':
    case 'h3':
    case 'p':
    case 'code':
      return [b.text];
    case 'note':
      // the tone is what marks a note as planned or a limit; keep it in the text this file searches
      return [`(${b.tone}) ${b.text}`];
    case 'ul':
    case 'ol':
      return b.items;
    case 'table':
      return [...b.head, ...b.rows.flat()];
  }
}
const pageText = (p: Page): string => [p.lead, ...p.blocks.flatMap(blockTexts)].join('\n');
const plannedText = (p: Page): string =>
  p.blocks
    .filter((b): b is Extract<Block, { kind: 'note' }> => b.kind === 'note' && b.tone === 'planned')
    .map((b) => b.text)
    .join('\n');

/** The first planned note of a page: the one at the top that lists everything not built. */
const firstPlanned = (p: Page): string => (p.blocks.find((b) => b.kind === 'note' && b.tone === 'planned') as Extract<Block, { kind: 'note' }>).text;

/** The usage function of the install script: from `usage() {` to the closing brace at the start of a line. */
const usageOf = (sh: string): string => {
  const start = sh.indexOf('usage() {');
  return sh.slice(start, sh.indexOf('\n}\n', start));
};

const WHY = page('/why/');
const HOW = [page('/how/'), page('/how/configure/'), page('/how/examples/')];
const WHY_MD = repoFile('docs/why.md');
const HOW_MD = repoFile('docs/how.md');
const howText = HOW.map(pageText).join('\n');
const whyText = pageText(WHY);
/** Every text that states facts: the two pages' sets and the two documents. */
const ALL: [string, string][] = [
  ['the Why page', whyText],
  ['the How pages', howText],
  ['docs/why.md', WHY_MD],
  ['docs/how.md', HOW_MD],
];

describe('the Why and How pages exist and are linked', () => {
  test('the paths, titles and nav entries', () => {
    expect(WHY.nav).toBe('Why');
    expect(HOW[0].nav).toBe('How');
    // the two sub pages are reached from /how/ and are not in the nav
    expect(HOW[1].nav).toBeUndefined();
    expect(HOW[2].nav).toBeUndefined();
    const howLinks = pageText(HOW[0]);
    expect(howLinks).toContain('(/how/configure/)');
    expect(howLinks).toContain('(/how/examples/)');
    expect(howLinks).toContain('(/why/)');
    expect(whyText).toContain('(/how/)');
  });
  test('the documents point at each other', () => {
    expect(WHY_MD).toContain('[how.md](how.md)');
    expect(HOW_MD).toContain('[why.md](why.md)');
  });
});

describe('pins stated in the pages are the pins in the sources', () => {
  const rust = repoFile('rules/rust/pins.bzl');
  const pins = repoFile('rules/pins/pins.bzl');
  const node = repoFile('rules/node/pins.bzl');
  test('Rust', () => {
    expect(rust).toContain('RUST_DEFAULT = "1.95.0"');
    expect(rust).toContain('RUST_OLDEST = "1.85.0"');
    for (const [who, t] of ALL) expect({ who, has: t.includes('1.95.0') && t.includes('1.85.0') }).toEqual({ who, has: true });
    // the How texts say which is the default and which the oldest; the sentence is checked as a whole, so swapping or changing either is caught
    for (const [who, t] of ALL.filter(([w]) => /how/i.test(w))) {
      expect({ who, has: t.replace(/\s+/g, ' ').includes('buildrules pins `1.95.0` (the default) and `1.85.0` (the oldest') }).toEqual({ who, has: true });
    }
  });
  test('Zig, busybox and the conda libraries', () => {
    expect(pins).toContain('zig-linux-x86_64-0.12.0.tar.xz');
    expect(pins).toContain('zig-x86_64-linux-0.15.2.tar.xz');
    expect(pins).toContain('1.35.0-x86_64-linux-musl/busybox');
    expect(pins).toContain('libgcc_15.3.0_linux-64.conda');
    expect(pins).toContain('libstdcxx_15.3.0_linux-64.conda');
    for (const [who, t] of ALL.filter(([w]) => /why/i.test(w))) {
      for (const v of ['0.12.0', '0.15.2', '1.35.0', '15.3.0']) expect({ who, v, has: t.includes(v) }).toEqual({ who, v, has: true });
    }
  });
  test('Node.js', () => {
    expect(node).toContain('"version": "24.21.0"');
    expect(node).toContain('node-v24.21.0-linux-x64');
    for (const [who, t] of ALL.filter(([w]) => /why/i.test(w))) expect({ who, has: t.includes('24.21.0') }).toEqual({ who, has: true });
  });
  test('kcov and AWS-LC', () => {
    expect(repoFile('rules/coverage/pins.bzl')).toContain('kcov v42');
    expect(repoFile('third_party/aws-lc/BUCK')).toContain('aws/aws-lc 1.39.0');
    for (const [who, t] of ALL.filter(([w]) => /why/i.test(w))) {
      expect({ who, kcov: t.includes('kcov (v42') }).toEqual({ who, kcov: true });
      expect({ who, awslc: t.includes('AWS-LC 1.39.0') }).toEqual({ who, awslc: true });
    }
  });
  test('the How pages and docs/how.md state the default Zig, the second Zig and its target', () => {
    // the sentence is one claim; both texts repeat it, so a mutated version in either is caught here
    expect(pins).toContain('download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz');
    expect(pins).toContain('download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz');
    expect(repoFile('rules/pins/pins.bzl')).toMatch(/"zig": \{[^}]*0\.12\.0/);
    expect(repoFile('rules/pins/pins.bzl')).toMatch(/"zig_next": \{[^}]*0\.15\.2/);
    for (const [who, t] of ALL.filter(([w]) => /how/i.test(w))) {
      const flat = t.replace(/\s+/g, ' ');
      expect({ who, has: flat.includes('Zig 0.12.0 by default; for 0.15.2 add `zig = "buildrules//rules/pins:zig_next"` to both rules') }).toEqual({ who, has: true });
    }
  });
  test('every version a text states next to a pinned tool is a version the sources pin (or a named example of one that is not)', () => {
    const rustPins = [...rust.matchAll(/^(?:RUST_DEFAULT|RUST_OLDEST) = "([\d.]+)"/gm)].map((m) => m[1]);
    const tools: [string, RegExp, string[]][] = [
      ['Rust', /\b(?:Rust|rustc)\b/g, [...rustPins, '1.86.0']], // 1.86.0 is the page's example of a version that is not pinned
      ['Zig', /\bZig\b|\bzig\b/g, [...pins.matchAll(/download\/([\d.]+)\//g)].map((m) => m[1])],
      ['Node.js', /\bNode(?:\.js)?\b/g, [(/"version": "([\d.]+)"/.exec(node) as RegExpExecArray)[1]]],
      ['busybox', /\bbusybox\b/g, [(/busybox[^]*?([\d.]+)-x86_64-linux-musl/.exec(pins) as RegExpExecArray)[1]]],
      ['kcov', /\bkcov\b/g, []],
      ['mopm', /\bmopm\b/g, ['0.0.1', '0.0.2']], // 0.0.2 is the page's example of a version that is not pinned
    ];
    let seen = 0;
    for (const [who, t] of ALL) {
      const flat = t.replace(/\s+/g, ' ');
      for (const [tool, name, allowed] of tools) {
        for (const m of flat.matchAll(name)) {
          // the first dotted number within 60 characters after the name, when no other pinned tool's name comes first
          const after = flat.slice(m.index! + m[0].length, m.index! + m[0].length + 60);
          const v = /\b(\d+\.\d+\.\d+)\b/.exec(after);
          if (v === null) continue;
          if (/[A-Za-z]{3,}.*(?:Rust|rustc|Zig|zig|Node|busybox|kcov|mopm|Mojo)/.test(after.slice(0, v.index))) continue;
          seen++;
          expect({ who, tool, v: v[1], pinned: allowed.includes(v[1]) }).toEqual({ who, tool, v: v[1], pinned: true });
        }
      }
    }
    expect(seen).toBeGreaterThanOrEqual(12);
  });
  test('the pin files the pages name hold the tools the pages put in them', () => {
    // the table of the Why page: tool -> file
    for (const f of ['rules/rust/pins.bzl', 'rules/pins/pins.bzl', 'rules/node/pins.bzl', 'rules/mopm/pins.bzl']) {
      expect(whyText).toContain(`\`${f}\``);
      expect(repoFile(f).length).toBeGreaterThan(100);
    }
  });
});

describe('C and C++', () => {
  const tc = repoFile('rules/cxx/toolchain.bzl');
  const defs = repoFile('rules/cxx/defs.bzl') + repoFile('rules/cxx/archive.bzl');
  test('the glibc floor, the compile flag and the link flag', () => {
    expect(tc).toContain('target = "x86_64-linux-gnu.2.34"');
    expect(tc).toContain('"-g0"');
    expect(tc).toContain('-Wl,--strip-debug');
    for (const [who, t] of ALL.filter(([w]) => /why/i.test(w))) {
      for (const s of ['x86_64-linux-gnu.2.34', '-g0', '-Wl,--strip-debug']) expect({ who, s, has: t.includes(s) }).toEqual({ who, s, has: true });
    }
  });
  test('the three gates exist and the page names exactly those four', () => {
    const gates = ['hermetic_check', 'glibc_floor_check', 'prefixed_archive_check', 'c_check'];
    for (const g of gates) {
      expect({ g, defined: new RegExp(`^${g} = `, 'm').test(defs) }).toEqual({ g, defined: true });
      expect({ g, named: whyText.includes(`\`${g}\``) }).toEqual({ g, named: true });
    }
    const table = WHY.blocks.find((b) => b.kind === 'table' && b.head[0] === 'Gate') as Extract<Block, { kind: 'table' }>;
    expect(table.rows.map((r) => r[0].replace(/`/g, ''))).toEqual(gates);
  });
  test('the planted defects: the document lists as many as the pages say', () => {
    const rows = repoFile('docs/cxx_mutants.md').split('\n').filter((l) => /^\| \d+ \|/.test(l));
    expect(rows).toHaveLength(6);
    for (const [who, t] of ALL.filter(([w]) => /why/i.test(w))) expect({ who, six: t.includes('six planted defects') }).toEqual({ who, six: true });
  });
});

describe('instruction-set levels', () => {
  const isa = repoFile('rules/isa.bzl');
  test('the levels the pages name are the levels in the table, and only x86-64 has an execution platform', () => {
    const levels = [...isa.matchAll(/^ {4}"((?:x86-64-v\d)|(?:armv8\.\d-a))": \{/gm)].map((m) => m[1]);
    expect(levels).toEqual(['x86-64-v1', 'x86-64-v2', 'x86-64-v3', 'x86-64-v4', 'armv8.0-a', 'armv8.1-a', 'armv8.2-a', 'armv8.3-a', 'armv8.4-a']);
    expect(isa).toMatch(/return \[l for l in test_levels\(\) if ISA_LEVELS\[l\]\["family"\] == "x86_64"\]/);
    expect(whyText).toContain('x86-64-v1 to v4 and armv8.0-a to armv8.4-a');
    expect(howText).toContain('`x86-64-v1` to `v4`');
    expect(howText).toContain('`linux_armv8_0` to `linux_armv8_4`');
  });
  test('the Arm rows are marked planned or as data on every page that mentions them', () => {
    expect(plannedText(WHY)).toMatch(/Arm rows are data/);
    expect(plannedText(HOW[1])).toMatch(/Arm levels[^]*exist as data only/);
  });
});

describe('where actions run', () => {
  const plat = repoFile('rules/platforms.bzl');
  test('remote is the default, local is refused beside a farm, any other value is refused', () => {
    expect(plat).toContain('read_config("buildrules_re", "mode", "remote")');
    expect(plat).toContain('if mode not in ("remote", "local")');
    for (const key of ['engine_address', 'cas_address']) expect(plat).toContain(`"${key}"`);
    expect(plat).toContain('_refuse_local_beside_remote("linux_x86_64_properties")');
    expect(whyText).toContain('it is refused when a farm is also configured');
    expect(howText).toContain('Local mode is refused if an engine or CAS address or a worker property set is also configured');
    expect(howText).toContain('Any other value is refused');
    // the same sentences in the Markdown documents, whose lines wrap
    const flat = (t: string): string => t.replace(/\s+/g, ' ');
    expect(flat(WHY_MD)).toContain('It is refused when a farm is also configured');
    expect(flat(HOW_MD)).toContain('Local mode is refused if an engine or CAS address or a worker property set is also configured');
    expect(flat(HOW_MD)).toContain('Any other value is refused');
    expect(flat(HOW_MD)).toContain('`remote` (the default, also when unset) or `local`');
    expect(flat(howText)).toContain('`remote` (the default, also when unset) or `local`');
  });
  test('a host that is not linux x86_64 gets no ISA platform, with or without a host table', () => {
    // A tree may also hold platforms that local mode registers on another host (`host_platforms`); that host still gets no ISA platform,
    // because the texts say no execution platform carries an Arm level.
    expect(plat).toMatch(/def buildrules_execution_platforms\(name, linux_x86_64, isa_platforms = \{\}, (?:host_platforms = \{\}, )?visibility = None\):/);
    if (plat.includes('host_platforms')) expect(plat).toMatch(/local_platform = host_platforms\[host\]\n\s*isa_platforms = \{\}/);
    expect(repoFile('rules/isa.bzl')).toMatch(/ISA_LEVELS\[l\]\["family"\] == "x86_64"/);
    let seen = 0;
    for (const [who, t] of ALL) {
      const flat = t.replace(/\s+/g, ' ');
      if (!/there is no Arm worker/i.test(flat)) continue;
      seen++;
      expect({ who, carries: flat.includes('no execution platform that carries an Arm level') }).toEqual({ who, carries: true });
    }
    expect(seen).toBe(4);
  });
});

describe('the transitive-set claim is the narrow one the sources support', () => {
  test('only the Mojo rules are said to avoid them', () => {
    const providers = repoFile('rules/mojo/providers.bzl');
    expect(providers).toMatch(/Lists and dicts only, never a tset \(facebook\/buck2#683/);
    expect(whyText).toContain('The Mojo rules avoid transitive sets');
    expect(whyText).not.toContain('The rules avoid transitive sets');
    expect(WHY_MD).toContain('The Mojo rules avoid transitive sets');
    expect(WHY_MD).not.toContain('The rules avoid transitive sets');
  });
});

describe('init and the generated files', () => {
  const init = repoFile('cli/src/init.zig');
  const contract = repoFile('cli/src/contract.zig');
  test('every file the How page says init writes is written by init', () => {
    for (const f of ['.buckconfig', 'toolchains/BUCK', 'platforms/BUCK', '.buckconfig.local.example', 'rust-toolchain.toml', 'Cargo.toml', '.gitignore']) {
      expect({ f, init: init.includes(`"${f}"`) || init.includes(`${f} `) || init.includes(`${f}"`) }).toEqual({ f, init: true });
      expect({ f, page: pageText(HOW[0]).includes(`\`${f}\``) }).toEqual({ f, page: true });
    }
    expect(contract).toContain('rust_pins_file = "toolchains/rust_pins.bzl"');
    expect(pageText(HOW[0])).toContain('`toolchains/rust_pins.bzl`');
    expect(HOW_MD).toContain('`toolchains/rust_pins.bzl`');
    expect(contract).toContain('ignore_lines = [_][]const u8{ ".buckconfig.local", "buck-out/" }');
  });
  test('a pin is a full 40-digit commit, the Rust default is 1.95.0, the cell default is root', () => {
    expect(init).toContain('--commit SHA          ... pinned at this full 40-hex commit');
    expect(init).toContain('default 1.95.0');
    expect(init).toContain('default root');
    expect(init).toContain('a branch or tag is not a pin');
    expect(whyText).toContain('40 lower-case hex digits');
    expect(howText).toContain('default `root`');
    expect(howText).toContain('default `1.95.0`');
  });
  test('the policy init writes, and the policy keys the page lists', () => {
    expect(contract).toContain('resolver = \\"3\\"');
    expect(contract).toContain('incremental = false');
    expect(contract).toContain('policy_keys = [_][]const u8{ "default-action", "actions", "lint" }');
    expect(contract).toContain('lint_keys = [_][]const u8{"deny-warnings"}');
    expect(contract).toContain('steps = [_][]const u8{ "lint", "debug", "test", "release", "coverage" }');
    const t = pageText(HOW[1]);
    for (const k of ['`actions`', '`lint.deny-warnings`', '`default-action`', 'resolver = "3"', '`incremental = false`']) expect({ k, has: t.includes(k) }).toEqual({ k, has: true });
    expect(t).toContain('Steps are `lint`, `debug`, `test`, `release` and `coverage`');
  });
  test('the How pages name no flag that no command has', () => {
    const usage = (zig: string): string => {
      const start = zig.indexOf('pub const usage_text =');
      return zig.slice(start, zig.indexOf('\n;', start));
    };
    // the options of the install script (a program of its own, in site/static/install.sh), from its usage text
    const install = new Set([...usageOf(repoFile('site/static/install.sh')).matchAll(/--[a-z][a-z0-9-]*/g)].map((m) => m[0]));
    const real = new Set(
      ['init', 'cargo_cmd', 'sync', 'check', 'npm_cmd', 'mojo_cmd', 'main'].flatMap((n) => [...usage(repoFile(`cli/src/${n}.zig`)).matchAll(/--[a-z][a-z0-9-]*/g)].map((m) => m[0])),
    );
    // other programs' flags the pages mention: buck2, curl, gh, mopm, rustc, the linker
    const others = ['--ignore-missing', '--show-output', '--target-platforms', '--repo', '--unit-graph', '--locked', '--test', '--strip-debug', '--verify-tag', '--help', '--version'];
    for (const t of [howText, whyText]) {
      for (const m of t.matchAll(/(?<![A-Za-z0-9-])--[a-z][a-z0-9-]*/g)) {
        expect({ flag: m[0], known: real.has(m[0]) || install.has(m[0]) || others.includes(m[0]) }).toEqual({ flag: m[0], known: true });
      }
    }
    for (const f of ['--git', '--commit', '--path', '--cell', '--rust-version', '--cargo', '--seed', '--vcs']) expect({ f, real: real.has(f) }).toEqual({ f, real: true });
  });
});

describe('the release pipeline', () => {
  const release = repoFile('.github/workflows/release.yml');
  const releasing = repoFile('RELEASING.md');
  const stages = ['gate', 'plan', 'build-cli', 'beta', 'gamma', 'archive', 'attest', 'verify', 'tag', 'publish'];
  const jobBlock = (name: string): string => {
    const start = release.search(new RegExp(`^  ${name}:$`, 'm'));
    expect(start).toBeGreaterThanOrEqual(0);
    const rest = release.slice(start + 1);
    const next = rest.search(/^ {2}[a-z_-]+:$/m);
    return next < 0 ? rest : rest.slice(0, next);
  };
  test('the stages the Why page lists are the jobs of the workflow, in the order RELEASING.md gives', () => {
    for (const s of stages) expect(jobBlock(s)).toContain(`${s}:`);
    expect(releasing).toContain('The order is `gate`, `plan`, `build-cli`, `beta`, `gamma`, `archive`, `attest`, `verify`, `tag`, `publish`');
    const table = WHY.blocks.find((b) => b.kind === 'table' && b.head[0] === 'Stage') as Extract<Block, { kind: 'table' }>;
    expect(table.rows.map((r) => r[0])).toEqual([...stages, 'bump']);
  });
  test('the stage table of docs/why.md says what the Why page table says, row by row', () => {
    const norm = (s: string): string => s.replace(/\s+/g, ' ').trim();
    const md = WHY_MD.slice(WHY_MD.indexOf('## 8. Releases')).split('\n')
      .filter((l) => new RegExp(`^\\| (?:${[...stages, 'bump'].join('|')}) \\| `).test(l))
      .map((l) => {
        const cells = l.replace(/^\| /, '').replace(/ \|$/, '').split(' | ');
        return [norm(cells[0]), norm(cells.slice(1).join(' | '))];
      });
    const table = WHY.blocks.find((b) => b.kind === 'table' && b.head[0] === 'Stage') as Extract<Block, { kind: 'table' }>;
    expect(md).toEqual(table.rows.map((r) => [norm(r[0]), norm(r[1])]));
    expect(md).toHaveLength(11);
  });
  test('verify before tag: tag needs verify, nothing before tag needs tag, publish needs both', () => {
    expect(jobBlock('tag')).toMatch(/needs: \[[^\]]*\bverify\b[^\]]*\]/);
    expect(jobBlock('publish')).toMatch(/needs: \[[^\]]*\btag\b[^\]]*\bverify\b[^\]]*\]/);
    for (const s of ['gate', 'plan', 'build-cli', 'beta', 'gamma', 'archive', 'attest', 'verify']) expect({ s, needsTag: /needs: \[[^\]]*\btag\b/.test(jobBlock(s)) }).toEqual({ s, needsTag: false });
    expect(jobBlock('verify')).toMatch(/needs: \[[^\]]*\battest\b/);
    expect(jobBlock('attest')).toMatch(/needs: \[[^\]]*\barchive\b/);
    expect(jobBlock('archive')).toMatch(/needs: \[[^\]]*\bbuild-cli\b/);
    expect(jobBlock('build-cli')).toMatch(/needs: \[[^\]]*\bplan\b/);
    expect(whyText).toContain('Verify before tag. Nothing before `tag` waits for it');
  });
  test('tiers: a pull request runs ci.yml (build and unit tests) and nothing of the release; the beta, the gamma and the release run after the merge', () => {
    const ci = repoFile('.github/workflows/ci.yml');
    const beta = repoFile('.github/workflows/beta.yml');
    // neither the release nor the beta has a pull-request trigger, so no beta and no dry run of the release happens before a merge
    expect(release).not.toMatch(/\n {2}pull_request(_target)?:/);
    expect(beta).not.toMatch(/\n {2}pull_request(_target)?:/);
    expect(beta).toMatch(/\non:\n {2}workflow_call:/);
    // ci.yml is the pull-request check, and it calls neither the beta nor the stage tool nor the release tool
    expect(ci).toMatch(/\non:\n {2}pull_request:\n/);
    for (const later of ['workflows/beta.yml', 'tools/stage', 'tools/release', 'id-token', 'cosign']) expect({ later, inCi: ci.includes(later) }).toEqual({ later, inCi: false });
    // the release calls the beta, after the merge, and builds the gamma
    expect(jobBlock('beta')).toContain('uses: ./.github/workflows/beta.yml');
    expect(jobBlock('gamma')).toContain('tool/stage gamma ');
    // the pages say so, and name no dry run
    expect(releasing).toContain('## The tiers');
    expect(releasing).not.toMatch(/dry run of a pull request|attest-dry|verify-dry|The dry run/);
    for (const [name, text] of [['the Why page', whyText], ['docs/why.md', WHY_MD]] as [string, string][]) {
      expect({ name, tiers: text.includes('Three tiers') }).toEqual({ name, tiers: true });
      expect({ name, dry: /attest-dry|verify-dry|as a dry run/.test(text) }).toEqual({ name, dry: false });
    }
  });
  test('bump runs after publish and nothing waits for it', () => {
    expect(jobBlock('bump')).toMatch(/needs: \[[^\]]*\btag\b[^\]]*\bpublish\b/);
    for (const s of [...stages, 'tool', 'site']) expect({ s, needsBump: /needs: \[[^\]]*\bbump\b/.test(jobBlock(s)) }).toEqual({ s, needsBump: false });
    expect(whyText).toContain('nothing waits for it, and a failed bump un-releases nothing');
    expect(releasing).toContain('Nothing waits for it');
    // the page names the downstream repository by role only
    expect(whyText).not.toMatch(/internal/i);
  });
  test('the release holds a source archive, the command line for three platforms, sums, signatures and attestations', () => {
    expect(release).toContain('buildrules-cli-<version>-<target>.tar.gz');
    expect(releasing).toContain('buildrules-cli-<version>-<target>.tar.gz');
    expect(releasing).not.toContain('There are no binaries');
    for (const target of ['linux-x86_64', 'linux-aarch64', 'macos-arm64']) {
      expect({ target, why: whyText.includes(target) }).toEqual({ target, why: true });
      expect({ target, how: howText.includes(target) }).toEqual({ target, how: true });
    }
    // no program for an Intel Mac: the release names no such target on either page, and the tool lists exactly the three
    expect(whyText).not.toContain('macos-x86_64');
    expect(howText).not.toContain('macos-x86_64');
    expect(repoFile('tools/release/binhdr.zig')).toContain('pub const targets = [_][]const u8{ "linux-x86_64", "linux-aarch64", "macos-arm64" };');
    expect(whyText).toContain('buildrules-cli-<version>-<target>.tar.gz');
    const cmds = repoFile('tools/release/cmds.zig');
    expect(cmds).toContain('SHA256SUMS');
    expect(cmds).toContain('buildrules-{s}.tar.gz');
    expect(whyText).toContain('`buildrules-<version>.tar.gz`');
    expect(howText).toContain('buildrules-$v.tar.gz');
    expect(howText).toContain('gh attestation verify');
  });
  test('the static check the page cites exists and the version file has the shape the page says', () => {
    expect(releasing).toContain('ci/release_check.zig');
    expect(release).toContain('ci/release_check.zig');
    expect(repoFile('VERSION').trim()).toMatch(/^\d+\.\d+$/);
    expect(whyText).toContain('`MAJOR.MINOR` is the `VERSION` file');
  });
  test('the beta legs: the languages the page and RELEASING.md list, the Arm and macOS legs declared and skipped', () => {
    for (const leg of ['rust', 'cxx', 'zig', 'node', 'mixed']) expect(releasing).toContain(`| \`${leg}\` |`);
    const beta = repoFile('.github/workflows/beta.yml');
    for (const j of ['beta_arm', 'beta_macos']) {
      const start = beta.indexOf(`  ${j}:`);
      expect(start).toBeGreaterThan(0);
      expect(beta.slice(start, start + 120)).toContain("github.event_name == 'planned'");
    }
    expect(beta).toContain('runs-on: ubuntu-24.04-arm');
    expect(beta).toContain('runs-on: macos-14');
    expect(plannedText(WHY)).toMatch(/Arm and macOS legs and skips them/);
  });
});

describe('what is planned is marked planned', () => {
  const needles: [string, RegExp][] = [
    ['Arm', /Arm/],
    ['macOS', /macOS/],
    ['a Homebrew formula', /Homebrew formula/],
    ['an apt repository', /apt repository/],
  ];
  test.each(needles)('the Why page has a planned note for %s', (_n, re) => {
    expect(plannedText(WHY)).toMatch(re);
  });
  test.each(needles.filter(([n]) => n !== 'Arm' && n !== 'macOS'))('the first How page has a planned note for %s', (_n, re) => {
    expect(firstPlanned(HOW[0])).toMatch(re);
  });
  test('the first How page says Arm and macOS hosts are not built', () => {
    expect(firstPlanned(HOW[0])).toMatch(/Arm and macOS hosts/);
  });
  test('no document claims a binary, a Homebrew formula, an apt repository or an install script exists', () => {
    // every mention is inside a sentence that says none exists / planned / not built
    // A paragraph of a document (blank-line separated), or a block of a page (one line each).
    const units = (who: string, t: string): string[] => (who.startsWith('docs/') ? t.split(/\n\s*\n/) : t.split('\n'));
    let seen = 0;
    for (const [who, t] of ALL) {
      for (const u of units(who, t).filter((l) => /Homebrew|apt repository|an install script/.test(l))) {
        seen++;
        expect({ who, u, marked: /planned|none exist|not built/i.test(u) }).toEqual({ who, u, marked: true });
      }
    }
    expect(seen).toBeGreaterThanOrEqual(8);
  });
  test('the repository really has no formula and no apt files, and the release job does not run the install script', () => {
    const release = repoFile('.github/workflows/release.yml');
    expect(release).not.toMatch(/brew\b|apt-get install buildrules|install\.sh/);
    // the release carries the command line and says the other channels are not built
    expect(repoFile('RELEASING.md')).not.toContain('There are no binaries');
    // the platforms of another host, where a tree has them, are pins and a local-mode platform; the check above ('a host that is not linux x86_64
    // gets no ISA platform') holds either way
  });
});

describe('the mopm pin, in both states', () => {
  // The texts say what each state is (a row marked `release_pending` is a stand-in and the Mojo beta leg is skipped; a row without the mark is the
  // published release and the leg runs) and send the reader to the file for which one it is today, so no text goes stale when the pin moves. What
  // must agree, in either state, is the data: the pin file, the Mojo beta steps and the RELEASING.md leg table. `disagreements` is that check; it is run
  // on this tree and on both states made from it, so each state's rule is asserted whichever state the tree is in.
  const pins = repoFile('rules/mopm/pins.bzl');
  const mojoSteps = repoFile('beta/mojo/STEPS');
  const releasing = repoFile('RELEASING.md');
  const MARK = '"release_pending": True,';
  const PLANNED_STEP = 'planned-until mopm-release';
  const mojoRow = (r: string): string => r.split('\n').find((l) => l.startsWith('| `mojo` |')) as string;

  const disagreements = (p: string, steps: string, rel: string): string[] => {
    const pending = p.includes(MARK);
    const out: string[] = [];
    if (steps.includes(PLANNED_STEP) !== pending) out.push(`beta/mojo/STEPS ${pending ? 'lacks' : 'has'} ${PLANNED_STEP}`);
    if (mojoRow(rel).includes('**planned**') !== pending) out.push(`RELEASING.md marks the mojo leg ${pending ? 'as running' : 'planned'}`);
    return out;
  };
  const asPending = (p: string): string => (p.includes(MARK) ? p : p.replace(/(\n {8}"dir": "[^"]+",)/, `$1\n        ${MARK}`));
  const asReleased = (p: string): string => p.replace(/\n\s*"release_pending": True,/, '');
  const stepsPending = (s: string): string => (s.includes(PLANNED_STEP) ? s : `${PLANNED_STEP}\n${s}`);
  const stepsReleased = (s: string): string => s.replace(`${PLANNED_STEP}\n`, '');
  const relPending = (r: string): string => r.replace(mojoRow(r), '| `mojo` | a Mojo package | **planned** until mopm\'s first release |');
  const relReleased = (r: string): string => r.replace(mojoRow(r), '| `mojo` | a Mojo package, built by the pinned mopm release | ubuntu x86_64 |');

  test('this tree: the pin file, beta/mojo/STEPS and RELEASING.md say the same', () => {
    expect(disagreements(pins, mojoSteps, releasing)).toEqual([]);
  });
  test('the pending state: a marked row needs the planned step and the planned table row', () => {
    expect(disagreements(asPending(pins), stepsPending(mojoSteps), relPending(releasing))).toEqual([]);
    expect(disagreements(asPending(pins), stepsReleased(mojoSteps), relPending(releasing))).toEqual([`beta/mojo/STEPS lacks ${PLANNED_STEP}`]);
    expect(disagreements(asPending(pins), stepsPending(mojoSteps), relReleased(releasing))).toEqual(['RELEASING.md marks the mojo leg as running']);
  });
  test('the released state: an unmarked row needs neither', () => {
    expect(asReleased(pins)).not.toContain(MARK);
    expect(disagreements(asReleased(pins), stepsReleased(mojoSteps), relReleased(releasing))).toEqual([]);
    expect(disagreements(asReleased(pins), stepsPending(mojoSteps), relReleased(releasing))).toEqual([`beta/mojo/STEPS has ${PLANNED_STEP}`]);
    expect(disagreements(asReleased(pins), stepsReleased(mojoSteps), relPending(releasing))).toEqual(['RELEASING.md marks the mojo leg planned']);
  });
  test('the texts describe both states and name the file that decides, and none calls the release planned', () => {
    const flat = (t: string): string => t.replace(/\s+/g, ' ');
    for (const [who, t] of ALL) {
      const f = flat(t);
      expect({ who, stand: /marked `release_pending` is a stand-in/.test(f) }).toEqual({ who, stand: true });
      expect({ who, released: /A row without that mark is the published release, and the leg runs/.test(f) }).toEqual({ who, released: true });
      expect({ who, file: f.includes('The file shows which it is') }).toEqual({ who, file: true });
    }
    // nothing about mopm is a planned item: a planned note or a "(planned)" / "(**planned**)" tag beside mopm would be false once the pin is the release
    expect(plannedText(WHY) + '\n' + HOW.map(plannedText).join('\n')).not.toMatch(/mopm|release_pending/);
    for (const [who, t] of ALL.filter(([w]) => w.startsWith('docs/'))) {
      for (const para of t.split(/\n\s*\n/).filter((x) => /mopm/.test(x))) {
        expect({ who, para: para.slice(0, 60), planned: /\(planned\)|\(\*\*planned\*\*\)|is \*\*planned\*\*/.test(para) }).toEqual({ who, para: para.slice(0, 60), planned: false });
      }
    }
  });
  test('the pin the pages name is the pin in the table', () => {
    expect(pins).toContain('MOPM_DEFAULT = "0.0.1"');
    expect(howText).toContain('mopm = "0.0.1"');
    expect(howText).toContain('[mopm."0.0.2"]');
    expect(pins).not.toContain('"0.0.2": {'); // so the page's example of a version buildrules does not pin is still one
  });
});

describe('the install script (site/static/install.sh, served as /install.sh)', () => {
  const sh = repoFile('site/static/install.sh');
  const usage = usageOf(sh);
  const flags = [...new Set([...usage.matchAll(/--[a-z][a-z0-9-]*/g)].map((m) => m[0]))].sort();
  const pagesAndDocs: [string, string][] = [
    ['the How page', pageText(HOW[0])],
    ['docs/how.md', HOW_MD],
  ];
  test('it takes the release targets of the release tool and no other', () => {
    const targets = [...repoFile('tools/release/binhdr.zig').matchAll(/pub const targets = \[_\]\[\]const u8\{([^}]*)\}/g)][0][1];
    const want = [...targets.matchAll(/"([a-z0-9_-]+)"/g)].map((m) => m[1]).sort();
    const got = [...sh.matchAll(/\btarget=([a-z0-9_-]+)/g)].map((m) => m[1]).sort();
    expect(want).toEqual(['linux-aarch64', 'linux-x86_64', 'macos-arm64']);
    expect(got).toEqual(want);
  });
  test('it asks for the asset the release tool names, and for SHA256SUMS', () => {
    expect(repoFile('tools/release/binaries.zig')).toContain('const cli_prefix = "buildrules-cli-";');
    expect(repoFile('tools/release/binaries.zig')).toContain('const tar_suffix = ".tar.gz";');
    expect(sh).toContain('name=buildrules-cli-$version-$target');
    expect(sh).toContain('asset=$name.tar.gz');
    expect(sh).toContain('/SHA256SUMS');
    expect(repoFile('RELEASING.md')).toContain('buildrules-cli-0.0.1-linux-x86_64.tar.gz');
  });
  test('it refuses an Intel Mac by name, and so do the pages', () => {
    expect(sh).toMatch(/Darwin-x86_64\) die "no buildrules release for Intel Macs/);
    for (const [who, t] of pagesAndDocs) expect({ who, has: /Intel Mac/.test(t) }).toEqual({ who, has: true });
  });
  test('the signature --verify checks is the release workflow\'s, on main, from the Actions issuer', () => {
    expect(sh).toMatch(/^signer=https:\/\/github\.com\/[a-z-]+\/buildrules\/\.github\/workflows\/release\.yml@refs\/heads\/main$/m);
    expect(sh).toMatch(/^issuer=https:\/\/token\.actions\.githubusercontent\.com$/m);
    expect(repoFile('.github/workflows/release.yml')).toContain('sigstore/cosign-installer');
    expect(repoFile('RELEASING.md')).toContain('`<file>.sigstore.json`');
  });
  test('the options the pages name are the options of the script, and every option is on the pages', () => {
    expect(flags).toEqual(['--help', '--prefix', '--releases-url', '--verify', '--version']);
    for (const [who, t] of pagesAndDocs) for (const f of flags.filter((x) => x !== '--help')) expect({ who, f, has: t.includes(`\`${f}`) }).toEqual({ who, f, has: true });
  });
  test('the install location is the one the pages name', () => {
    expect(sh).toContain('prefix=${HOME:?HOME is not set; use --prefix}/.buildrules');
    expect(sh).toContain('"$prefix/bin/buildrules"');
    for (const [who, t] of pagesAndDocs) expect({ who, has: t.includes('~/.buildrules/bin/buildrules') }).toEqual({ who, has: true });
  });
  test('the address answers only once the site is published, and the pages say so with a planned note', () => {
    expect(plannedText(HOW[0])).toMatch(/install\.sh answers only after/);
    expect(plannedText(WHY)).toMatch(/Publishing this site at buildrules\.dev/);
    expect(HOW_MD).toMatch(/The site is not published yet \(\*\*planned\*\*\)/);
  });
});
