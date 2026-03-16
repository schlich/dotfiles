# modalkit API (reedline Helix subset)

Generated from docs.rs rustdoc JSON.

Symbols imported in src/edit_mode/helix.rs:
- TerminalKey
- BindingMachine
- EdgeEvent
- EdgeRepeat
- EmptyKeyState
- InputBindings
- InputKey
- ModalMachine
- Mode
- ModeKeys

## BindingMachine
- kind: trait
- source: keybindings@0.0.2
- path: keybindings::BindingMachine
- docs: Trait for objects that can process input keys using previously mapped bindings.

## EdgeEvent
- kind: enum
- source: keybindings@0.0.2
- path: keybindings::EdgeEvent
- docs: What kind of input is acceptible for continuing towards a [Step].

## EdgeRepeat
- kind: enum
- source: keybindings@0.0.2
- path: keybindings::EdgeRepeat
- docs: Specifies how many times an [EdgeEvent] is allowed to be repeated.

## EmptyKeyState
- kind: struct
- source: keybindings@0.0.2
- path: keybindings::EmptyKeyState
- docs: An implementation of [InputKeyState] that stores nothing.

## InputBindings
- kind: trait
- source: keybindings@0.0.2
- path: keybindings::InputBindings
- docs: A collection of bindings that can be added to a [ModalMachine].

## InputKey
- kind: trait
- source: keybindings@0.0.2
- path: keybindings::InputKey
- docs: Trait for keys that can be used with [ModalMachine].

## ModalMachine
- kind: struct
- source: keybindings@0.0.2
- path: keybindings::ModalMachine
- docs: Manage and process modal keybindings.

## Mode
- kind: trait
- source: keybindings@0.0.2
- path: keybindings::Mode
- docs: Trait for the input modes specific to a consumer.

## ModeKeys
- kind: trait
- source: keybindings@0.0.2
- path: keybindings::ModeKeys
- docs: Key-specific behaviour associated with a [Mode].

## TerminalKey
- kind: struct
- source: modalkit@0.0.24
- path: modalkit::key::TerminalKey
- docs: A key pressed in a terminal.
