use std/assert

def --wrapped run-sync [script: path, ...args: string] {
  let res = (nu --no-config-file $script ...$args | complete)
  if $res.exit_code != 0 {
    error make { msg: $"kb-sync failed \(exit ($res.exit_code)): ($res.stderr)" }
  }
  $res
}

def main [script: path] {
  let tmp = (mktemp -d)
  try {
    let bare = ($tmp | path join "kb.git")
    let asus = ($tmp | path join "asus")
    let homelab = ($tmp | path join "homelab")

    git init --bare --initial-branch=main $bare | ignore

    # Seed asus as a local colocated JJ repo and push initial commit.
    mkdir $asus
    jj --no-pager git init --colocate $asus | ignore
    jj --no-pager -R $asus config set --repo user.name "Test User" | ignore
    jj --no-pager -R $asus config set --repo user.email "test@example.com" | ignore
    jj --no-pager -R $asus git remote add origin $bare | ignore

    "# Index\n" | save ($asus | path join "index.md")
    run-sync $script --root $asus --manual --host asus

    # Verify bare repo received main.
    let refs = (git --git-dir $bare show-ref --heads)
    assert ($refs | str contains "refs/heads/main") $"expected refs/heads/main in bare repo, got: ($refs)"

    # Clone to homelab.
    jj --no-pager git clone --colocate $bare $homelab | ignore
    jj --no-pager -R $homelab config set --repo user.name "Test User" | ignore
    jj --no-pager -R $homelab config set --repo user.email "test@example.com" | ignore
    assert equal (open --raw ($homelab | path join "index.md")) "# Index\n"

    # 1. Asus writes a note -> auto-commit/push (--manual) -> homelab fetch-only sees it.
    "# Asus Note\nfrom asus\n" | save ($asus | path join "asus-note.md")
    run-sync $script --root $asus --manual --host asus
    run-sync $script --root $homelab --fetch-only --host homelab
    assert equal (open --raw ($homelab | path join "asus-note.md")) "# Asus Note\nfrom asus\n"

    # 2. Homelab writes a note -> syncs back -> asus sees it.
    "# Homelab Note\nfrom homelab\n" | save ($homelab | path join "homelab-note.md")
    run-sync $script --root $homelab --manual --host homelab
    run-sync $script --root $asus --manual --host asus
    assert equal (open --raw ($asus | path join "homelab-note.md")) "# Homelab Note\nfrom homelab\n"

    # 3. Concurrent non-conflicting edits on both hosts merge cleanly onto main.
    "# Topic A\n" | save ($asus | path join "topic-a.md")
    "# Topic B\n" | save ($homelab | path join "topic-b.md")
    run-sync $script --root $asus --manual --host asus
    run-sync $script --root $homelab --manual --host homelab
    run-sync $script --root $asus --fetch-only --host asus
    assert equal (open --raw ($asus | path join "topic-b.md")) "# Topic B\n"
    assert equal (open --raw ($homelab | path join "topic-a.md")) "# Topic A\n"

    # 4. Debounce skips a freshly modified file on automated runs.
    "# Fresh Draft\n" | save ($asus | path join "draft.md")
    run-sync $script --root $asus --debounce 60sec --host asus
    run-sync $script --root $homelab --fetch-only --host homelab
    assert (not (($homelab | path join "draft.md") | path exists)) "debounced draft should not be pushed yet"
    # Manual run bypasses debounce and pushes it.
    run-sync $script --root $asus --manual --host asus
    run-sync $script --root $homelab --fetch-only --host homelab
    assert equal (open --raw ($homelab | path join "draft.md")) "# Fresh Draft\n"

    # 5. Concurrent conflicting edits keep main clean and push conflict to sync/<host>.
    "# Index\nversion asus\n" | save -f ($asus | path join "index.md")
    "# Index\nversion homelab\n" | save -f ($homelab | path join "index.md")
    run-sync $script --root $asus --manual --host asus
    run-sync $script --root $homelab --manual --host homelab

    # Bare repo main must remain asus's clean commit without conflict markers.
    let main_content = (git --git-dir $bare show main:index.md | str trim)
    assert equal $main_content "# Index\nversion asus"
    let all_refs = (git --git-dir $bare show-ref --heads)
    let side_ref = ($all_refs | lines | where {|l| $l | str contains "refs/heads/sync/homelab/" } | first | split row " " | last)
    assert equal (git --git-dir $bare show $"($side_ref):index.md" | str trim) "# Index\nversion homelab"
    # homelab working tree stays clean (no conflict markers that would break IWE).
    assert equal (open --raw ($homelab | path join "index.md")) "# Index\nversion asus\n"

    # Subsequent automated run on conflicted homelab stays idempotent and keeps main clean.
    run-sync $script --root $homelab --debounce 0sec --host homelab
    assert equal (git --git-dir $bare show main:index.md | str trim) "# Index\nversion asus"

    print "kb-sync-test: all cases passed"
  } catch {|err|
    rm -rf $tmp
    error make $err
  }
  rm -rf $tmp
}
