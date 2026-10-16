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

def entries [log: string] {
    if not ($log | path exists) { return [] }
    open --raw $log | lines | where $it != '' | each { from json }
}

def cache-dir [] {
    $env.XDG_STATE_HOME? | default ($env.HOME | path join .local state) | path join deploy-reverts
}

# List this host's reverts and which checks caused them.
def main [
    --json # print the entries as JSON, each with its report's text
    --since: string # only entries after this RFC 3339 time
    --all # add the canaries' entries this workstation has fetched
] {
    let local = (entries ((state) | path join reverts.jsonl))
    let fetched = if $all { glob ((cache-dir) | path join '*.jsonl') | each {|log| entries $log } | flatten } else { [] }
    let rows = ($local ++ $fetched | sort-by at)
    let rows = if $since == null { $rows } else {
        let after = ($since | into datetime)
        $rows | where {|row| ($row.at | into datetime) > $after }
    }
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

def seen-file [cache: string, source: string] { $cache | path join $"($source).seen" }

def last-seen [cache: string, source: string] {
    let file = (seen-file $cache $source)
    if ($file | path exists) { open --raw $file | str trim } else { '1970-01-01T00:00:00+00:00' }
}

# Announce the newest unseen revert from one source. It is marked seen
# first, so a notification that never gets an answer is not repeated.
def announce [cache: string, source: string, rows: list] {
    let seen = (last-seen $cache $source | into datetime)
    let fresh = ($rows | where {|row| ($row.at | into datetime) > $seen } | sort-by at)
    if ($fresh | is-empty) { return }
    let latest = ($fresh | last)
    $latest.at | save --force (seen-file $cache $source)

    let verb = if $latest.activated { "reverted" } else { "rejected" }
    let earlier = (($fresh | length) - 1)
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
# destination. An unreachable canary is skipped until the next run.
def "main notify" [...sources: string] {
    let cache = (cache-dir)
    mkdir $cache
    announce $cache (sys host | get hostname) (entries ((state) | path join reverts.jsonl))
    for source in $sources {
        # Quoted, since the remote login shell parses the command line.
        let since = (last-seen $cache $source)
        let result = (^ssh -o BatchMode=yes -o ConnectTimeout=10 $source deploy-reverts --json --since $"'($since)'" | complete)
        if $result.exit_code != 0 {
            print --stderr $"Could not read ($source)'s reverts: ($result.stderr | str trim)"
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
