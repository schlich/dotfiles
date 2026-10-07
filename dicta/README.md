# dicta

The cartoon reporter's tape recorder, for reviewing what your coding agents
did. Read an agent's report, select the line that bothers you, press a key,
and say what is wrong with it. The take is transcribed and handed to the
agent with your next prompt.

The name comes from the Dictaphone, the recorder those reporters carried, and
from the Latin _dicta_, "things said". In law, _obiter dicta_ are remarks made
in passing, which is what review notes are.

## Use

| Key                 | In        | Does                                                        |
| ------------------- | --------- | ----------------------------------------------------------- |
| Mod+M               | idle      | Start a take about the focused window and the selected text |
| Mod+M               | recording | Stop the take and transcribe it                             |
| Mod+Shift+M         | recording | Discard the take                                            |
| Click / right-click | bar light | Toggle recording / copy pending notes                       |

The Noctalia bar shows the recorder's mode: `REC 0:12` with the keys that
work while recording, `transcribing`, or the number of takes still pending.

A take records:

- the focused window, its niri workspace, and its working directory
- the primary selection, quoted as the passage the note is about
- the audio, transcribed locally with whisper.cpp (`base.en`)

## Delivery

A Claude Code `UserPromptSubmit` hook (`dicta hook`) attaches pending takes
to the next prompt sent from a session running under the window you recorded
in, and marks them delivered. In a terminal that is the session in that
terminal; in Claude Desktop it is whichever session you prompt next. Takes
older than `DICTA_HOOK_WINDOW` (default 12 hours) are left for you.

Takes recorded anywhere else, such as a pull request in a browser, wait for
you: `dicta ls` lists them and `dicta brief --copy --mark` puts them on the
clipboard as Markdown.

## Commands

```
dicta toggle | start | stop | cancel
dicta ls [--all]
dicta brief [ID ...] [--copy] [--mark]
dicta play ID | retry ID | drop ID
dicta status
dicta hook
```

Takes live in `$XDG_DATA_HOME/dicta/takes/` as one JSON record and one WAV
file each. Each recording runs as a `dicta-take-*` systemd user unit that stops
itself after `DICTA_MAX_TAKE` (default 15 minutes).
