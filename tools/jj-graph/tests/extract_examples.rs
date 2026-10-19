//! Each language's queries against a representative file.

use std::collections::BTreeSet;

use jj_graph::diff::FileDiff;
use jj_graph::extract::{Kind, Lang, file_symbols, parse};

fn items(lang: Lang, text: &str) -> BTreeSet<(String, Kind, bool)> {
    parse(lang, text)
        .items
        .into_iter()
        .map(|i| (i.name, i.kind, i.public))
        .collect()
}

fn set(items: &[(&str, Kind, bool)]) -> BTreeSet<(String, Kind, bool)> {
    items
        .iter()
        .map(|(n, k, p)| (n.to_string(), *k, *p))
        .collect()
}

fn names(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

fn added(path: &str, text: &str) -> FileDiff {
    FileDiff {
        new_path: Some(path.into()),
        new: text.into(),
        ..FileDiff::default()
    }
}

fn modified(path: &str, old: &str, new: &str) -> FileDiff {
    FileDiff {
        old_path: Some(path.into()),
        new_path: Some(path.into()),
        old: old.into(),
        new: new.into(),
        ..FileDiff::default()
    }
}

const RUST: &str = r#"use std::fmt;

pub trait Storage {
    fn get(&self, key: &str) -> Option<String>;
    fn describe(&self) -> String { String::from("store") }
}

pub struct Db { rows: Vec<String> }

enum Mode { Fast, Slow }

impl Storage for Db {
    fn get(&self, key: &str) -> Option<String> {
        fn helper() {}
        self.rows.iter().find(|r| *r == key).cloned()
    }
}

pub fn open(path: &str) -> Db { Db { rows: vec![path.to_owned()] } }
const LIMIT: usize = 3;
"#;

#[test]
fn rust_items() {
    use Kind::*;
    // A method of a trait implementation is named after its type: callers
    // reach it through the trait's member, not by its own name.
    assert_eq!(
        items(Lang::Rust, RUST),
        set(&[
            ("Storage", Contract, true),
            ("Db", Contract, true),
            ("Mode", Contract, false),
            ("Db::get", Impl, false),
            ("open", Impl, true),
            ("LIMIT", Impl, false),
        ])
    );
    assert_eq!(parse(Lang::Rust, RUST).imports, vec![0..1]);
}

#[test]
fn rust_members_belong_to_their_items() {
    let parsed = parse(Lang::Rust, RUST);
    let members = |name: &str| -> BTreeSet<String> {
        parsed
            .items
            .iter()
            .find(|i| i.name == name)
            .unwrap()
            .members
            .iter()
            .cloned()
            .collect()
    };
    assert_eq!(members("Storage"), names(&["get", "describe"]));
    assert_eq!(members("Db"), names(&["rows"]));
    assert_eq!(members("Mode"), names(&["Fast", "Slow"]));
}

const PYTHON: &str = r#"from typing import Protocol, TypeAlias
from dataclasses import dataclass

Key: TypeAlias = str

class Storage(Protocol):
    def get(self, key: Key) -> str: ...

@dataclass
class Row:
    key: Key

class Db:
    def get(self, key):
        def helper():
            pass
        return lookup(key)

def _private():
    return 1

LIMIT = 3
"#;

#[test]
fn python_items() {
    use Kind::*;
    assert_eq!(
        items(Lang::Python, PYTHON),
        set(&[
            ("Key", Contract, true),
            ("Storage", Contract, true),
            ("Row", Contract, true),
            ("Db", Impl, true),
            ("get", Impl, true),
            ("_private", Impl, false),
            ("LIMIT", Impl, true),
        ])
    );
}

const TYPESCRIPT: &str = r#"import { Network } from "./net";

export interface Storage { get(key: string): string; }
export type Key = string;
enum Mode { Fast, Slow }
export abstract class Base { abstract run(): void; }

export class Db implements Storage {
  get(key: Key): string { return lookup(key); }
}

export function open(path: string): Db { return new Db(); }
const limit = 3;
"#;

#[test]
fn typescript_items() {
    use Kind::*;
    let found = items(Lang::TypeScript, TYPESCRIPT);
    for want in [
        ("Storage", Contract, true),
        ("Key", Contract, true),
        ("Mode", Contract, false),
        ("Base", Contract, true),
        ("Db", Impl, true),
        ("get", Impl, true),
        ("open", Impl, true),
        ("limit", Impl, false),
    ] {
        assert!(
            found.contains(&(want.0.to_string(), want.1, want.2)),
            "missing {want:?} in {found:?}"
        );
    }
}

const GO: &str = r#"package store

import "fmt"

type Storage interface { Get(key string) string }

type Db struct { rows []string }

func (d *Db) Get(key string) string { return fmt.Sprint(key) }

func open() *Db { return &Db{} }

const Limit = 3
"#;

#[test]
fn go_items() {
    use Kind::*;
    assert_eq!(
        items(Lang::Go, GO),
        set(&[
            ("Storage", Contract, true),
            ("Db", Contract, true),
            ("Get", Impl, true),
            ("open", Impl, false),
            ("Limit", Impl, true),
        ])
    );
}

const NIX: &str = r#"{ config, lib, pkgs, ... }:
let
  cfg = config.dotfiles.store;
in
{
  options.dotfiles.store = {
    enable = lib.mkEnableOption "the store";
    path = lib.mkOption { type = lib.types.str; default = "/srv"; };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.hello ];
  };

  home.stateVersion = "26.05";
}
"#;

#[test]
fn nix_items() {
    use Kind::*;
    assert_eq!(
        items(Lang::Nix, NIX),
        set(&[
            ("dotfiles.store.enable", Contract, true),
            ("dotfiles.store.path", Contract, true),
            ("home.stateVersion", Impl, true),
        ])
    );
    let refs: BTreeSet<String> = parse(Lang::Nix, NIX)
        .refs
        .into_iter()
        .map(|r| r.name)
        .collect();
    for r in ["dotfiles", "dotfiles.store", "store", "lib", "pkgs", "cfg"] {
        assert!(refs.contains(r), "missing ref {r}: {refs:?}");
    }
}

#[test]
fn an_added_file_defines_everything_in_it() {
    let s = file_symbols(&added("src/store.rs", RUST));
    assert_eq!(
        s.defs,
        names(&[
            "Storage", "get", "describe", "Db", "rows", "Mode", "Fast", "Slow", "Db::get", "open",
            "LIMIT"
        ])
    );
    assert_eq!(
        s.contracts,
        names(&[
            "Storage", "get", "describe", "Db", "rows", "Mode", "Fast", "Slow"
        ])
    );
    // `rows` is used by the implementation, and `String` by both.
    assert!(s.refs.contains("String") && s.refs.contains("rows"));
    // Its new contracts make up its contract part.
    assert_eq!(s.hoisted, s.contracts);
    assert_eq!(s.cfiles, names(&["src/store.rs"]));
}

#[test]
fn reformatting_and_comments_define_nothing() {
    let old = "pub fn open(path: &str) -> u8 { 1 }\n";
    let new = "// Open the store.\npub fn open(\n    path: &str,\n) -> u8 {\n    1\n}\n";
    let s = file_symbols(&modified("a.rs", old, new));
    assert!(s.defs.is_empty(), "{s:?}");
}

#[test]
fn a_changed_body_defines_its_item_and_references_what_it_adds() {
    let old = "fn open() -> u8 { 1 }\nfn close() {}\n";
    let new = "fn open() -> u8 { checksum(2) }\nfn close() {}\n";
    let s = file_symbols(&modified("a.rs", old, new));
    assert_eq!(s.defs, names(&["open"]));
    assert!(s.contracts.is_empty());
    assert!(s.refs.contains("checksum"));
    assert!(!s.refs.contains("close"));
}

#[test]
fn removing_an_item_defines_it() {
    let s = file_symbols(&modified(
        "a.py",
        "def a():\n    pass\ndef b():\n    pass\n",
        "def a():\n    pass\n",
    ));
    assert_eq!(s.defs, names(&["b"]));
}

#[test]
fn contract_references_are_those_inside_contract_items() {
    let old = "fn run() {}\n";
    let new = "trait Store { fn key(&self) -> Key; }\nfn run() { helper(); }\n";
    let s = file_symbols(&modified("a.rs", old, new));
    assert_eq!(s.hoisted, names(&["Store", "key"]));
    assert!(s.crefs.contains("Key"));
    assert!(!s.crefs.contains("helper"));
    assert!(s.refs.contains("helper"));
}

#[test]
fn unknown_and_binary_files_only_touch_paths() {
    let s = file_symbols(&added("README.md", "# Store\n"));
    assert_eq!(s.files, names(&["README.md"]));
    assert!(s.defs.is_empty() && s.refs.is_empty());
    let b = FileDiff {
        binary: true,
        ..added("logo.rs", "")
    };
    assert_eq!(file_symbols(&b).files, names(&["logo.rs"]));
}
