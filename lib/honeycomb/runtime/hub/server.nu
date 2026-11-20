# The honeycomb hub (module.nix): an http-nu handler that serves the phone's
# flower page and keeps two files in $env.HUB_STATE:
#   flower.json   the last snapshot a host sent (`honeycomb hub sync`)
#   actions.json  actions queued on the phone, until that host applies them
#
#   GET    /                  the page; /hub.js, /sw.js and /icon.svg beside it
#   GET    /api/flower        the snapshot, with the queued and failed actions
#   POST   /api/actions       queue {kind: archive|file, target, area?, title?}
#   DELETE /api/actions/ID    drop a queued action
#   POST   /api/sync          {flower, results} from a host; answers what is queued
#
# Tailscale Serve is the only way in: it stamps each request with the
# tailnet identity of the device that sent it, so a request without one did
# not come through Serve and is refused.

const kinds = [archive file]

def state-dir [] { $env.HUB_STATE? | default "." }
def static-dir [] { $env.HUB_STATIC? | default "." }

def read-state [name: string, empty: any] {
  let file = (state-dir | path join $name)
  if ($file | path exists) { open $file } else { $empty }
}

def write-state [name: string] {
  let value = $in
  let file = (state-dir | path join $name)
  $value | to json | save --force $"($file).tmp"
  mv --force $"($file).tmp" $file
}

def respond [status: int] {
  metadata set { merge { 'http.response': { status: $status } } }
}

def body [] {
  let raw = $in
  if $raw == null { return {} }
  try { $raw | decode utf-8 | from json } catch { try { $raw | from json } catch { {} } }
}

def manifest [] {
  {
    name: "Honeycomb"
    short_name: "Honeycomb"
    description: "The seven areas and what each holds now."
    start_url: "/"
    scope: "/"
    display: "standalone"
    background_color: "#14110f"
    theme_color: "#14110f"
    icons: [
      { src: "/icon.svg", sizes: "any", type: "image/svg+xml", purpose: "any" }
      { src: "/icon-512.png", sizes: "512x512", type: "image/png", purpose: "any maskable" }
    ]
  } | to json | metadata set { merge { 'http.response': { headers: { "Content-Type": "application/manifest+json" } } } }
}

{|req|
  let identity = ($req.headers | get --optional tailscale-user-login)
  if $identity == null {
    return ("Reach the hub through Tailscale Serve." | respond 403)
  }
  let input = $in
  match $"($req.method) ($req.path)" {
    "GET /" => { .static (static-dir) "/index.html" }
    "GET /hub.js" | "GET /sw.js" | "GET /icon.svg" | "GET /icon-512.png" => { .static (static-dir) $req.path }
    "GET /manifest.webmanifest" => { manifest }
    "GET /api/flower" => {
      {
        flower: (read-state flower.json null)
        pending: (read-state actions.json [])
        failed: (read-state failed.json [])
      }
    }
    "POST /api/actions" => {
      let action = ($input | body)
      if ($action.kind? | default "") not-in $kinds or ($action.target? | default "") == "" {
        return ({ error: $"an action needs a kind \(($kinds | str join ', ')\) and a target" } | respond 400)
      }
      if $action.kind == "file" and ($action.area? | default "") == "" {
        return ({ error: "filing needs an area" } | respond 400)
      }
      let queued = {
        id: (random uuid)
        kind: $action.kind
        target: $action.target
        area: ($action.area? | default null)
        title: ($action.title? | default "")
        at: (date now | format date "%+")
        by: $identity
      }
      read-state actions.json [] | append $queued | write-state actions.json
      $queued | respond 201
    }
    $route if ($route | str starts-with "DELETE /api/actions/") => {
      let id = ($route | str replace "DELETE /api/actions/" "")
      read-state actions.json [] | where id != $id | write-state actions.json
      null | respond 204
    }
    "POST /api/sync" => {
      let sync = ($input | body)
      if ($sync.flower? | default null) != null { $sync.flower | write-state flower.json }
      let results = ($sync.results? | default [])
      let settled = ($results | get --optional id | default [])
      let queue = (read-state actions.json [])
      let failed = ($results | where not ok | each {|result|
        $queue | where id == $result.id | get 0? | default { id: $result.id } | insert note $result.note
      })
      read-state failed.json [] | append $failed | last 12 | write-state failed.json
      let pending = ($queue | where id not-in $settled)
      $pending | write-state actions.json
      { pending: $pending }
    }
    _ => { "Not found" | respond 404 }
  }
}
