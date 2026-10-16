# jev against a stub /v1/systemone server, which records every request it
# receives, so the test sees exactly what would leave the machine:
#   nu --no-config-file tests/jev.nu jev/jev.nu jev/questions.nuon

# A Python stub, since Nushell has no HTTP server. It answers each question
# jev asks with a confident value and appends {path, authorization, body}
# for every request to the log.
const stub_server = '
import http.server, json, sys

log_path, port_path = sys.argv[1], sys.argv[2]
answers = {
    "failure_class": {"type": "choice", "choice": "typo_or_not_found", "confidence": 0.95},
    "needs_diagnosis": {"type": "noul", "noul": 0.1},
    "nushell_rewrite": {"type": "noul", "noul": 0.9},
    "ending": {"type": "choice", "choice": "finished", "confidence": 0.9},
    "delivery_only": {"type": "noul", "noul": 0.9},
    "activation_step": {"type": "noul", "noul": 0.1},
    "remaining_work": {"type": "score", "score": 0.2, "confidence": 0.9},
    "difficulty": {"type": "choice", "choice": "medium", "confidence": 0.9},
    "error_cost": {"type": "choice", "choice": "low", "confidence": 0.9},
}

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(log_path, "a") as log:
            log.write(json.dumps({
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "body": body,
            }) + "\n")
        reply = json.dumps({
            "model": body["model"],
            "answers": {name: answers[name] for name in body["questions"]},
            "usage": {"input_tokens": 1, "output_tokens": 0},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(port_path, "w") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
'

def expect [name: string, actual: any, expected: any] {
    if $actual == $expected {
        print $"ok   ($name)"
        []
    } else {
        print $"FAIL ($name)\n     got      ($actual | to nuon)\n     expected ($expected | to nuon)"
        [$name]
    }
}

# Requests the stub has received so far.
def requests [log: path] {
    if not ($log | path exists) {
        return []
    }
    open --raw $log | lines | where {|line| $line | str trim | is-not-empty } | each { from json }
}

# Run a jev subcommand on a JSON payload in a fresh process, as the hooks do,
# without the caller's TypeSafe key and with `vars` added to the environment.
def run-jev [script: path, command: string, payload: record, vars: record] {
    hide-env --ignore-errors TYPESAFE_API_KEY
    with-env $vars {
        $payload | to json --raw | ^$nu.current-exe --no-config-file --stdin $script $command | complete
    }
}

def main [script: path, questions: path] {
    let script = ($script | path expand)
    let tmp = (mktemp --directory)
    let log = ($tmp | path join requests.jsonl)
    let port_file = ($tmp | path join port)
    let server = ($tmp | path join stub.py)
    $stub_server | save $server
    let server_job = (job spawn { ^python3 $server $log $port_file })

    mut waited = 0
    while not ($port_file | path exists) and $waited < 100 {
        sleep 100ms
        $waited += 1
    }
    if not ($port_file | path exists) {
        error make --unspanned { msg: "the stub server did not start" }
    }
    let base_url = $"http://127.0.0.1:(open --raw $port_file | str trim)"

    # secretspec is not on the test's PATH, so any keyring lookup fails.
    let vars = {
        TYPESAFE_BASE_URL: $base_url
        JEV_QUESTIONS: ($questions | path expand)
        JEV_USAGE_LOG: ($tmp | path join usage.jsonl)
    }
    mut failures = []

    # An ordinary failure is sent to the override, without any key.
    let result = (run-jev $script triage-gate { command: "gti status", cwd: "/tmp", exit_code: 127 } $vars)
    let route = ($result.stdout | from json)
    $failures = ($failures | append (expect "triage-gate asks the TYPESAFE_BASE_URL server" ($route | select route class) { route: skip, class: typo_or_not_found }))
    let sent = (requests $log)
    $failures = ($failures | append (expect "the request goes to /v1/systemone" ($sent | get path) ["/v1/systemone"]))
    $failures = ($failures | append (expect "the stored key is not sent to another server" ($sent | get authorization) [null]))
    $failures = ($failures | append (expect "only the command line, cwd, and exit code are sent" ($sent.0.body.state | columns | sort) [command cwd exit_code]))
    let ledger = (open --raw ($vars.JEV_USAGE_LOG) | lines | each { from json })
    $failures = ($failures | append (expect "the ledger names the endpoint" ($ledger | get endpoint) [$"($base_url)/v1/systemone"]))

    # A key in the environment is the caller's choice, so it is sent.
    let keyed = ($vars | merge { TYPESAFE_API_KEY: "test-key" })
    run-jev $script triage-gate { command: "gti status", cwd: "/tmp", exit_code: 127 } $keyed | ignore
    $failures = ($failures | append (expect "TYPESAFE_API_KEY is sent as a bearer token" ((requests $log) | last | get authorization) "Bearer test-key"))

    # A trailing slash on the root does not double the path separator.
    let slashed = ($vars | merge { TYPESAFE_BASE_URL: $"($base_url)/" })
    run-jev $script triage-gate { command: "gti status", cwd: "/tmp", exit_code: 127 } $slashed | ignore
    $failures = ($failures | append (expect "a trailing slash on TYPESAFE_BASE_URL is ignored" ((requests $log) | last | get path) "/v1/systemone"))

    # Credential assignments in every shell form are never sent.
    let credential_lines = [
        '$env.OPENAI_API_KEY = "sk-test"'
        'GITHUB_TOKEN=ghp_test gh pr list'
        'export AWS_SECRET_ACCESS_KEY=test'
    ]
    let before = ((requests $log) | length)
    for line in $credential_lines {
        let gate = (run-jev $script triage-gate { command: $line, cwd: "/tmp", exit_code: 1 } $vars | get stdout | from json)
        $failures = ($failures | append (expect $"triage-gate withholds `($line)`" $gate { route: triage, reason: "credential assignment is not sent to Jev" }))
        let guard = (run-jev $script bash-guard { tool_name: Bash, tool_input: { command: $line } } $vars | get stdout | from json)
        $failures = ($failures | append (expect $"bash-guard asks the user about `($line)`" $guard.hookSpecificOutput.permissionDecision ask))
    }
    $failures = ($failures | append (expect "no credential line reached the server" ((requests $log) | length) $before))

    # classify-task sends only the task, and never one that assigns a credential.
    let before = ((requests $log) | length)
    let labels = (run-jev $script classify-task { task: "Review a small Python change" } $vars)
    $failures = ($failures | append (expect "classify-task returns the difficulty answer" ($labels.stdout | from json | get answers.difficulty.choice) "medium"))
    $failures = ($failures | append (expect "classify-task sends only the task" ((requests $log) | last | get body.state) { task: "Review a small Python change" }))
    let withheld = (run-jev $script classify-task { task: "export GITHUB_TOKEN=ghp_test and deploy" } $vars)
    $failures = ($failures | append (expect "classify-task fails on a credential assignment" ($withheld.exit_code != 0) true))
    $failures = ($failures | append (expect "the credential task never reached the server" ((requests $log) | length) ($before + 1)))

    # bash-guard still judges an ordinary command through the override.
    let guard = (run-jev $script bash-guard { tool_name: Bash, tool_input: { command: "cat notes.txt | grep todo" } } $vars | get stdout | from json)
    $failures = ($failures | append (expect "bash-guard denies a rewritable pipeline" $guard.hookSpecificOutput.permissionDecision deny))

    # session-triage reads the desktop app's metadata and Claude Code's
    # transcripts, and sends Jev only a session's ending.
    let meta_dir = ($tmp | path join sessions org account)
    let transcripts = ($tmp | path join projects proj)
    mkdir $meta_dir $transcripts
    let session = {|id, archived| { sessionId: $"local_($id)", title: $id, cwd: $tmp, isArchived: $archived, lastActivityAt: 1790000000000 } }
    do $session finished false | save ($meta_dir | path join local_finished.json)
    do $session cleared false | save ($meta_dir | path join local_cleared.json)
    do $session old true | save ($meta_dir | path join local_old.json)
    let line = {|role, content| { type: $role, message: { content: $content } } | to json --raw }
    [
        (do $line user "Fix the hook")
        (do $line assistant [{ type: text, text: "Fixed and landed.\nexport GITHUB_TOKEN=ghp_secret" }])
    ] | str join "\n" | save ($transcripts | path join finished.jsonl)
    (do $line user "<command-name>/clear</command-name>") | save ($transcripts | path join cleared.jsonl)
    (do $line assistant "Archived work") | save ($transcripts | path join old.jsonl)
    let triage_vars = ($vars | merge {
        JEV_SESSION_METADATA_DIR: ($tmp | path join sessions)
        JEV_TRANSCRIPT_DIR: ($tmp | path join projects)
    })
    let before = ((requests $log) | length)
    let triage = (with-env $triage_vars { "" | ^$nu.current-exe --no-config-file --stdin $script session-triage --json | complete })
    let rows = ($triage.stdout | from json)
    $failures = ($failures | append (expect "session-triage skips archived sessions" ($rows | get session | sort) [local_cleared local_finished]))
    $failures = ($failures | append (expect "a session without conversation is archived" ($rows | where session == local_cleared | get decision) [archive]))
    $failures = ($failures | append (expect "a finished session is archived" ($rows | where session == local_finished | select decision reason) [{ decision: archive, reason: finished }]))
    let triage_sent = ((requests $log) | skip $before)
    $failures = ($failures | append (expect "only the session with a conversation reaches Jev" ($triage_sent | length) 1))
    $failures = ($failures | append (expect "only the session's ending is sent" ($triage_sent.0.body.state.session | columns | sort) [folder last_assistant_message last_user_message stopped_mid_turn]))
    $failures = ($failures | append (expect "credential assignments in a reply are withheld" ($triage_sent.0.body.state.session.last_assistant_message | str contains "ghp_secret") false))

    job kill $server_job
    rm -rf $tmp
    if ($failures | is-not-empty) {
        error make --unspanned { msg: $"($failures | length) jev test\(s\) failed: ($failures | str join '; ')" }
    }
    print "All jev tests passed."
}
