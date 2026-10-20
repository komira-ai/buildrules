import { code, h2, info, p, table, ul, type Page } from '../model';

export const home: Page = {
  path: '/',
  title: 'Hermetic, multi-language builds for Buck2',
  description:
    'buildrules is a set of Buck2 rules and a small command line that build Rust, Node, Zig and C/C++ from the lockfiles your native tools already use, with pinned toolchains and per-dependency remote caching.',
  lead:
    'buildrules is a set of [Buck2](https://buck2.build) rules and a small command line. It builds a project from the files its ' +
    'native tools already use (`Cargo.toml`, `Cargo.lock`, `package-lock.json`), pins every toolchain by hash, and caches ' +
    'each dependency separately on any remote execution farm that speaks the REAPI protocol.',
  blocks: [
    info(
      'buildrules is a v0 proof of concept. It builds for Linux x86_64 only. Actions run on a remote execution farm by default, or on your own machine if you opt in. The ' +
        'Rust, Node, Zig, C/C++ and Mojo rules exist; Python, macOS and Windows are planned. A release is a tagged source archive, made automatically from `main`. Every page says which parts are built and which are not.',
    ),
    h2('What it gives you'),
    ul(
      'Lockfile-native. Your lockfile is the dependency list. buildrules does not keep a second one; it reads `Cargo.lock` and `package-lock.json` and builds exactly what they say. See [lockfile-native](/concepts/#lockfile-native).',
      'Your native tools keep working. `cargo build`, `cargo test` and `npm test` run on the same files, with the same compiler version, as the Buck2 build. See [native-tool parity](/concepts/#native-tool-parity).',
      'Hermetic. The compiler, the Node.js runtime and the other tools are downloads pinned by sha256. An action has no `PATH` and no host compiler, and the Node actions have no network. See [hermetic pinned toolchains](/concepts/#hermetic-pinned-toolchains).',
      'Per-dependency caching. Each registry crate compiles in its own action and each npm package is its own pinned download, so a remote cache can reuse everything a change did not touch. See [per-crate caching](/concepts/#per-crate-caching).',
      'Remote by default, local on request. Actions run on a farm you connect with a gitignored `.buckconfig.local`; no endpoint is ever written into a repository. Without a farm, `-c buildrules_re.mode=local` runs them on your machine with the same pinned toolchains. See [remote execution](/remote-execution/).',
    ),
    h2('Rule families'),
    table(
      ['Family', 'Status', 'What exists'],
      ['[Rust](/rules/rust/)', 'built', '`cargo_workspace` and `cargo_package`, driven by `Cargo.lock`, one compile action per crate, with pinned Rust versions and CPU levels'],
      ['[Node](/rules/node/)', 'built', '`npm_package`, `npm_modules`, `tsc_check`, `tsc_build`, `jest_test`, `node_tree_test`, `node_tree_build` and more, over a pinned Node.js'],
      ['[Zig](/rules/zig/)', 'built', '`zig_exe`, `zig_test`, `zig_module`, on a pinned Zig'],
      ['[C/C++](/rules/cxx/)', 'built', 'a toolchain for the prelude\'s `cxx_library` and `cxx_binary` on a pinned Zig, plus symbol and glibc-floor gates'],
      ['[Mojo](/rules/mojo/)', 'built', '`mojo_package`, on [mopm](https://mopm.dev), which decides what to build; buildrules runs it as cached actions'],
      ['[Python](/rules/python/)', 'planned', 'no rules yet'],
    ),
    h2('A first look'),
    p('For a Rust workspace, this is the whole workflow. [Getting started](/getting-started/) explains each step.'),
    code(
      [
        'buildrules init . --git https://github.com/komira-ai/buildrules --commit <40-hex commit>',
        'buildrules cargo new crates/hello',
        'buildrules sync',
        'buck2 build //crates/hello:test //crates/hello:debug',
        'buildrules check',
      ].join('\n'),
      'shell',
    ),
    p('A member\'s `BUCK` file is two lines, and `buildrules` writes it:'),
    code('load("//:buildrules.bzl", "cargo_package")\n\ncargo_package(path = ".")', 'crates/hello/BUCK'),
    h2('Where to go next'),
    ul(
      '[Why buildrules](/why/): the argument, the design and what is not done.',
      '[Getting started](/getting-started/): set up a repository and build a crate.',
      '[How to use it](/how/): the manual, with [configuration](/how/configure/) and [examples by language](/how/examples/).',
      '[Concepts](/concepts/): how the lockfile, the pins and the sync model fit together.',
      '[Rules reference](/rules/): every rule family and what is planned.',
      '[CLI reference](/cli/): commands, flags and exit codes.',
      '[Remote execution](/remote-execution/): connect a farm.',
      '[FAQ](/faq/): limits and common questions.',
    ),
  ],
};
