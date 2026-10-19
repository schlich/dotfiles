---
type: bug
stage: done
description: GitHub Actions selected Bash for workflow scripts even though the repository uses Nushell.
generated:
  by: process:copilot-task-agent
  at: 2026-10-18T05:37:04Z
sources:
- id: workflow
  resource: .github/workflows/nix-ci.yml
  title: GitHub Actions workflow
- id: action
  resource: .github/actions/flake-check/action.yml
  title: Composite flake-check action
---

# Bug: GitHub Actions runs workflow scripts in Bash instead of Nushell

## Symptom

The CI workflow and composite flake-check action explicitly selected Bash for
their scripts, so Nushell-specific commands and syntax could not run in those
steps.

## Reproduction

Inspect `.github/workflows/nix-ci.yml` and
`.github/actions/flake-check/action.yml` for shell declarations and Bash
syntax in their `run` steps.

## Root cause

GitHub Actions defaults to Bash for shell steps, and the workflow also declared
`shell: bash` explicitly. Nushell was neither installed nor selected as the
runner shell.

## Fix

Install a pinned Nushell version in each job that runs scripts, set the
workflow's default shell to Nushell, explicitly select Nushell in composite
action steps, and translate the scripts to Nushell syntax.

## Key references

- 2026-10-18 — `.github/workflows/nix-ci.yml:6` — workflow-level Nushell shell and setup
- 2026-10-18 — `.github/actions/flake-check/action.yml:15` — composite action shell and setup
