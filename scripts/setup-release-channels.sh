#!/usr/bin/env bash
# One-time GitHub setup for the test → beta → main release channels. Run by a repository admin; safe to re-run.
#   - rulesets: main (narrowed from every branch to main only, merge commits allowed, CI required),
#     test (squash/rebase, linear) and beta (merge commits only), all with signed commits and PRs
#   - environments: "beta", and "stable" with you as required reviewer, so stable releases wait for approval
#   - lets GitHub Actions open pull requests (the Promote workflow)
#   - gh-pages branch with an empty appcast, served by GitHub Pages
# Usage: scripts/setup-release-channels.sh [owner/repo]
set -euo pipefail
R="${1:-burinworks/slashlight}"
ME="$(gh api user --jq .id)"
CHECK='{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"do_not_enforce_on_create":true,"required_status_checks":[{"context":"Build & test","integration_id":15368}]}}'
BYPASS='[{"actor_id":null,"actor_type":"OrganizationAdmin","bypass_mode":"always"}]'

ruleset() { # name, JSON body
  local id
  id="$(gh api "repos/$R/rulesets" --jq ".[] | select(.name == \"$1\") | .id")"
  if [[ -n "$id" ]]; then gh api -X PUT "repos/$R/rulesets/$id" --input - --jq '"updated " + .name'
  else gh api "repos/$R/rulesets" --input - --jq '"created " + .name'; fi
}

channel() { # name, branch, linear history (true/false), allowed merge methods (JSON)
  jq -n --arg name "$1" --arg ref "refs/heads/$2" --argjson linear "$3" --argjson methods "$4" \
    --argjson check "$CHECK" --argjson bypass "$BYPASS" '{
      name: $name, target: "branch", enforcement: "active", bypass_actors: $bypass,
      conditions: {ref_name: {include: [$ref], exclude: []}},
      rules: ([{type: "deletion"}, {type: "non_fast_forward"}, {type: "required_signatures"},
               {type: "pull_request", parameters: {required_approving_review_count: 0, dismiss_stale_reviews_on_push: false,
                 require_code_owner_review: false, require_last_push_approval: false,
                 required_review_thread_resolution: false, allowed_merge_methods: $methods}},
               $check] + (if $linear then [{type: "required_linear_history"}] else [] end))
    }' | ruleset "$1"
}

# main keeps its review rules. It loses linear history because promotions arrive as merge commits from beta,
# and it no longer applies to every branch (that blocked bot pushes to gh-pages and Dependabot rebases).
MAIN_ID="$(gh api "repos/$R/rulesets" --jq '.[] | select(.name == "Main Rule") | .id')"
if [[ -n "$MAIN_ID" ]]; then
  gh api "repos/$R/rulesets/$MAIN_ID" | jq --argjson check "$CHECK" '{
      name, target, enforcement, bypass_actors,
      conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
      rules: ([.rules[] | select(.type != "required_linear_history" and .type != "required_status_checks")] + [$check])
    }' | ruleset "Main Rule"
fi
channel "Test channel" test true '["squash", "rebase"]'
channel "Beta channel" beta false '["merge"]'

for B in test beta; do
  gh api "repos/$R/git/ref/heads/$B" >/dev/null 2>&1 ||
    gh api "repos/$R/git/refs" -f "ref=refs/heads/$B" -f "sha=$(gh api "repos/$R/git/ref/heads/main" --jq .object.sha)" --jq '"created " + .ref'
done

gh api -X PUT "repos/$R/environments/beta" --input - --jq '"environment " + .name' <<<'{}'
gh api -X PUT "repos/$R/environments/stable" --input - --jq '"environment " + .name + " (needs your approval)"' \
  <<<"{\"reviewers\":[{\"type\":\"User\",\"id\":$ME}],\"prevent_self_review\":false}"

gh api -X PUT "repos/$R/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true
echo "GitHub Actions may open pull requests"

# gh-pages: an orphan branch holding appcast.xml, updated by the release workflow through the contents API.
if ! gh api "repos/$R/git/ref/heads/gh-pages" >/dev/null 2>&1; then
  INDEX="$(gh api "repos/$R/git/blobs" -f encoding=utf-8 \
    -f content='<meta http-equiv="refresh" content="0; url=https://github.com/burinworks/slashlight">' --jq .sha)"
  NOJEKYLL="$(gh api "repos/$R/git/blobs" -f encoding=utf-8 -f content='' --jq .sha)"
  APPCAST="$(gh api "repos/$R/git/blobs" -f encoding=utf-8 -f content='<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Slashlight</title>
    <link>https://github.com/burinworks/slashlight</link>
    <description>Slashlight updates</description>
    <language>en</language>
  </channel>
</rss>
' --jq .sha)"
  TREE="$(jq -n --arg i "$INDEX" --arg n "$NOJEKYLL" --arg a "$APPCAST" '{tree: [
      {path: "index.html", mode: "100644", type: "blob", sha: $i},
      {path: ".nojekyll", mode: "100644", type: "blob", sha: $n},
      {path: "appcast.xml", mode: "100644", type: "blob", sha: $a}]}' |
    gh api "repos/$R/git/trees" --input - --jq .sha)"
  COMMIT="$(gh api "repos/$R/git/commits" -f message="Appcast home" -f "tree=$TREE" --jq .sha)"
  gh api "repos/$R/git/refs" -f ref=refs/heads/gh-pages -f "sha=$COMMIT" --jq '"created " + .ref'
fi
if ! gh api "repos/$R/pages" >/dev/null 2>&1; then
  gh api "repos/$R/pages" --input - --jq '"Pages: " + .html_url' <<<'{"source":{"branch":"gh-pages","path":"/"}}'
fi
echo "Appcast: https://$(cut -d/ -f1 <<<"$R").github.io/$(cut -d/ -f2 <<<"$R")/appcast.xml"
