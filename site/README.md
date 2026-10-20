# site: the buildrules.dev website

Static pages, prerendered by a TypeScript program at build time. The pages carry no script, no tracking, no web fonts and
no third-party request. Light and dark themes follow the reader's system setting through one stylesheet. The build
program has no runtime dependencies: `package.json` lists only development tools (typescript, jest, ts-jest and type
declarations), and nothing from `node_modules` is imported by the rendering code.

## Where things are

| path | what |
|---|---|
| `tools/content/*.ts` | the text of every page, as data (a title and a list of blocks); the only place prose lives |
| `tools/model.ts`, `tools/inline.ts`, `tools/render.ts` | the block types, the inline syntax (plain text, `code`, `[label](href)`), and the HTML writer |
| `tools/pages.ts` | the list of pages and the navigation |
| `tools/check-dist.ts` | the checker for a built tree: every link and fragment resolves, no orphan page, no script, no inline style |
| `tools/build.ts` | the build program: render, hash the stylesheet, check, write `dist/` |
| `static/` | the stylesheet and the icon |
| `serve.js`, `preview.bzl` | the local preview server and the `buck2 run` rule that starts it |
| `test/` | render tests, the link check, tests that compare the pages with the rule sources, the CLI usage text and the contract |
| `pins.toml`, `pins.lock.bzl`, `package-lock.json` | the npm packages, pinned by hash |

## Build and test

Everything runs on the farm, through buildrules' own Node rules, from the pinned packages: no `npm install`, no host Node.
From the repository root:

```sh
buck2 build //site:typecheck   # tsc --noEmit over pages, tools and tests
buck2 build //site:test        # jest: render tests, link check, page-against-source tests
buck2 build //site:dist        # the site, written to dist/
```

A test is part of the build: a cached rebuild of `//site:test` means it passed on identical inputs. The `dist` target runs
the same tree check as the tests, so a broken link, a missing fragment or an inline style fails `//site:dist`.

The tests read the sources the pages describe (the Zig usage texts of the command line, `docs/contract.md`, the `.bzl` files of
the rules, the Rust version table, the CPU-level table, `ci/BUCK`, the Mojo and mopm pins) and fail when a page names a command, flag, rule, rule argument, version, CPU level, matrix target or exit code that does not exist, or states a value that differs from its source (`test/facts.test.ts`, `test/rules_facts.test.ts`). A page that describes
something not built must say so with a `planned` note. The Why and How pages repeat `docs/why.md` and `docs/how.md`; `test/docs_facts.test.ts`
holds their pins, gates, platforms, release stages, flags and planned items to the sources, and the mopm pin in both of its states.

## Preview

```sh
buck2 run //site:preview            # serves dist/ on 127.0.0.1:8080
buck2 run //site:preview -- 9000    # another port
```

`dist/` is built on the farm first. Serving is the only local work: a small HTTP server, run by the pinned Node.js, that
reads files. It binds to the loopback address only.

## Edit a page

Change the matching file under `tools/content/`, then run the three targets above. Links between pages are written as
`[label](/path/#fragment)`; the fragment is the slug of a heading on the target page. Link text and fragments are checked at
build time.

## Publish (held)

Publishing is not part of the build and nothing here does it. The hosting stack, `infra/site`, and its held steps
(`github`, `dns`, `site`, `vars`) are run by a person with their own cloud credentials; each step is a dry run unless
`--apply` is given, and refuses unless the account matches `--account`. See `infra/site/README.md`. After the stack exists, the
publish workflow (not yet written; `infra/site/README.md` says what it must do) builds `//site:dist` and uploads the tree to the bucket.
