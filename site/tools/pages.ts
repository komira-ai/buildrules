import { concepts } from './content/concepts';
import { cli } from './content/cli';
import { faq } from './content/faq';
import { gettingStarted } from './content/getting-started';
import { home } from './content/home';
import { remote } from './content/remote';
import { cxx, mojo, node, python, rules, rust, zig } from './content/rules';
import type { Page } from './model';
import type { NavItem } from './render';

/** Every page of the site, in the order of the sitemap. */
export const PAGES: Page[] = [home, gettingStarted, concepts, rules, rust, node, zig, cxx, mojo, python, cli, remote, faq];

export const NAV: NavItem[] = [{ path: '/', label: 'Home' }].concat(
  PAGES.filter((p) => p.nav !== undefined).map((p) => ({ path: p.path, label: p.nav as string })),
);
