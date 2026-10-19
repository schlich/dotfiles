//! Files in every language jj-graph reads, made of item templates.

#![allow(dead_code)]

use hegel::TestCase;
use hegel::generators as gs;

/// An item, with `{i}` for its index and `{v}` for a value its body holds.
pub struct Template {
    pub name: &'static str,
    pub text: &'static str,
    pub contract: bool,
}

/// A language: a file's path, what comes before and after its items, and
/// a comment.
pub struct Language {
    pub path: &'static str,
    pub header: &'static str,
    pub footer: &'static str,
    pub comment: &'static str,
    pub templates: &'static [Template],
}

pub const LANGUAGES: [Language; 6] = [
    Language {
        path: "src/a.rs",
        header: "",
        footer: "",
        comment: "// note\n",
        templates: &[
            Template {
                name: "T{i}",
                text: "pub trait T{i} {\n    fn m{i}(&self) -> u8 {\n        {v}\n    }\n}\n",
                contract: true,
            },
            Template {
                name: "S{i}",
                text: "pub struct S{i} {\n    pub f{i}: [u8; {v}],\n}\n",
                contract: true,
            },
            Template {
                name: "f{i}",
                text: "pub fn f{i}() -> u8 {\n    {v}\n}\n",
                contract: false,
            },
            Template {
                name: "C{i}",
                text: "const C{i}: u8 = {v};\n",
                contract: false,
            },
        ],
    },
    Language {
        path: "a.py",
        header: "",
        footer: "",
        comment: "# note\n",
        templates: &[
            Template {
                name: "P{i}",
                text: "class P{i}(Protocol):\n    def m{i}(self) -> int:\n        return {v}\n",
                contract: true,
            },
            Template {
                name: "f{i}",
                text: "def f{i}():\n    if x:\n        a()\n    return {v}\n",
                contract: false,
            },
        ],
    },
    Language {
        path: "a.ts",
        header: "",
        footer: "",
        comment: "// note\n",
        templates: &[
            Template {
                name: "I{i}",
                text: "export interface I{i} {\n  m{i}(a{v}: number): void;\n}\n",
                contract: true,
            },
            Template {
                name: "f{i}",
                text: "export function f{i}() {\n  return {v};\n}\n",
                contract: false,
            },
            Template {
                name: "c{i}",
                text: "const c{i} = [{v}];\n",
                contract: false,
            },
            Template {
                name: "T{i}",
                text: "export type T{i} = [{v}];\n",
                contract: true,
            },
        ],
    },
    Language {
        path: "a.js",
        header: "",
        footer: "",
        comment: "// note\n",
        templates: &[
            Template {
                name: "f{i}",
                text: "function f{i}() {\n  return {v};\n}\n",
                contract: false,
            },
            Template {
                name: "c{i}",
                text: "export const c{i} = {v};\n",
                contract: false,
            },
            Template {
                name: "K{i}",
                text: "class K{i} {\n  m{i}() {\n    return {v};\n  }\n}\n",
                contract: false,
            },
        ],
    },
    Language {
        path: "a.go",
        header: "package a\n\n",
        footer: "",
        comment: "// note\n",
        templates: &[
            Template {
                name: "F{i}",
                text: "func F{i}() int {\n\treturn {v}\n}\n",
                contract: false,
            },
            Template {
                name: "T{i}",
                text: "type T{i} interface {\n\tM{i}(a{v} int)\n}\n",
                contract: true,
            },
            Template {
                name: "S{i}",
                text: "type S{i} struct {\n\tF{i} [{v}]int\n}\n",
                contract: true,
            },
            Template {
                name: "V{i}",
                text: "var V{i} = {v}\n",
                contract: false,
            },
        ],
    },
    Language {
        path: "module.nix",
        header: "{ lib, ... }:\n{\n",
        footer: "}\n",
        comment: "# note\n",
        templates: &[
            Template {
                name: "o{i}",
                text: "  options.o{i} = lib.mkOption { default = {v}; };\n",
                contract: true,
            },
            Template {
                name: "c{i}",
                text: "  config.c{i} = {v};\n",
                contract: false,
            },
            Template {
                name: "x{i}",
                text: "  x{i} = {v};\n",
                contract: false,
            },
        ],
    },
];

/// An item of a generated file: its template, index, and value, and
/// whether its first space is doubled, an edit only of layout.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Drawn {
    pub template: usize,
    pub index: usize,
    pub value: usize,
    pub spaced: bool,
}

impl Drawn {
    pub fn name(&self, lang: &Language) -> String {
        lang.templates[self.template]
            .name
            .replace("{i}", &self.index.to_string())
    }

    pub fn contract(&self, lang: &Language) -> bool {
        lang.templates[self.template].contract
    }

    pub fn text(&self, lang: &Language) -> String {
        let text = lang.templates[self.template]
            .text
            .replace("{i}", &self.index.to_string())
            .replace("{v}", &self.value.to_string());
        if !self.spaced {
            return text;
        }
        let indent = text.len() - text.trim_start().len();
        match text[indent..].find(' ') {
            Some(at) => format!("{} {}", &text[..indent + at], &text[indent + at..]),
            None => text,
        }
    }
}

pub fn file(lang: &Language, items: &[Drawn]) -> String {
    let body: String = items.iter().map(|d| d.text(lang)).collect();
    format!("{}{body}{}", lang.header, lang.footer)
}

/// One to four items, each with its own index.
#[hegel::composite]
pub fn files(tc: &TestCase, lang: usize) -> Vec<Drawn> {
    let n = tc.draw(gs::integers::<usize>().min_value(1).max_value(4));
    (0..n)
        .map(|index| Drawn {
            template: tc
                .draw(gs::integers::<usize>().max_value(LANGUAGES[lang].templates.len() - 1)),
            index,
            value: tc.draw(gs::integers::<usize>().min_value(1).max_value(2)),
            spaced: false,
        })
        .collect()
}
