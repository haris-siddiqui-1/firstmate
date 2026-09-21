# Live validation: omp ASCII-preset status row (fm/fm-omp-composer-misread-8p)

Target commit `2ce859c` widens `FM_COMPOSER_OMP_STATUS_RE_DEFAULT` in
`bin/fm-composer-lib.sh` so omp's ASCII-preset footer is composer furniture:
`pi` identity cell, `/ | - \` busy spinners (with elapsed + middle dot), and
`%/<n>[KM]` context cell. Before the fix, an idle ASCII omp pane read
`pending`, skipping the steering doorbell (plus exit/relaunch/teardown guards).

All Herdr driving went through `bin/fm-herdr-lab.sh` in lab session
`fm-lab-omp-ascii-15927-12893` (provisioned, used, torn down; tripwire
verified, default session untouched). Each screen was rendered into the live
lab pane `w1:p1` via `pane run` + `sleep 120` (holding the frame with no shell
prompt below it), then classified through the real product path.

## Scenario 1 — idle ASCII footer reads empty (the reported bug)
Pane frame:
```
transcript line

❯
 pi · [xhi] Muse Spark 1.3 Contributor · [wt] …ate · @ fm/rw-pipeline-atlas-1k · ctx: 20.0%/1M [A]
```
`fm_backend_composer_state herdr <lab>:w1:p1` → `empty` (PASS, live).
Pre-fix regex confirmed to MISS this row (`grep -E` old pattern → no match),
reproducing the reported `pending` misread.

## Scenario 2 — busy ASCII spinner row keeps an empty composer
Pane frame: `❯` + ` - 30m · [xhi] Muse Spark 1.3 Contributor · [wt] …ews · @ fm/rw-deploy-pull-remint-6k`
`fm_backend_composer_state herdr` → `empty` (PASS, live).

## Scenario 3 — typed text above the ASCII footer still reads pending
Pane frame: `❯ fix the flaky test` + ASCII footer below.
`fm_backend_composer_state herdr` → `pending` (PASS, live).

## Scenario 4 (adversarial) — lookalike typed rows are never furniture
- `_fm_composer_row_is_omp_status '| 1h of meetings today was rough'` → INPUT (not furniture).
  Full-screen ANSI classify → `unknown` (styled proof of real text, correctly
  not `pending` since a leading `|` is a shell-glyph edge; critically never `empty`).
- `_fm_composer_row_is_omp_status 'fix · tests before pushing'` → INPUT; live
  ANSI pane frame classified `pending` (PASS, live).
- No-regression predicates, all FURNITURE: unicode idle `π … 15.4%/272K`,
  nerd idle `󰵗 … 36.7%/41K`, braille busy `⠧ 11s · …`; all four ASCII busy
  frames (`-`, `|`, `/`, `\`); M-suffix ctx `27.1%/1M`.

## Focused suite
`bash tests/fm-composer-lib.test.sh` → 35 ok, 0 not-ok (includes the updated
`test_matrix_omp_status_row_bounds_bare_composer` with idle/busy ASCII fixtures).
