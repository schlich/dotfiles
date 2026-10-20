# Deliver luvus's integration branch to main: push it to GitHub, wait for
# nix-ci's `nix flake checks` on that exact commit, then move main to it.
# The main-checks ruleset admits only a commit with that check passed, and
# GitHub refuses a push that is not a fast-forward, so this never rewrites
# main. It waits for CI, so agents run it as a `job-log` job.
def main [
  --repo: path = "."                     # Any checkout of the repository
  --branch: string = "luvus/integration" # The branch luvus merges finished tasks into
  --check: string = "nix flake checks"   # The required check run on GitHub
  --timeout: duration = 2hr
  --poll: duration = 30sec
] {
  let root = (^git -C $repo rev-parse --show-toplevel | str trim)
  let sha = (^git -C $root rev-parse --verify $"($branch)^{commit}" | str trim)
  let short = ($sha | str substring 0..11)
  ^git -C $root fetch --quiet origin main
  let main = (^git -C $root rev-parse origin/main | str trim)
  if $main == $sha {
    print $"main is already at ($short)."
    return
  }
  if (^git -C $root merge-base --is-ancestor $main $sha | complete).exit_code != 0 {
    error make { msg: $"($branch) does not contain origin/main; merge main into it before delivering." }
  }
  print $"Pushing ($branch) at ($short)."
  ^git -C $root push --quiet origin $"($sha):refs/heads/($branch)"
  let slug = (do { cd $root; ^gh repo view --json nameWithOwner --jq .nameWithOwner } | str trim)
  let deadline = ((date now) + $timeout)
  loop {
    let runs = (^gh api --method GET $"repos/($slug)/commits/($sha)/check-runs" -f $"check_name=($check)" | from json | get check_runs)
    let latest = ($runs | where status == completed | sort-by completed_at | last)
    if $latest != null {
      if $latest.conclusion != "success" {
        error make { msg: $"`($check)` concluded ($latest.conclusion) on ($short): ($latest.html_url)" }
      }
      break
    }
    if (date now) > $deadline {
      error make { msg: $"Timed out after ($timeout) waiting for `($check)` on ($short)." }
    }
    print $"Waiting for `($check)` on ($short)."
    sleep $poll
  }
  ^git -C $root push --quiet origin $"($sha):refs/heads/main"
  print $"Delivered: main is now ($short)."
}
