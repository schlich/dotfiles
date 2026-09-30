# Forced command for homelab's config-verifications SSH account. It appends
# one verification record from `ci verify` to the sending host's log and does
# nothing else; the client's requested command is ignored.
const LOG_DIR = "/var/lib/config-verifications"
const REQUIRED = ["host" "release" "commit" "toplevel" "verified_at"]

def main [] {
    let record = (open --raw /dev/stdin | str trim | from json)
    if ($record | describe) !~ '^record' {
        error make { msg: "expected one JSON object" }
    }
    let missing = ($REQUIRED | where {|field| ($record | get --optional $field) == null })
    if ($missing | is-not-empty) {
        error make { msg: $"missing fields: ($missing | str join ', ')" }
    }
    # The host names the log file, so it must not escape the directory.
    if $record.host !~ '^[a-z0-9][a-z0-9-]*$' {
        error make { msg: $"invalid host name: ($record.host)" }
    }
    let entry = ($record | upsert received_at (date now | format date "%+"))
    $"($entry | to json --raw)\n" | save --append ($LOG_DIR | path join $"($record.host).jsonl")
    print $"recorded ($record.release) for ($record.host)"
}
