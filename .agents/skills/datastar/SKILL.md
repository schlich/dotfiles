---
name: datastar
description: Build, debug, or update applications using the Datastar hypermedia framework, including its Rocket web component API.
---

# Datastar

Use official Datastar docs as the source of truth. Before writing or changing
Datastar code, check the current documentation and release notes for the
version used by the project; APIs and syntax can change between releases.

## Core framework

- Follow the installed or pinned version. Do not copy old examples that use
  pre-1.0 attribute syntax; current attributes use a colon between the
  attribute name and key (for example, `data-on:click` and
  `data-signals:count`).
- Prefer server-rendered HTML and Datastar's SSE event model for server-driven
  updates. Use the official SDK for the project's backend language when one is
  available, and preserve the existing framework's response and streaming
  conventions.
- For frontend-only behavior, use Datastar attributes and expressions before
  adding custom JavaScript state management. Keep expressions small and
  validate behavior against the current attribute and action references.
- Pin the browser bundle to the app's Datastar version. The project's README
  and release page provide the current versioned bundle URL and migration
  notes.

## Rocket components

Rocket is Datastar's web component API and is documented as beta; confirm the
current stability and distribution requirements before adopting it. Read the
[Rocket reference](https://data-star.dev/reference/rocket) for component work.

- Load the Rocket bundle (`datastar-rocket.js`) instead of separately loading
  the standard Datastar bundle; Rocket's bundle includes Datastar.
- Define components with `rocket(tag, options)`. Declare and decode public
  attributes through `props`, create instance-local reactive state and
  lifecycle effects in `setup`, and return declarative DOM from `render`.
- Put logic that needs rendered refs, measurements, or mounted DOM in
  `onFirstRender`, rather than deferring it inside `setup`.
- Use `$$name` for component-local signals in rendered expressions. Rocket
  scopes these per instance; do not hard-code its generated `_rocket` paths.
  Use the `__root` modifier only when authored child elements must bind to
  page-level signals.
- Keep the component's public props, slots, and events intentional. Add
  manifest metadata when consumers or tooling need slot and event
  documentation.
- Treat the beta API as version-sensitive. Avoid depending on undocumented
  internals, and isolate Rocket usage so a later API change is manageable.

## References

- [Getting started and guides](https://data-star.dev/guide)
- [Attribute, action, and SSE references](https://data-star.dev/reference)
- [Rocket API reference](https://data-star.dev/reference/rocket)
- [Official repository and releases](https://github.com/starfederation/datastar/releases)
