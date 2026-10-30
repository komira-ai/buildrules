"""Values and checks the analysis tests of rules/native/tests/BUCK are made of (a BUCK file defines no function)."""

load("//rules/native:checks.bzl", "archive_extension", "cxx_label", "link_order")
load("//rules/native:link.bzl", "extra_link_archives", "link_archive_name", "link_cfg")

SHA = "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"

def up(**changes):
    """A good `upstream` table, with the keys of `changes` replaced (a value of None removes the key)."""
    table = {"url": "https://example.invalid/lib-1.0.tar.gz", "sha256": SHA, "size": 1512791, "strip": "lib-1.0", "files": ["a.c", "inc/a.h"]}
    for k, v in changes.items():
        if v == None:
            table.pop(k)
        else:
            table[k] = v
    return table

def _equal(who, got, want, refuse):
    if got != want:
        refuse("{}: got {}, want {}".format(who, got, want))

def link_order_is(who, own, deps, want, refuse = fail):
    _equal(who, link_order(own, deps), want, refuse)

def extension_is(who, url, want, refuse = fail):
    _equal(who, archive_extension(url), want, refuse)

def label_is(who, label, want, refuse = fail):
    _equal(who, cxx_label(label), want, refuse)

def extras_are(who, archive_lists, linked, want, refuse = fail):
    got = extra_link_archives(archive_lists, linked, lambda a: a)
    _equal(who, got, want, refuse)

def cfg_is(who, names, cxx, want, refuse = fail):
    _equal(who, link_cfg(names, cxx), want, refuse)

def extras_by_path_are(who, archive_lists, linked, want, refuse = fail):
    """Archives are told apart by the path they are at, not by their file name: the key is the whole string."""
    _equal(who, extra_link_archives(archive_lists, linked, lambda a: a), want, refuse)

def name_is(who, position, basename, want, refuse = fail):
    _equal(who, link_archive_name(position, basename), want, refuse)
