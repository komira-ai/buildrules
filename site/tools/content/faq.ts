import { h2, p, type Block, type Page } from '../model';

const q = (question: string, ...answer: string[]): Block[] => [h2(question), ...answer.map(p)];

export const faq: Page = {
  path: '/faq/',
  title: 'FAQ',
  nav: 'FAQ',
  description: 'Common questions about buildrules: what it replaces, what it needs, its limits, and what is planned.',
  lead: 'Short answers, with links to the page that has the detail.',
  blocks: [
    ...q(
      'Does buildrules replace Cargo or npm?',
      'No. Cargo still resolves and writes `Cargo.lock`, and `cargo build` and `cargo test` keep working. npm\'s `package-lock.json` is read as it is, and `npm test` keeps working. buildrules builds from those files in Buck2. See [native-tool parity](/concepts/#native-tool-parity).',
    ),
    ...q(
      'Is it ready for production?',
      'No. It is a v0 proof of concept for Linux x86_64. The Rust, Node, Zig, C/C++ and Mojo rules have run on a farm. The public CI also builds everything except the Mojo packages in the opt-in local mode. Interfaces can still change, a release is a tagged source archive with the command line, and not a promise of stability, and the limits below are real.',
    ),
    ...q(
      'Does it need a remote farm?',
      'By default, yes: the point is a shared, per-dependency cache and uniform workers, so the default execution platform has no local fallback and fails to load without a farm. If you have no farm, you can opt in with `-c buildrules_re.mode=local`, which runs every action on your machine with the same pinned toolchains; it is refused when a farm is also configured. See [Remote execution](/remote-execution/).',
    ),
    ...q(
      'Which farms work?',
      'Any server that implements the Remote Execution API that Buck2 speaks. It has been run on one farm only, so check your worker properties first if something fails.',
    ),
    ...q(
      'Does it work on macOS, Windows or ARM?',
      'Not yet. macOS and Windows are planned and nothing is built for them. Arm CPU levels are in the tables as data, but no Arm worker has run them. Clients and workers must be Linux x86_64. See [Platforms](/rules/#platforms).',
    ),
    ...q(
      'Can I build for a newer CPU level?',
      'Yes, for x86-64: a target platform such as `linux_x86_64_v3` passes the matching flags to rustc, Zig and Mojo, and tests at that level run on workers that report it. See [CPU levels](/rules/#cpu-levels).',
    ),
    ...q(
      'Why is rust-toolchain.toml required?',
      'So that Cargo and Buck2 use one compiler, and so that the build can refuse a floating channel. It must name an exact release such as `1.95.0`. See [rust-toolchain.toml is required](/concepts/#rust-toolchain-toml-is-required).',
    ),
    ...q(
      'Can I use a different Rust version?',
      'Yes, if it is pinned. The rules pin `1.95.0` (the default) and `1.85.0` (the oldest supported), and `rust-toolchain.toml` selects between them. For another release, add its hashes to `buildrules-pins.toml`. A release that is in neither is refused by `buildrules sync`. See [the Rust toolchains](/rules/rust/#toolchains).',
    ),
    ...q(
      'What do I have to commit?',
      'Everything `init` and `sync` write, except `.buckconfig.local`: `.buckconfig`, `toolchains/BUCK`, `platforms/BUCK`, `buildrules.lock.bzl`, `buildrules.bzl`, `third_party/buildrules/` and each member\'s `BUCK`. Generated files say "Do not edit" in their first line.',
    ),
    ...q(
      'What happens when I forget to run sync?',
      '`buildrules check` fails in CI, and `:check` fails the Buck2 build of `:debug`, `:release`, `:test` and `:lint`. Both print `buildrules sync` as the fix.',
    ),
    ...q(
      'Which Rust projects does it support?',
      'Workspaces whose root `Cargo.toml` is virtual (no `[package]`) and sits at the repository root, with crates from crates.io. Git dependencies and alternate registries are refused. Build scripts run as actions; a few that compile C code need an override. See [the Rust rules](/rules/rust/).',
    ),
    ...q(
      'Are doctests and coverage supported?',
      'No. `:test` does not run doctests, and `:coverage` refuses.',
    ),
    ...q(
      'Do npm install scripts run?',
      'No. The Node rules are the offline equivalent of `npm ci --ignore-scripts`, and no action has network access.',
    ),
    ...q(
      'Is there an `npm_package` macro like `cargo_package`?',
      'Yes. `npm_package(path = ".")` is the front door, over the table `buildrules npm sync` writes from `package.json` and `package-lock.json`. The single-tarball rule is `npm_tarball`. See [the Node rules](/rules/node/).',
    ),
    ...q(
      'What about Mojo and Python?',
      'Mojo has rules, built on mopm: see [Mojo](/rules/mojo/). They build with the one Mojo version mopm pins, and the mopm they pin is the published 0.0.34 release. Python is planned and has none: see [Python](/rules/python/).',
    ),
    ...q(
      'Does this site track me?',
      'No. It sets no cookies, runs no scripts and loads no files from other sites.',
    ),
    ...q(
      'What is the license?',
      'Apache-2.0.',
    ),
    ...q(
      'Where do I report a problem?',
      'On the [issue tracker](https://github.com/komira-ai/buildrules/issues) of the repository.',
    ),
  ],
};
