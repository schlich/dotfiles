# Bidirectional, conflict-safe JJ sync for the personal knowledge base.
#
# Fetches from the private Git remote over Tailscale HTTPS, auto-bootstraps
# remotes/clones when `--remote-url` is provided, fast-forwards an empty
# working copy, and snapshots/rebases/pushes settled local edits onto the
# shared branch. If a rebase hits a conflict, the shared branch stays clean
# and the pre-rebase commit is pushed to `sync/<host>/<timestamp>`.

def --wrapped run-jj [root: path, ...args: string] {
  jj --no-pager -R $root ...$args | complete
}

def --wrapped jj-must [root: path, ...args: string]: nothing -> string {
  let res = (run-jj $root ...$args)
  if $res.exit_code != 0 {
    error make { msg: $"jj ($args | str join ' ') failed: ($res.stderr | str trim)" }
  }
  $res.stdout | str trim
}

def has-remote [root: path, remote: string]: nothing -> bool {
  let res = (run-jj $root git remote list)
  if $res.exit_code != 0 {
    return false
  }
  $res.stdout
  | lines
  | each {|line| $line | split row --regex '\s+' | first }
  | any {|name| $name == $remote }
}

def remote-ref-exists [root: path, branch: string, remote: string]: nothing -> bool {
  let res = (run-jj $root log -r $"($branch)@($remote)" --no-graph -T "commit_id")
  $res.exit_code == 0 and ($res.stdout | str trim | is-not-empty)
}

def newest-mtime [root: path]: nothing -> any {
  let jj_dir = ($root | path join ".jj")
  let git_dir = ($root | path join ".git")
  let pattern = ($root | path join "**" "*")
  let files = (
    glob $pattern --no-dir --exclude [
      ($jj_dir | path join "**")
      ($git_dir | path join "**")
      $jj_dir
      $git_dir
    ]
  )
  if ($files | is-empty) {
    return null
  }
  $files
  | each {|f| try { ls -D $f | first | get modified } catch { null } }
  | compact
  | math max
}

def describe-from-diff [root: path, host: string]: nothing -> string {
  cd $root
  let summary = (jj-must $root diff -r "@" --summary)
  let paths = (
    $summary
    | lines
    | where {|l| ($l | str trim | is-not-empty) }
    | each {|l| $l | str replace --regex '^[A-Z?]\s+' '' }
  )
  if ($paths | is-empty) {
    $"kb\(($host)): sync"
  } else if ($paths | length) <= 3 {
    $"kb\(($host)): ($paths | str join ', ')"
  } else {
    let head = ($paths | first 3 | str join ", ")
    let rest = (($paths | length) - 3)
    $"kb\(($host)): ($head) +($rest) more"
  }
}

def push-rev-once [
  root: path
  rev: string
  remote: string
  branch: string
  host: string
]: nothing -> record<ok: bool, conflict: bool, stderr: string> {
  let has_remote_branch = (remote-ref-exists $root $branch $remote)
  let remote_ref = $"($branch)@($remote)"
  let pre_rebase_op = (jj-must $root op log -n 1 --no-graph -T "id")

  if $has_remote_branch {
    let already_based = (jj-must $root log -r $"($remote_ref) & ::\(($rev))" --no-graph -T "commit_id")
    if ($already_based | is-empty) {
      let unpushed_roots = (jj-must $root log -r $"roots\(\(($remote_ref)..\(($rev))) & mutable\())" --no-graph -T 'change_id ++ "\n"')
      if ($unpushed_roots | is-not-empty) {
        for r in ($unpushed_roots | lines | where {|x| ($x | str trim | is-not-empty) }) {
          let rb = (run-jj $root rebase -s $r -d $remote_ref)
          if $rb.exit_code != 0 {
            error make { msg: $"jj rebase failed: ($rb.stderr | str trim)" }
          }
        }
      }
    }
  }

  let check_revset = if $has_remote_branch {
    $"($remote_ref)..\(($rev))"
  } else {
    $"::\(($rev)) & mutable\()"
  }
  let conflicts = (jj-must $root log -r $check_revset --no-graph -T 'if(conflict, "CONFLICT\n", "")')
  if ($conflicts | is-not-empty) {
    # Restore the clean pre-rebase commit so Git accepts the push and IWE never
    # sees conflict markers in the working tree; publish it on sync/<host>/<ts>.
    jj-must $root op restore $pre_rebase_op
    let side = $"sync/($host)/(date now | format date '%Y%m%d-%H%M%S')"
    jj-must $root bookmark set $side -r $rev
    let pushed = (
      with-env { KB_SYNC_INTERNAL: "1" } {
        run-jj $root git push --remote $remote --bookmark $side
      }
    )
    if $pushed.exit_code != 0 {
      print --stderr $"kb-sync: conflict detected and side-branch push failed: ($pushed.stderr | str trim)"
    } else {
      if $has_remote_branch {
        jj-must $root new $remote_ref
      }
      print --stderr $"kb-sync: conflict on ($branch); saved diverged change to ($side) and kept ($branch) clean."
    }
    return { ok: false, conflict: true, stderr: "conflict" }
  }

  jj-must $root bookmark set $branch -r $rev
  let pushed = (
    with-env { KB_SYNC_INTERNAL: "1" } {
      run-jj $root git push --remote $remote --bookmark $branch
    }
  )
  if $pushed.exit_code == 0 {
    let wc_is_empty = ((jj-must $root log -r "@" --no-graph -T "empty") == "true")
    let parent_id = (jj-must $root log -r "@-" --no-graph -T "commit_id")
    let branch_id = (jj-must $root log -r $branch --no-graph -T "commit_id")
    if (not $wc_is_empty) or ($parent_id != $branch_id) {
      jj-must $root new $branch
    }
    { ok: true, conflict: false, stderr: "" }
  } else {
    { ok: false, conflict: false, stderr: ($pushed.stderr | str trim) }
  }
}

def push-with-retry [
  root: path
  rev: string
  remote: string
  branch: string
  host: string
  manual: bool
] {
  let first = (push-rev-once $root $rev $remote $branch $host)
  if $first.ok or $first.conflict {
    return
  }

  # Push race: another host pushed between our fetch and push. Fetch and retry once.
  let refetch = (run-jj $root git fetch --remote $remote)
  if $refetch.exit_code != 0 {
    let msg = $"kb-sync: retry fetch failed: ($refetch.stderr | str trim)"
    if $manual {
      error make { msg: $msg }
    }
    print --stderr $msg
    return
  }

  let second = (push-rev-once $root $rev $remote $branch $host)
  if (not $second.ok) and (not $second.conflict) {
    let msg = $"kb-sync: push failed after retry: ($second.stderr)"
    if $manual {
      error make { msg: $msg }
    }
    print --stderr $msg
  }
}

def maybe-bootstrap-clone [
  root: path
  remote_url: string
  branch: string
  manual: bool
]: nothing -> bool {
  if ($root | path exists) {
    let entries = (ls -a $root)
    if ($entries | is-not-empty) {
      return false
    }
  }
  let probe = (git ls-remote --heads $remote_url $branch | complete)
  if $probe.exit_code != 0 {
    let msg = $"kb-sync: remote check ($remote_url) failed: ($probe.stderr | str trim)"
    if $manual {
      error make { msg: $msg }
    }
    print --stderr $msg
    return false
  }
  if ($probe.stdout | str trim | is-empty) {
    # Remote exists but has no commits on $branch yet.
    return false
  }
  mkdir ($root | path dirname)
  let cloned = (jj --no-pager git clone --colocate $remote_url $root | complete)
  if $cloned.exit_code != 0 {
    let msg = $"kb-sync: clone from ($remote_url) failed: ($cloned.stderr | str trim)"
    if $manual {
      error make { msg: $msg }
    }
    print --stderr $msg
    return false
  }
  true
}

def do-sync [
  root: path
  remote: string
  branch: string
  debounce: duration
  manual: bool
  fetch_only: bool
  host: string
] {
  let fetch = (run-jj $root git fetch --remote $remote)
  if $fetch.exit_code != 0 {
    let msg = $"kb-sync: fetch from ($remote) failed: ($fetch.stderr | str trim)"
    if $manual {
      error make { msg: $msg }
    }
    print --stderr $msg
    return
  }

  let has_remote_branch = (remote-ref-exists $root $branch $remote)
  let remote_ref = $"($branch)@($remote)"

  # Ensure the local branch tracks the remote branch when it exists.
  if $has_remote_branch {
    let _ = (run-jj $root bookmark track $branch --remote $remote)
  }

  # Never touch an already-conflicted working copy; let the user resolve it.
  if ((jj-must $root log -r "@" --no-graph -T "conflict") == "true") {
    if $manual {
      print --stderr $"kb-sync: working copy in ($root) has unresolved conflicts; skipping push."
    }
    return
  }

  let wc_empty = ((jj-must $root log -r "@" --no-graph -T "empty") == "true")
  let wc_desc = (jj-must $root log -r "@" --no-graph -T "description")

  if $wc_empty {
    # Push any unpushed local commits on $branch (or @- when seeding an empty remote).
    if (not $fetch_only) {
      let local_branch = (run-jj $root log -r $branch --no-graph -T "commit_id")
      if $local_branch.exit_code == 0 and ($local_branch.stdout | str trim | is-not-empty) {
        let unpushed = if $has_remote_branch {
          jj-must $root log -r $"($remote_ref)..($branch)" --no-graph -T "commit_id"
        } else {
          $local_branch.stdout | str trim
        }
        if ($unpushed | is-not-empty) {
          push-with-retry $root $branch $remote $branch $host $manual
          return
        }
      } else if (not $has_remote_branch) {
        let parent_non_root = (jj-must $root log -r '@- & ~root()' --no-graph -T "commit_id")
        if ($parent_non_root | is-not-empty) {
          push-with-retry $root "@-" $remote $branch $host $manual
          return
        }
      }
    }

    # Fast-forward an unnamed, empty working copy to the latest remote branch.
    if $has_remote_branch and ($wc_desc | is-empty) {
      let parent_id = (jj-must $root log -r "@-" --no-graph -T "commit_id")
      let remote_id = (jj-must $root log -r $remote_ref --no-graph -T "commit_id")
      if $parent_id != $remote_id {
        jj-must $root new $remote_ref
      }
    }
    return
  }

  if $fetch_only {
    return
  }

  # Debounce automated commits so we never snapshot while the user or an agent
  # is actively writing files.
  if (not $manual) and ($debounce > 0sec) {
    let latest = (newest-mtime $root)
    if $latest != null and ((date now) - $latest) < $debounce {
      return
    }
  }

  if ($wc_desc | is-empty) {
    let msg = (describe-from-diff $root $host)
    jj-must $root describe -m $msg
  }

  push-with-retry $root "@" $remote $branch $host $manual
}

def main [
  --root: path
  --remote: string = "origin"
  --remote-url: string
  --branch: string = "main"
  --debounce: duration = 60sec
  --manual
  --fetch-only
  --host: string
] {
  let kb_root = ($root | default ($env.KB_ROOT? | default ($env.HOME | path join Research kb)))
  let host_name = ($host | default (sys host | get hostname))
  let resolved_url = ($remote_url | default ($env.KB_REMOTE_URL? | default ""))

  # Git hooks export GIT_DIR, which confuses JJ in another working copy.
  hide-env --ignore-errors GIT_DIR
  hide-env --ignore-errors GIT_WORK_TREE
  hide-env --ignore-errors GIT_INDEX_FILE

  # Serialize concurrent sync triggers with flock when not already locked.
  # Keep the lock beside the repo so system services (with PrivateTmp) and
  # user timers share one lock file.
  if ($env.KB_SYNC_LOCKED? | default "") != "1" and (which flock | is-not-empty) {
    let expanded_root = ($kb_root | path expand)
    let lock_dir = ($expanded_root | path dirname)
    if not ($lock_dir | path exists) {
      if ($resolved_url | is-empty) {
        if $manual {
          error make { msg: $"kb-sync: no JJ repository at ($kb_root)" }
        }
        return
      }
      mkdir $lock_dir
    }
    let lock_file = ($lock_dir | path join $".($expanded_root | path basename).sync.lock")
    let flock_args = if ($manual or $fetch_only) {
      ["-w" "30" $lock_file]
    } else {
      ["-n" $lock_file]
    }
    let self_args = (
      [
        "--root" ($kb_root | into string)
        "--remote" $remote
        "--branch" $branch
        "--debounce" ($debounce | into string)
        "--host" $host_name
      ]
      | append (if ($resolved_url | is-not-empty) { ["--remote-url" $resolved_url] } else { [] })
      | append (if $manual { ["--manual"] } else { [] })
      | append (if $fetch_only { ["--fetch-only"] } else { [] })
    )
    let res = (
      with-env { KB_SYNC_LOCKED: "1" } {
        flock ...$flock_args nu --no-config-file $env.CURRENT_FILE ...$self_args | complete
      }
    )
    if ($res.stdout | is-not-empty) { print -n $res.stdout }
    if ($res.stderr | is-not-empty) { print --stderr -n $res.stderr }
    # For non-blocking timer runs, exit 1 from flock simply means another sync holds the lock.
    if $res.exit_code != 0 and ($manual or $fetch_only) {
      exit $res.exit_code
    }
    return
  }

  let ssh_cmd = ($env.GIT_SSH_COMMAND? | default "ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2")
  with-env {
    GIT_SSH_COMMAND: $ssh_cmd
    GIT_TERMINAL_PROMPT: "0"
    GIT_HTTP_LOW_SPEED_LIMIT: "1000"
    GIT_HTTP_LOW_SPEED_TIME: "10"
  } {
    if not (($kb_root | path join ".jj") | path exists) {
      if ($resolved_url | is-not-empty) {
        let _ = (maybe-bootstrap-clone $kb_root $resolved_url $branch $manual)
        return
      }
      if $manual {
        error make { msg: $"kb-sync: no JJ repository at ($kb_root)" }
      }
      return
    }

    if not (has-remote $kb_root $remote) {
      if ($resolved_url | is-not-empty) {
        jj-must $kb_root git remote add $remote $resolved_url
      } else {
        if $manual {
          error make { msg: $"kb-sync: remote '($remote)' is not configured in ($kb_root)" }
        }
        return
      }
    }

    do-sync $kb_root $remote $branch $debounce $manual $fetch_only $host_name
  }
}
