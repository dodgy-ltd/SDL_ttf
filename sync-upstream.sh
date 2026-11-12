#!/bin/sh
# Copyright 2026 Dodgy Ltd.
# sync-upstream.sh
#
# Syncs every local branch from the original SDL repository (pushing the
# result to the fork on origin as a fast-forward), then rebases the local
# fixes on DODGY_BRANCH onto the updated BASE_BRANCH, leaving the result
# staged (NOT committed) for review.
#
# End state: DODGY_BRANCH points at upstream/BASE_BRANCH with the
# local fixes sitting in the index. Review with `git diff --cached`, then
# commit when happy.
#
# Notes:
#  - Local branches are only ever fast-forwarded; a branch that has diverged
#    (local commits not upstream) is skipped with a warning, never clobbered.
#  - Synced branches are pushed to origin, fast-forward only; a branch the
#    fork has moved on (on origin) is never pushed, only warned about.
#  - release-3.4.x-dodgy is never touched by the branch-sync step.
#  - Upstream branches that have no local counterpart are listed, with the
#    command to create a matching local branch; none are created for you.
#  - Nothing is committed; if the rebase hits a conflict the script stops
#    and tells you what to run next.

set -eu

UPSTREAM_REMOTE="upstream"
UPSTREAM_URL="https://github.com/libsdl-org/SDL_ttf.git"
BASE_BRANCH="release-3.2.x"
DODGY_BRANCH="release-3.2.x-dodgy"

die() {
    echo "error: $*" >&2
    exit 1
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not inside a git work tree"

git_dir=$(git rev-parse --git-dir)
if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
    die "a rebase is already in progress; finish or abort it first (git rebase --abort)"
fi

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    die "work tree has uncommitted changes; commit or stash them first"
fi

git show-ref --verify --quiet "refs/heads/$DODGY_BRANCH" \
    || die "local branch '$DODGY_BRANCH' not found"

# Make sure 'upstream' points at the original SDL repository.
if git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    url=$(git remote get-url "$UPSTREAM_REMOTE")
    case "$url" in
        *libsdl-org/SDL*) ;;
        *) die "$UPSTREAM_REMOTE points at '$url', expected the original SDL repository" ;;
    esac
else
    git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
    echo "added remote '$UPSTREAM_REMOTE' -> $UPSTREAM_URL"
fi

echo "fetching $UPSTREAM_REMOTE ..."
git fetch --prune --tags "$UPSTREAM_REMOTE"

git show-ref --verify --quiet "refs/remotes/$UPSTREAM_REMOTE/$BASE_BRANCH" \
    || die "no '$BASE_BRANCH' branch found on $UPSTREAM_REMOTE"

# Step 1: fast-forward every local branch (except the dodgy one) to its
# upstream counterpart.
current_branch=$(git branch --show-current)

git for-each-ref --format='%(refname:short)' refs/heads/ |
while read -r branch; do
    if [ "$branch" = "$DODGY_BRANCH" ]; then
        continue
    fi
    if ! git show-ref --verify --quiet "refs/remotes/$UPSTREAM_REMOTE/$branch"; then
        continue
    fi
    if git merge-base --is-ancestor "refs/heads/$branch" "refs/remotes/$UPSTREAM_REMOTE/$branch"; then
        if [ "$branch" = "$current_branch" ]; then
            git merge --ff-only "refs/remotes/$UPSTREAM_REMOTE/$branch"
        else
            git update-ref "refs/heads/$branch" "refs/remotes/$UPSTREAM_REMOTE/$branch"
        fi
        echo "synced '$branch'"
        if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
            if [ "$(git rev-parse "refs/remotes/origin/$branch")" = \
                 "$(git rev-parse "refs/remotes/$UPSTREAM_REMOTE/$branch")" ]; then
                echo "origin '$branch' already up to date"
            elif git merge-base --is-ancestor "refs/remotes/origin/$branch" \
                    "refs/remotes/$UPSTREAM_REMOTE/$branch"; then
                if git push origin "$branch"; then
                    echo "pushed '$branch' to origin"
                else
                    echo "warning: push of '$branch' to origin failed; try manually" >&2
                fi
            else
                echo "warning: origin '$branch' has commits not in $UPSTREAM_REMOTE/$branch; not pushed" >&2
            fi
        else
            echo "note: origin has no '$branch'; create it with: git push -u origin $branch"
        fi
    else
        echo "warning: '$branch' has commits not in $UPSTREAM_REMOTE/$branch; skipped" >&2
    fi
done

# Step 2: report upstream branches that have no local counterpart, with
# the command to create one.
new_branches=$(
    git for-each-ref --format='%(refname:short)' "refs/remotes/$UPSTREAM_REMOTE/" |
    while read -r ref; do
        name=${ref#"$UPSTREAM_REMOTE/"}
        # The <remote>/HEAD symref shortens to just <remote>; skip it.
        if [ "$name" = "HEAD" ] || [ "$name" = "$UPSTREAM_REMOTE" ]; then
            continue
        fi
        if ! git show-ref --verify --quiet "refs/heads/$name"; then
            printf '  %s\n    git checkout -b %s %s/%s\n' "$name" "$name" "$UPSTREAM_REMOTE" "$name"
        fi
    done
)
if [ -n "$new_branches" ]; then
    echo "upstream branches with no local counterpart:"
    printf '%s\n' "$new_branches"
fi

# Step 3: rebase the local fixes onto the updated release branch, then
# un-commit the result so it is left staged for review.
echo "rebasing '$DODGY_BRANCH' onto $UPSTREAM_REMOTE/$BASE_BRANCH ..."
git checkout "$DODGY_BRANCH"

if ! git rebase "refs/remotes/$UPSTREAM_REMOTE/$BASE_BRANCH"; then
    echo >&2
    echo "rebase stopped (conflict?). Resolve it, then run:" >&2
    echo "  git rebase --continue" >&2
    echo "  git reset --soft refs/remotes/$UPSTREAM_REMOTE/$BASE_BRANCH" >&2
    echo "(or bail out with: git rebase --abort)" >&2
    exit 1
fi

# Move the branch back to the new base, keeping the rebased changes staged
# in the index (working tree untouched).
git reset --soft "refs/remotes/$UPSTREAM_REMOTE/$BASE_BRANCH"

echo
echo "done: '$DODGY_BRANCH' is now on $UPSTREAM_REMOTE/$BASE_BRANCH with the local fixes staged"
echo "review: git diff --cached"
echo "commit: git commit -m '<message>'"
