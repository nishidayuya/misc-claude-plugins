---
name: pr-ci
description: Watch the CI of every commit of one GitHub pull request or GitLab merge request, and get CI to run on the commits that never had any (the non-head commits of a multi-commit push) or whose CI was cancelled, by pushing a temporary branch pr-ci/<number>/<sha> and deleting it once CI has finished. Run it only when the user explicitly invokes /pr-ci:pr-ci or /loop /pr-ci:pr-ci with a URL — never on your own initiative, because it pushes branches.
argument-hint: "<pull request or merge request URL>"
allowed-tools:
  - Bash(${CLAUDE_SKILL_DIR}/scripts/pr-ci.sh *)
---

Watch the CI of every commit of a pull request (GitHub) or merge request
(GitLab), one iteration per invocation. Meant to run under `/loop`:

```
/loop /pr-ci:pr-ci <pull request or merge request URL>
```

The deterministic work — reading the pull request, its commits and their CI,
pushing and deleting temporary branches, and remembering what was pushed — is
done by `${CLAUDE_SKILL_DIR}/scripts/pr-ci.sh`. This skill runs it, reports
what changed, and paces the loop.

## Rules

* **Push and delete branches only through the script.** It pushes nothing but
  `pr-ci/<number>/<sha>` branches pointing at commits of the pull request, and
  deletes nothing else. Never push, delete, re-run or cancel anything by hand.
* **Never edit anything to make CI pass**, and never approve a run that waits for
  approval. A red or blocked commit is reported, not fixed.
* Anything not described here is something to ask about, not to do.

## 1. The URL

`$ARGUMENTS` is the URL of the pull request or merge request. If it is empty,
ask for it — do not guess one from the current branch.

## 2. One iteration

```
${CLAUDE_SKILL_DIR}/scripts/pr-ci.sh step --data-dir ${CLAUDE_PLUGIN_DATA} <URL>
```

It prints JSON:

* `state` — `open`, `merged` or `closed`.
* `commits[]`, oldest first — `short`, `subject`, `head` (true for the head
  commit), `ci` (`none`, `pending`, `success`, `failure`, `cancelled`,
  `action_required`, `manual`, `other`), `runs[]` (the newest run of each
  workflow, with `url`), `needs_rerun` (`no_ci`, `cancelled` or null) and
  `action`:
  * `push` — a temporary branch was pushed for it in this iteration.
  * `branch_waiting`, `branch_running`, `branch_finished`,
    `branch_untriggered` — it already has a temporary branch, which is waiting
    for CI to start, has CI running, or was just deleted. The next iteration
    decides whether to push again.
  * `untriggered` — a pushed branch started no CI within the timeout, so
    pushing a branch does not trigger CI in this repository. On GitHub, the
    workflow's `on: push` does not match `pr-ci/**`; on GitLab, `workflow:rules`
    do not allow a branch pipeline. Say so once, with that explanation; the
    script does not push that commit again.
  * `not_covered_by_push` — CI ran on the branch, but some workflow that was
    cancelled only runs for pull requests, so it stays cancelled.
  * `attempts_exhausted` — pushed three times and still cancelled.
  * `pull_request_not_open` — needs a re-run, but the pull request is closed.
* `branches[]` — the temporary branches seen at the start, with `result`
  (`waiting`, `running`, `finished`, `untriggered`) and `deleted`.
* `pushed[]` — the branches pushed in this iteration.
* `settled` — nothing is running, no temporary branch is left, nothing was
  pushed.

A script error (exit status not 0) is reported with its message. A network or
API error is transient: report it and carry on with the loop. An error that
will not go away by itself — the URL is wrong, `gh` or `glab` is not logged in,
the push is rejected — is reported, and the loop is stopped (step 4).

## 3. Report

The first iteration reports every commit: short SHA, subject, CI state, and the
action taken. After that, report only what changed since the previous
iteration — a branch pushed or deleted, a commit whose CI finished (with its
result and the run URL when it failed), anything that needs a person — in a
line or two. An iteration where nothing changed gets one short line.

When a commit is `failure`, `action_required` or `manual`, say so plainly with
the run URL. Do not investigate or fix it unless the user asks.

## 4. Pacing and stopping the loop

When running under `/loop` without an interval, schedule the next iteration
with `ScheduleWakeup`, passing the same `/pr-ci:pr-ci <URL>` prompt:

* about 270 seconds while anything is pending, a branch is alive, or something
  was just pushed (`settled` is false);
* about 1200 seconds when `settled` is true — new commits may still be pushed.

Stop the loop (`ScheduleWakeup` with `stop: true`, or `CronDelete` for a loop
started with an interval) when:

* `state` is `merged` or `closed` — first run
  `${CLAUDE_SKILL_DIR}/scripts/pr-ci.sh cleanup --data-dir ${CLAUDE_PLUGIN_DATA} --delete <URL>`
  and report which branches it deleted;
* an error that will not go away by itself happened (step 2).

When invoked without `/loop`, run one iteration, report, and mention that
`/loop /pr-ci:pr-ci <URL>` keeps watching.

## 5. 「中断」

When the user says 「中断」 (or otherwise asks to stop watching) while this loop is
running:

1. Stop the loop first, as in step 4, so that no iteration runs while cleaning
   up.
2. List the temporary branches that are left:

   ```
   ${CLAUDE_SKILL_DIR}/scripts/pr-ci.sh cleanup --data-dir ${CLAUDE_PLUGIN_DATA} <URL>
   ```

3. None left — say the watch has stopped and nothing is left behind.
4. Some left — name them, say whether CI is still running on them (from the last
   iteration's report), and ask whether to delete them now. Deleting a branch
   whose CI is still running may leave that commit without a result. On yes,
   run the same command with `--delete` and report what it deleted. On no, say
   that running `/pr-ci:pr-ci <URL>` once later deletes the ones that have
   finished.
