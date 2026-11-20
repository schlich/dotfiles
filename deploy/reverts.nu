# Read the revert log that nixos-switch-main keeps: every staged switch
# that did not become the boot default, why, and the report it wrote. The
# tally of breached checks is the feedback loop: the check that reverts most
# often marks the gap a pre-deploy check should close next.
#
# On a workstation, `notify` also fetches each canary's new entries over ssh,
# keeps them under ~/.local/state/deploy-reverts, and announces each new
# revert once, offering to open an agent on its report.

# Where nixos-switch-main keeps its log; DEPLOY_STATE points elsewhere for a
# trial run.
def state [] { $env.DEPLOY_STATE? | default '/var/lib/nixos-switch-main' }

# system-switch.nix replaces these with store paths; the DEPLOY_REVERTS_*
# variables override them for tests.
const default_questions = "@questions@"
const default_jev = "@jev@"

# Mirrors jev's credential filter: report lines that assign one, as a
# journal excerpt might, are never sent to Jev.
const credential_pattern = '(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)[A-Z0-9_]*\s*='

def entries [log: string] {
    if not ($log | path exists) { return [] }
    open --raw $log | lines | where $it != '' | each { from json }
}

def cache-dir [] {
    $env.XDG_STATE_HOME? | default ($env.HOME | path join .local state) | path join deploy-reverts
}

def revert-rows [since: any, all: bool] {
    let local = (entries ((state) | path join reverts.jsonl))
    let fetched = if $all { glob ((cache-dir) | path join '*.jsonl') | each {|log| entries $log } | flatten } else { [] }
    let rows = ($local ++ $fetched | sort-by at)
    if $since == null { $rows } else {
        let after = ($since | into datetime)
        $rows | where {|row| ($row.at | into datetime) > $after }
    }
}

# List this host's reverts and which checks caused them.
def main [
    --json # print the entries as JSON, each with its report's text
    --since: string # only entries after this RFC 3339 time
    --all # add the canaries' entries this workstation has fetched
] {
    let rows = (revert-rows $since $all)
    if $json {
        return ($rows | each {|row| $row | insert report_text (try { open --raw $row.report } catch { '' }) } | to json)
    }
    if ($rows | is-empty) {
        print "No reverts recorded."
        return
    }
    print ($rows | select at host phase breached subject author | update breached { str join ', ' })
    print "Checks that caused reverts, most frequent first; each is a gap for a pre-deploy check:"
    print ($rows | get breached | flatten | uniq --count | sort-by count --reverse | rename check reverts)
}

# Ask Jev what caused one revert, from its phase, breached probes, and
# report. The report is clipped and stripped of credential assignments.
def judge-cause [row: record, config: record] {
    let report = (try { open --raw $row.report } catch { '' })
    let report = ($report | lines | where {|line| $line !~ $credential_pattern } | str join "\n")
    let report = if ($report | str length) > $config.max_report_chars { $report | str substring 0..($config.max_report_chars - 1) } else { $report }
    let state = { revert: { phase: $row.phase, breached: $row.breached, activated: $row.activated, report: $report } }
    let jev = ($env.DEPLOY_REVERTS_JEV? | default $default_jev)
    let result = ({ state: $state, questions: $config.questions } | to json --raw | run-external $jev "ask" | complete)
    if $result.exit_code != 0 {
        let detail = ($result.stderr | lines | where {|line| $line | str trim | is-not-empty } | get -o 0 | default "no output")
        error make { msg: $"jev ask exited ($result.exit_code): ($detail)" }
    }
    let answers = ($result.stdout | from json).answers
    {
        cause: (if $answers.cause.confidence >= $config.min_confidence { $answers.cause.choice } else { "unsure" })
        catchable: $answers.precheck_catchable.noul
    }
}

# Tally reverts by root cause, judged by Jev from each report, where the
# plain listing tallies the probe that tripped. Causes are ranked by how
# many reverts a pre-deploy check could have caught, which names the next
# check to add; a revert Jev cannot judge is listed with its error.
def "main causes" [
    --json # print each revert's judgment and the tally as JSON
    --since: string # only entries after this RFC 3339 time
    --all # add the canaries' entries this workstation has fetched
] {
    let config = (open ($env.DEPLOY_REVERTS_QUESTIONS? | default $default_questions)).deploy_reverts
    let judged = (revert-rows $since $all | each {|row|
        let base = { id: $row.id, at: $row.at, host: $row.host, phase: $row.phase, subject: $row.subject }
        $base | merge (try { judge-cause $row $config | insert error null } catch {|err|
            { cause: null, catchable: null, error: $err.msg }
        })
    })
    let tally = (
        $judged
        | where cause != null
        | group-by cause --to-table
        | each {|group| {
            cause: $group.cause
            reverts: ($group.items | length)
            catchable: ($group.items | where catchable >= $config.min_catchable | length)
        } }
        | sort-by {|row| -1 * $row.catchable } {|row| -1 * $row.reverts } cause
    )
    if $json {
        return ({ reverts: $judged, causes: $tally } | to json)
    }
    if ($judged | is-empty) {
        print "No reverts recorded."
        return
    }
    print ($judged | select at host phase cause catchable subject error)
    print "Causes, most often catchable before deployment first; the top one names the next pre-deploy check:"
    print $tally
}

# Seconds an ssh fetch from one canary may take before it is killed.
def fetch-timeout [] { $env.DEPLOY_REVERTS_FETCH_TIMEOUT? | default '60' }

# The name a canary's cache files go by: its host, without the
# ssh://, user, or port that its destination may carry.
def source-name [destination: string] {
    $destination | str replace --regex '^ssh://' '' | str replace --regex '^[^@]*@' '' | str replace --regex ':[0-9]+$' ''
}

def seen-file [cache: string, source: string] { $cache | path join $"($source).seen" }

def last-seen [cache: string, source: string] {
    let file = (seen-file $cache $source)
    if ($file | path exists) { open --raw $file | str trim } else { '1970-01-01T00:00:00+00:00' }
}

# Announce the newest unseen revert from one source. It is marked seen
# first, so a notification that never gets an answer is not repeated. The
# notification waits for its answer in a transient unit of its own, so this
# oneshot, and an activation that restarts it, never wait on the user.
def announce [cache: string, source: string, rows: list] {
    let seen = (last-seen $cache $source | into datetime)
    let fresh = ($rows | where {|row| ($row.at | into datetime) > $seen } | sort-by at)
    if ($fresh | is-empty) { return }
    let latest = ($fresh | last)
    $latest.at | save --force (seen-file $cache $source)

    let earlier = (($fresh | length) - 1)
    let spawned = (^systemd-run --user --collect --quiet --description $"Answer the deploy revert notice for ($source)" $"--setenv=PATH=([$env.PATH] | flatten | str join (char esep))" -- $nu.current-exe --no-config-file $env.CURRENT_FILE prompt $source $latest.id --earlier $earlier | complete)
    if $spawned.exit_code != 0 {
        print --stderr $"Could not announce ($source)'s revert ($latest.id): ($spawned.stderr | str trim)"
    }
}

def find-row [cache: string, source: string, id: string] {
    let logs = [((state) | path join reverts.jsonl) ($cache | path join $"($source).jsonl")]
    $logs | each {|log| entries $log } | flatten | where id == $id | get -o 0
}

# Show one revert's notification and act on its answer. `notify` starts
# this in a transient unit; it waits until the notification is answered or
# dismissed.
def "main prompt" [
    source: string # the host, or the canary's cache name, that reverted
    id: string # the revert's id
    --earlier: int = 0 # how many unseen reverts came before it
] {
    let latest = (find-row (cache-dir) $source $id)
    if $latest == null {
        error make --unspanned { msg: $"No revert ($id) recorded for ($source)." }
    }
    let verb = if $latest.activated { "reverted" } else { "rejected" }
    let more = if $earlier > 0 { $" \(and ($earlier) earlier\)" } else { "" }
    let body = $"($latest.phase): ($latest.breached | str join ', '). By ($latest.author)($more)."
    let choice = (^notify-send --app-name "Deploy revert" --icon dialog-warning --urgency critical --wait --action "investigate=Investigate with an agent" --action "open=Open report" $"($latest.host) ($verb) ($latest.subject)" $body | complete | get stdout | str trim)
    let dotfiles = ($env.HOME | path join dotfiles)
    match $choice {
        "investigate" => {
            let prompt = $"Read the deploy revert report at ($latest.report). Explain why ($latest.host) ($verb) revision ($latest.rev), and propose the pre-deploy check in this repository that would have caught it. Do not dispatch, land, or activate anything without asking."
            ^niri msg action spawn -- terminal --directory $dotfiles ai $prompt
        }
        "open" => { ^niri msg action spawn -- terminal --directory $dotfiles editor $latest.report }
        _ => {}
    }
}

# Announce new reverts on this host and on each canary named, by its ssh
# destination, such as ssh://homelab:2222. An unreachable or hanging canary
# is skipped until the next run once its fetch times out.
def "main notify" [...destinations: string] {
    let cache = (cache-dir)
    mkdir $cache
    announce $cache (sys host | get hostname) (entries ((state) | path join reverts.jsonl))
    let limit = (fetch-timeout)
    for destination in $destinations {
        let source = (source-name $destination)
        # Quoted, since the remote login shell parses the command line.
        let since = (last-seen $cache $source)
        let result = (^timeout --kill-after=5 $limit ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 $destination deploy-reverts --json --since $"'($since)'" | complete)
        if $result.exit_code in [124 137] {
            print --stderr $"Could not read ($source)'s reverts: ssh to ($destination) gave no answer within ($limit) seconds"
            continue
        }
        if $result.exit_code != 0 {
            print --stderr $"Could not read ($source)'s reverts: ssh to ($destination) exited ($result.exit_code): ($result.stderr | str trim)"
            continue
        }
        let reports = ($cache | path join reports $source)
        mkdir $reports
        let rows = ($result.stdout | from json | each {|row|
            let report = ($reports | path join $"($row.id).md")
            $row.report_text | save --force $report
            $row | reject report_text | upsert report $report
        })
        let log = ($cache | path join $"($source).jsonl")
        for row in $rows {
            $"($row | to json --raw)\n" | save --append $log
        }
        announce $cache $source $rows
    }
}
