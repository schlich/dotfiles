---
name: immersive-songwriting-studio
description: Generates immersive in-studio VR songwriting tutorials from song ideas and maps tangible 3D controls onto real DAW or audio-engine constructs. Use when a user asks for a VR music lesson, spatial songwriting workflow, virtual studio experience, or DAW-integrated tutorial, especially for Maolan.
---

# Immersive Songwriting Studio

Turn a song idea into a guided VR studio session in which every spatial interaction teaches a songwriting decision and every functional control has a concrete DAW or audio-engine binding.

The result is a tutorial specification, not just a themed room or a list of production tips. It must tell the learner what to hear, what to decide, what to touch, what changes in the song, and how that change reaches the underlying audio system.

## Input

Accept a free-form song idea. The prompt may include any combination of:

- mood, story, image, lyric, genre, or reference
- tempo, meter, key, chords, instrumentation, or vocal range
- target DAW or audio engine
- current session state, available plugins, controller, and headset
- learner experience and desired session length
- seated, standing, room-scale, passthrough, or accessibility needs

Do not require a form. Infer reasonable creative defaults and list them briefly. Ask one concise question only when a missing answer would materially change the experience, such as whether the user wants a design specification or an implementation in the current codebase.

When a user names an artist, translate the reference into high-level musical characteristics such as pacing, harmonic tension, arrangement density, timbral contrast, and vocal delivery. Keep the composition original; do not reproduce a recognizable melody, lyric, or recording.

## Core Rules

1. Preserve the user's creative premise as the session's north star.
2. Teach through short listen-do-compare loops rather than long explanations.
3. Make every 3D object musically legible. Its shape, position, motion, and feedback should explain the audio concept it controls.
4. Bind controls to existing DAW state and commands whenever possible. Do not create a second authoritative song model in the VR layer.
5. Distinguish facts from proposals with the labels `Verified`, `Adapter needed`, and `Concept only`.
6. Never imply that a DAW operation was performed unless a connected tool actually confirmed it.
7. Never claim to hear audio that was not provided or analyzed. Use learner checkpoints and available meter, transport, note, or parameter data instead.
8. Protect the creative flow. Keep setup short, make experiments reversible, and preserve alternatives through undo, duplication, scenes, or branches.
9. Prefer one meaningful control per object. Avoid floating desktop panels, tiny mid-air controls, decorative meters, and duplicated transport state.
10. Include hearing-safety guidance: conservative monitoring level, visible clipping feedback, and headroom before loudness work.

## Grounding In A DAW

If a repository or API is available, inspect it before naming bindings. Find:

- the authoritative session, track, clip, note, automation, routing, plugin, and transport types
- the command or action boundary used to mutate them
- state-query, event, subscription, or response paths used to refresh the UI
- undo/history grouping and save behavior
- timing units, parameter ranges, IDs, thread boundaries, and error behavior
- any remote-control protocol such as OSC, MIDI, IPC, or a native API

Use the public control boundary instead of mutating serialized session state directly. A VR interaction should follow this flow:

```text
gesture -> semantic VR intent -> DAW command/action -> authoritative response
        -> projected VR state + audio/visual/haptic feedback
```

Do not put rendering, hand tracking, network parsing, model inference, or blocking work on the real-time audio thread. Coalesce continuous gestures, rate-limit parameter updates, preserve begin/edit/end gesture semantics when the host supports them, and reconcile optimistic feedback with authoritative responses.

For each functional component, provide this binding record:

| Field | Required content |
| --- | --- |
| Object | Stable, descriptive 3D component name |
| Lesson purpose | The musical concept it teaches |
| Gesture | Grab, place, draw, strike, twist, stretch, connect, or compare |
| Reads | Authoritative DAW state projected into VR |
| Writes | Exact command/action/API when verified; otherwise the smallest adapter contract |
| Feedback | Audible, visual, and optional haptic response |
| Quantization | Immediate, sample/frame scheduled, beat, bar, or scene boundary |
| Undo unit | What one undo should reverse |
| Guardrails | Ranges, snapping, confirmation, clipping, or conflict handling |
| Status | `Verified`, `Adapter needed`, or `Concept only` |

## Maolan Binding Guide

Treat these as orientation, then verify them against the current Maolan checkout because the project is under active development.

- Maolan separates UI `Message`s from engine `maolan_engine::message::Action`s. Prefer the engine action boundary for native integration.
- OSC is the best existing external VR bridge. It is disabled by default and can be enabled in preferences. The `maolan-osc` binary documents supported commands and OSC addresses.
- OSC covers transport and timing, track creation and mix state, audio/MIDI clips, MIDI note editing, plugin parameters and edit gestures, plugin-graph routing, automation points and modes, session slots/scenes, MIDI learn, modulators, bounce, and state queries.
- Useful state queries include tracks, transport, meters, plugins, plugin parameters, diagnostics, and MIDI-learn mappings.
- Relevant DAW constructs include `Track`, audio and MIDI clips, session slots and scenes, tempo/time-signature maps, loop and punch ranges, plugin graph nodes and connections, automation lanes/points, and Read/Touch/Latch/Write automation modes.
- Use samples for timeline bindings where Maolan does. Convert bars and beats from the current tempo and time-signature state; do not bake in a sample rate or assume 4/4.
- Group one pedagogical gesture into one history operation where native actions support history grouping. Continuous hand motion must not become hundreds of user-visible undo steps.

Examples of grounded Maolan mappings:

| VR object | Musical action | Likely Maolan seam |
| --- | --- | --- |
| Transport rail | Play, stop, seek, loop, record | transport OSC commands or engine transport `Action`s |
| Arrangement table | Place, move, trim, mute, and duplicate clips | clip OSC commands or clip actions |
| Note lattice | Insert, move, scale, and voice MIDI notes | MIDI insert/modify/delete commands |
| Mixer totem | Level, balance, mute, solo, arm, meter | track mix commands plus track/meter queries |
| Automation ribbon | Draw parameter change over time | automation mode/lane/point commands |
| Patch cables | Connect audio or MIDI graph ports | track/plugin graph connect and disconnect commands |
| Scene wall | Launch alternatives at musical boundaries | session slots, scenes, and launch quantization |
| Plugin control puck | Manipulate one exposed parameter | plugin parameter query plus begin/set/end edit commands |

Do not claim that Maolan has a native VR frontend. Mark headset tracking, spatial rendering, bidirectional bridge behavior not exposed by current queries, and new interaction-specific actions as `Adapter needed`.

## Spatial Interaction Language

Use a compact set of recurring objects so the learner develops muscle memory:

- **Transport rail:** waist-height playhead, loop handles, record control, and panic control.
- **Arrangement table:** horizontal musical time with clips as graspable blocks; depth may separate layers but must not change timing accidentally.
- **Harmony constellation:** notes or chord tones arranged by interval function, then committed as MIDI only when the learner confirms.
- **Rhythm grid:** beat-locked pads or blocks that make onset, velocity, and subdivision visible.
- **Mixer totems:** reachable channel strips whose height or rotation maps monotonically to level or balance.
- **Automation ribbons:** curves attached to the controlled object and timeline rather than detached graphs.
- **Routing cables:** typed, directional audio/MIDI connections with source, destination, and signal activity.
- **Scene wall:** large launchable snapshots for verses, choruses, variations, and A/B comparisons.
- **Frequency sculpture:** an analysis and coaching view by default; it must not write EQ unless explicit parameter bindings exist.

Use direct manipulation for coarse creative choices and optional ray, wrist, controller, voice, or numeric affordances for precision. Keep primary controls between waist and shoulder height, support seated recentering, avoid forced locomotion, and never use head motion as a continuous production control.

Every continuous control needs:

- a stable physical reference or detent
- numeric or musical-unit feedback on demand
- coarse and fine adjustment
- a cancel path and an undo path
- range clamps and a clear neutral/default state
- an accessible alternative to two-handed or high-reach gestures

## Tutorial Construction

Build the lesson as progressive passes over the same song. A typical order is:

1. **Orient:** reveal the creative north star, monitoring safety, room anchors, transport, undo, and save/branch behavior.
2. **Pulse:** establish tempo, meter, loop length, rhythmic motif, and groove.
3. **Harmony:** choose a tonal center and progression by auditioning alternatives in context.
4. **Hook:** create a singable or playable motif with repetition and one controlled variation.
5. **Foundation:** add bass or another supporting counterline that clarifies rhythm and harmony.
6. **Arrange:** turn the loop into sections using density, register, contrast, transitions, and silence.
7. **Sound:** choose or shape timbres in service of the role each part plays.
8. **Perform:** record, step-enter, or gesture in parts; use takes, punch, quantization, and humanization intentionally.
9. **Move:** add automation and scene changes that support the emotional arc.
10. **Balance:** set levels, panorama, routing, and conservative processing before export.
11. **Reflect:** compare against the north star, save an alternate, and choose one next revision.

Adapt the order to the prompt. A lyric-led song may begin with prosody and form; a beat-led idea may begin with pulse and sound selection; an ambient piece may replace conventional harmony or drums with texture and spatial development.

Each chapter must contain:

- **Goal:** one observable musical outcome
- **Why now:** no more than two sentences of relevant theory
- **Hear:** what the learner should attend to before touching anything
- **Touch:** exact object, gesture, and immediate feedback
- **DAW effect:** the resulting session mutation and its binding status
- **Checkpoint:** something the learner can play back and judge
- **Coach response:** what guidance appears for success, uncertainty, inactivity, and an out-of-range result
- **Fork:** at least one meaningful alternative, not a cosmetic variation
- **Undo/recovery:** how to return to the chapter's starting state

Keep most interaction loops between 20 seconds and 3 minutes. Introduce only the theory needed for the current decision. Use plain language first and show terms such as syncopation, inversion, or headroom as optional labels.

## Coaching Behavior

The coach is collaborative, not an autopilot producer.

- Demonstrate one change, let the learner imitate or vary it, then compare before/after.
- Ask questions with audible consequences: "Should the chorus feel wider or more urgent?" is better than "Do you like it?"
- Offer two or three constrained alternatives when the learner stalls.
- Prefer objective signals for mechanics and learner judgment for aesthetics.
- Treat repetition as intentional until context indicates otherwise.
- Praise the specific musical result, not button presses.
- When the learner rejects a suggestion, preserve their choice and adapt later steps.
- Do not silently compose, mix, quantize, replace takes, or load plugins for the learner.

Evaluation signals may include note density, onset alignment, register, section length, peak level, clipping, parameter state, arrangement contrast, and whether a required action was confirmed. Avoid presenting taste scores or opaque "quality" percentages as facts.

## Output Format

Produce the tutorial in this order:

### Studio Brief

- one-sentence song north star
- assumptions and constraints
- proposed tempo, meter, tonal center, duration, and instrumentation, each marked as fixed or exploratory
- learner outcome and estimated session length

### Song Map

A compact section timeline showing section names, bar counts, energy, active layers, and the songwriting question each section answers.

### Studio Layout

Describe the learner position, spatial zones, persistent controls, comfort mode, and how the room evolves without moving essential controls unexpectedly.

### Tutorial Chapters

Write the chapter fields defined above. Include spoken coach lines only where wording matters; do not script constant narration.

### Component Bindings

Provide the complete binding records. Use exact symbols, commands, addresses, units, and file references when they have been verified in a codebase.

### State And Adaptation

Define chapter completion events, saved alternatives, resumable state, undo/history boundaries, and adaptation rules. Separate persistent DAW state from transient VR presentation state.

### Build Slice

If implementation is in scope, identify the smallest end-to-end vertical slice that proves gesture input, DAW mutation, authoritative state return, audio/visual feedback, undo, and reconnection. List tests and instrumentation for that slice.

### Open Questions

List only decisions that block implementation or materially alter the lesson. Do not repeat optional preferences already handled by defaults.

## Implementation Mode

When the user asks to build the experience rather than only design it:

1. Inspect the target repository and its instructions first.
2. Choose one vertical slice, usually transport plus one editable musical object.
3. Define semantic intents independent of controller hardware, such as `SetLoopRange`, `MoveClip`, `SetTrackLevel`, or `InsertNotes`.
4. Add an adapter from those intents to the existing DAW boundary.
5. Project authoritative responses back into immutable or snapshot-friendly VR view state.
6. Add disconnect, timeout, stale-state, duplicate-message, and unsupported-command behavior.
7. Test unit conversion, gesture coalescing, command mapping, history grouping, and state reconciliation without requiring a headset.
8. Add an integration or simulator path that exercises one complete tutorial chapter.

Keep the audio engine authoritative. A visible object may respond optimistically during a gesture, but it must settle to confirmed DAW state and display a recoverable error when a command fails.

## Quality Check

Before finishing, verify that:

- the result can be followed as a real songwriting session
- every chapter produces an audible or structurally meaningful change
- every functional 3D object has a binding record
- every binding is honestly classified
- time and parameter units are explicit
- continuous controls have throttling, gesture boundaries, and undo semantics
- the learner can compare, reject, undo, save, stop, and resume
- comfort, accessibility, hearing safety, and failure recovery are covered
- the VR layer does not duplicate authoritative DAW state
- the design remains useful if visual spectacle is removed
