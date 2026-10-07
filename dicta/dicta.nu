# dicta: a reporter's tape recorder for reviewing agent reports.
#
# `dicta toggle` (Mod+M) starts a take. It notes the focused window, its niri
# workspace and working directory, and the primary selection (the passage
# you are reacting to), then records the microphone until Mod+M again stops
# it; `dicta cancel` (Mod+Shift+M) discards it. Stopping transcribes the take
# with whisper.cpp. A pending take rides along with your next prompt to an
# agent running inside the window you recorded in (`dicta hook`, a Claude
# Code UserPromptSubmit hook); `dicta brief` hands takes to anything else.

# Each take records in its own systemd user unit, so it outlives the
# keybinding's process, a forgotten take stops itself, and the unit's
# ExecStopPost transcribes it however it stopped.
const unit_prefix = "dicta-take-"

def data-dir [] {
  $env.DICTA_DIR? | default (($env.XDG_DATA_HOME? | default $"($env.HOME)/.local/share") | path join dicta)
}

def takes-dir [] { data-dir | path join takes }

def runtime-dir [] {
  $env.XDG_RUNTIME_DIR? | default $"/tmp/dicta-($env.USER)" | path join dicta
}

def recording-file [] { runtime-dir | path join recording.json }

def take-file [id: string, extension: string] {
  takes-dir | path join $"($id).($extension)"
}

# Write through a temporary file so the bar widget and the hook never read a
# half-written record.
def save-json [file: path] {
  let value = $in
  mkdir ($file | path dirname)
  let partial = $"($file).partial"
  $value | to json | save --force $partial
  mv --force $partial $file
}

def read-json [file: path] {
  if ($file | path exists) { try { open --raw $file | from json } catch { null } } else { null }
}

def load-take [id: string] { read-json (take-file $id json) }

def save-take [take: record] { $take | save-json (take-file $take.id json) }

def drop-take [id: string] {
  rm --force (take-file $id json) (take-file $id wav)
}

def all-takes [] {
  let directory = (takes-dir)
  if not ($directory | path exists) { return [] }
  glob ($directory | path join "*.json") | each {|file| read-json $file } | compact | sort-by id
}

def recording [] { read-json (recording-file) }

def now-seconds [] { date now | format date '%s' | into int }

def timestamp [] { date now | format date '%+' }

# The bar widget polls this file; see noctalia/widget.luau.
def publish-status [] {
  let takes = (all-takes)
  let current = (recording)
  let transcribing = ($takes | where status == "transcribing" | length)
  let mode = if $current == null {
    if $transcribing > 0 { "transcribing" } else { "idle" }
  } else if ($current.stopping? | default false) {
    "transcribing"
  } else {
    "recording"
  }
  {
    mode: $mode
    started: ($current.started? | default 0)
    pending: ($takes | where status == "pending" | length)
    transcribing: $transcribing
  } | save-json (runtime-dir | path join status.json)
}

def notify [summary: string, body: string = ""] {
  ^notify-send --app-name dicta $summary $body | complete | ignore
}

def niri-json [query: string] {
  let response = (^niri msg --json $query | complete)
  if $response.exit_code != 0 { return null }
  $response.stdout | from json
}

# The focused window's working directory, when it says something: terminals
# report their project, while apps like Claude Desktop sit in the home
# directory.
def window-directory [pid: any] {
  if $pid == null { return null }
  let response = (^readlink $"/proc/($pid)/cwd" | complete)
  let directory = ($response.stdout | str trim)
  if $response.exit_code != 0 or $directory in ["" "/" $env.HOME] { null } else { $directory }
}

# The passage you are reacting to: whatever is selected when the take starts.
# Wayland keeps the primary selection after you click away, so a selection
# already attached to an earlier take is not repeated.
def selection [] {
  let response = (^timeout 2 wl-paste --primary --no-newline --type text | complete)
  if $response.exit_code != 0 { return null }
  let text = ($response.stdout | str trim)
  let previous = (all-takes | each {|take| $take.quote? } | compact | last 1 | get 0?)
  if ($text | is-empty) or $text == $previous { null } else { $text | str substring 0..3999 }
}

def snapshot [] {
  let window = (niri-json focused-window)
  let workspace = if $window == null { null } else {
    niri-json workspaces | default [] | where id == $window.workspace_id | get 0?
  }
  {
    app: $window.app_id?
    title: $window.title?
    pid: $window.pid?
    workspace: $workspace.name?
    directory: (window-directory $window.pid?)
    quote: (selection)
  }
}

# Start a take, or stop the one recording.
def "main toggle" [] {
  if (recording) == null { main start } else { main stop }
}

# Start a take: note what is on screen, then record the microphone.
def "main start" [] {
  if (recording) != null { return }
  let context = (snapshot)
  let id = (date now | format date '%Y%m%dT%H%M%S')
  let unit = $"($unit_prefix)($id)"
  let audio = (take-file $id wav)
  save-take ({ id: $id, at: (timestamp), status: "recording", ...$context, audio: $audio, transcript: null })
  # Claim the recorder before the unit starts, so a recorder that fails at
  # once still finds its take when ExecStopPost runs.
  { id: $id, unit: $unit, started: (now-seconds) } | save-json (recording-file)
  publish-status
  let response = (
    ^systemd-run
      --user
      --quiet
      --collect
      --unit $unit
      --description $"dicta take ($id)"
      --property $"RuntimeMaxSec=($env.DICTA_MAX_TAKE? | default '15min')"
      --property "TimeoutStopSec=infinity"
      --property $"ExecStopPost=($env.DICTA_SELF? | default 'dicta') finalize ($id)"
      --setenv $"DICTA_DIR=(data-dir)"
      (which pw-record | get 0.path)
      --rate 16000
      --channels 1
      --format s16
      $audio
    | complete
  )
  if $response.exit_code != 0 {
    rm --force (recording-file)
    drop-take $id
    publish-status
    notify "Could not start recording" ($response.stderr | str trim)
  }
}

# Stop the take recording; its unit then transcribes it.
def "main stop" [] {
  let current = (recording)
  if $current == null { return }
  $current | upsert stopping true | save-json (recording-file)
  publish-status
  let stopped = (^systemctl --user stop --no-block $current.unit | complete)
  # A recorder that already exited has run its ExecStopPost or never will.
  if $stopped.exit_code != 0 { main finalize $current.id }
}

# Discard the take recording.
def "main cancel" [] {
  let current = (recording)
  if $current == null { return }
  rm --force (recording-file)
  drop-take $current.id
  ^systemctl --user stop --no-block $current.unit | complete | ignore
  publish-status
  notify "Take discarded"
}

# Transcribe a stopped take. The recorder unit runs this as ExecStopPost.
def "main finalize" [id: string] {
  let current = (recording)
  if $current != null and $current.id == $id { rm --force (recording-file) }
  let take = (load-take $id)
  if $take == null or $take.status != "recording" {
    publish-status
    return
  }
  transcribe-take $take
}

# Transcribe a take again, such as one that failed.
def "main retry" [id: string] {
  let take = (load-take $id)
  if $take == null { error make { msg: $"no take ($id)" } }
  transcribe-take $take
}

# whisper.cpp marks silence and noise with bracketed or parenthesised tags.
def transcribe [audio: path] {
  if not ($audio | path exists) {
    return { ok: false, text: "", error: "no audio was recorded" }
  }
  let response = (
    ^whisper-cli
      --model $env.DICTA_MODEL
      --file $audio
      --language ($env.DICTA_LANGUAGE? | default "en")
      --threads ($env.DICTA_THREADS? | default "4")
      --no-timestamps
      --no-prints
    | complete
  )
  if $response.exit_code != 0 {
    return { ok: false, text: "", error: ($response.stderr | str trim | lines | last 3 | str join "\n") }
  }
  let text = (
    $response.stdout
    | lines
    | str trim
    | where {|line| $line != "" and $line !~ '^[\[\(].*[\]\)]$' }
    | str join " "
  )
  { ok: true, text: $text, error: null }
}

def transcribe-take [take: record] {
  save-take ($take | upsert status "transcribing")
  publish-status
  let result = (transcribe $take.audio)
  # The take may have been dropped while whisper ran.
  if (load-take $take.id) == null {
    publish-status
    return
  }
  if not $result.ok {
    save-take ($take | upsert status "failed" | upsert error $result.error)
    publish-status
    notify "Transcription failed" $"($result.error)\nRetry with `dicta retry ($take.id)`."
  } else if ($result.text | is-empty) {
    drop-take $take.id
    publish-status
    notify "Nothing heard" "The take was silent, so it was discarded."
  } else {
    save-take ($take | upsert status "pending" | upsert transcript $result.text | upsert error null)
    publish-status
    notify "Take saved" ($result.text | str substring 0..119)
  }
}

def mark-delivered [takes: list, recipient: string] {
  for take in $takes {
    save-take ($take | upsert status "delivered" | upsert delivered_to $recipient | upsert delivered_at (timestamp))
  }
  publish-status
}

def brief [takes: list] {
  let header = [
    "## Spoken review notes (dicta)"
    ""
    "The user recorded these voice notes while reviewing your work. They are"
    "machine transcriptions, so expect misheard words. A quote is the text the"
    "user had selected when they started speaking; the note is about it."
  ]
  let entries = (
    $takes | each {|take|
      let when = ($take.at | into datetime | format date '%H:%M')
      let place = ([$take.app? $take.workspace? $take.directory?] | compact | str join " · ")
      let quote = if ($take.quote? | is-empty) { [] } else {
        $take.quote | lines | each {|line| $"> ($line)" } | append ""
      }
      ["" $"### ($when) — ($place)" "" ...$quote ($take.transcript? | default "(not transcribed yet)")] | str join "\n"
    }
  )
  [...$header ...$entries] | str join "\n"
}

# The process and its ancestors, from /proc.
def lineage [pid: int] {
  mut chain = []
  mut current = $pid
  while $current > 1 {
    $chain = ($chain | append $current)
    let stat = $"/proc/($current)/stat"
    if not ($stat | path exists) { break }
    # After the parenthesised command name come the state and the parent pid.
    $current = (open --raw $stat | str replace --regex '^.*\) ' '' | split row ' ' | get 1 | into int)
  }
  $chain
}

# Claude Code UserPromptSubmit hook: attach the pending takes recorded in the
# window this session runs under, which is the app or terminal you were
# reading when you spoke. It never blocks the prompt.
def "main hook" [] {
  let payload = $in
  try {
    let event = ($payload | into string | from json)
    let ancestors = (lineage $nu.pid)
    let horizon = ((date now) - ($env.DICTA_HOOK_WINDOW? | default "12hr" | into duration))
    let takes = (
      all-takes
      | where status == "pending"
      | where {|take| $take.pid? in $ancestors and ($take.at | into datetime) > $horizon }
    )
    if ($takes | is-not-empty) {
      let output = {
        hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: (brief $takes) }
        systemMessage: $"dicta: attached ($takes | length) spoken note\(s\) to this prompt"
      }
      mark-delivered $takes ($event.session_id? | default "claude-code")
      $output | to json --raw | print
    }
  } catch {|error|
    print --stderr $"dicta hook: ($error.msg)"
  }
}

# Takes not yet delivered, or every take with --all.
def "main ls" [--all (-a)] {
  all-takes
  | where {|take| $all or $take.status != "delivered" }
  | each {|take|
      {
        id: $take.id
        status: $take.status
        at: ($take.at | into datetime)
        place: ([$take.app? $take.workspace?] | compact | str join " · ")
        quote: ($take.quote? | default "" | str substring 0..39)
        transcript: ($take.transcript? | default "" | str substring 0..59)
      }
    }
}

# Pending takes (or the given ids) as Markdown for any agent. --copy puts
# them on the clipboard; --mark records them as delivered.
def "main brief" [...ids: string, --copy (-c), --mark (-m)] {
  let takes = if ($ids | is-empty) {
    all-takes | where status == "pending"
  } else {
    all-takes | where id in $ids
  }
  if ($takes | is-empty) {
    print --stderr "No pending takes."
    return
  }
  let text = (brief $takes)
  if $mark { mark-delivered $takes "manual" }
  if $copy {
    $text | ^wl-copy
    notify "Notes copied" $"($takes | length) take\(s\) on the clipboard."
  } else {
    $text
  }
}

# Play a take's recording.
def "main play" [id: string] {
  let take = (load-take $id)
  if $take == null { error make { msg: $"no take ($id)" } }
  ^pw-play $take.audio
}

# Delete a take and its recording.
def "main drop" [id: string] {
  drop-take $id
  publish-status
}

# The recorder state the bar widget shows.
def "main status" [] {
  publish-status
  read-json (runtime-dir | path join status.json)
}

def main [] {
  print "Usage: dicta (toggle | start | stop | cancel | ls [--all] | brief [IDS] [--copy] [--mark] | play ID | retry ID | drop ID | status | hook)"
}
