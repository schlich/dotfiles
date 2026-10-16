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

    # bash-guard still judges an ordinary command through the override.
    let guard = (run-jev $script bash-guard { tool_name: Bash, tool_input: { command: "cat notes.txt | grep todo" } } $vars | get stdout | from json)
    $failures = ($failures | append (expect "bash-guard denies a rewritable pipeline" $guard.hookSpecificOutput.permissionDecision deny))

    job kill $server_job
    rm -rf $tmp
    if ($failures | is-not-empty) {
        error make --unspanned { msg: $"($failures | length) jev test\(s\) failed: ($failures | str join '; ')" }
    }
    print "All jev tests passed."
}
