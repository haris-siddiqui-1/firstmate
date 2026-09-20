# Live validation transcript: fm-fleet-sync non-default-branch fix

Branch: fm/fm-fleet-sync-nondefault-branch-5k (target 96fe11b vs base a09090d).
Method: drove the real `bin/fm-fleet-sync.sh` against isolated `file://`
origin+clone fixtures shaped like the RouteWork projects (origin default `main`,
clone checked out on `develop` with its own upstream `origin/develop`).

## Bug reproduction (old script from base commit vs new script, same fixture)

Fixture: bare origin with HEAD -> main; clone on `develop` tracking
`origin/develop`, 1 commit behind it; `main` advanced elsewhere.

OLD script (base a09090d):

    n: STUCK: on branch develop, 0 commits behind origin/main - needs attention

  -> Exactly the reported RouteWork symptom: measured against origin/main
     (count 0), never refreshed.

NEW script (worktree 96fe11b), same fixture:

    n: synced 3ec73a2..de5a6a1

  -> Fast-forwards the checked-out branch to its own upstream.

## Live scenarios against the new script (full transcript)

    --- clone state before: 0ffa95b branch=develop
    --- remote develop: daba139 remote main: 0c000f1
    === SCENARIO 1: clean dev branch behind own upstream ===
    news: synced 0ffa95b..daba139
    --- after: daba139 origin/develop=daba139
    SCENARIO1: FAST-FORWARDED to own upstream
    === SCENARIO 2 (adversarial): dirty dev branch must stay STUCK ===
    news: STUCK: on branch develop with uncommitted changes, 1 commits behind origin/develop - needs attention
    SCENARIO2: UNTOUCHED (correct)
    === SCENARIO 3 (adversarial): diverged dev branch must stay STUCK ===
    news: STUCK: on branch develop diverged from origin/develop, 2 commits behind origin/develop - needs attention
    SCENARIO3: UNTOUCHED (correct)

## Targeted suite

`bash tests/fm-fleet-sync.test.sh`: all 28 checks pass (`grep -c ^ok` = 28),
including the four new non-default-branch tests:
clean-behind-upstream fast-forwards; dirty / diverged / no-upstream stay STUCK
and untouched. No Herdr surface exists for this change, so no Herdr lab session
was used; all fixtures were throwaway directories under /tmp, since removed.
Worktree left clean.
