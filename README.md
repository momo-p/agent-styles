# style-agents

My global setup for Claude Code: the instructions every session loads, a skill for rewriting prose, and hooks that enforce the rules a script can check.

> [!WARNING]
> This repo is vibe coded. I described what I wanted and Claude wrote almost all of it, including the hooks and this README. I read the result and ran the tests described below on one machine (NixOS, Claude Code 2.1.272, Perl 5.42). That is all the testing it has had. The hooks run on every Bash call and every file edit, and some of them block commands. Read them before you install them, and expect to fix things.

## What's in it

| Path | What it does | Installed as |
|:---|:---|:---|
| `AGENTS.md` | Rules loaded into every session: scope, code style, writing style, commits and PRs | `~/.claude/CLAUDE.md` |
| `settings.json` | Permissions and hook wiring | merged into `~/.claude/settings.json` |
| `hooks/` | Perl scripts that Claude Code runs around tool calls | `~/.claude/hooks` |
| `skills/humanizer/` | A copy of [blader/humanizer](https://github.com/blader/humanizer) at `9862685` | `~/.claude/skills/humanizer` |

A rule in `AGENTS.md` only works if the model follows it. A hook runs outside the model, so the check happens every time, and it costs no tokens unless it fires. When a rule can be checked by a script, it lives in a hook.

## Hooks

At session start, `project-info.pl` prints a few lines of facts read from disk: manifests (nested ones too), the Go version or Rust edition, npm scripts, make and just targets, CI workflows, formatter configs, and instruction files Claude Code doesn't load on its own, such as `AGENTS.md` and `CONTRIBUTING.md`. The agent starts from real names instead of guessing them. Outside a project it prints nothing.

Before each Bash call, `guard-bash.pl` blocks:

- commit messages that aren't a single conventional subject line, or that carry an attribution trailer
- PR titles that aren't conventional, and PR bodies with more than 10 lines or 5 bullets, headings, or code blocks
- AI-writing tells in commit subjects and PR bodies
- any attempt to skip commit signing (`--no-gpg-sign`, `-c commit.gpgsign=false`, editing the signing config)
- commits whose staged files look wrong by name (`.env`, keys, `node_modules/`, build output, databases) or are over 1 MB
- commits whose staged diff contains a secret, scanned with [gitleaks](https://github.com/gitleaks/gitleaks) when installed, falling back to built-in patterns
- commits where the index changed since the agent last ran `git status` or `git diff --cached`, so nothing is committed unseen
- commits signed through 1Password (`op-ssh-sign`) while 1Password is closed
- push, pull, fetch, and clone over SSH while 1Password is closed, when `~/.ssh/config` points `IdentityAgent` at 1Password (HTTPS remotes are left alone)

Staging itself is never checked, so incremental `git add` calls stay silent. The index is checked once, at the commit, and running `git status` or `git diff --cached` marks it as reviewed. That state is a fingerprint of the index in `~/.cache/style-agents/`, one file per repo and session.

After each file edit, `post-edit.pl` formats the file and lints its prose. `gofmt`, `rustfmt`, and `zig fmt` always run. Prettier, ruff, black, alejandra, nixfmt, stylua, clang-format, and treefmt run only when the project has a config for them, so a repo that doesn't use a formatter won't get reformatted.

The prose lint reads `.md`, `.txt`, `.rst` and `.adoc` whole, plus the comments and doc comments of source files in the usual languages. Stock AI words fire on one sighting in the text the edit added. The structural tells (X-not-Y contrasts, one-line closers, three-item lists, em dashes, bold lead-in bullets) are counted over the whole file against a budget per line of prose, and raised only when the edit fed them, so a document can't drift past a budget one small edit at a time. Code blocks, tables, headings and quotes don't count toward anything. Comments get the word, contrast, list and dash budgets but not the closer one, since a one-line comment is a short standalone sentence by design. `AGENTS.md` and its siblings are skipped because they quote the tells they ban, and any other file opts out with a `prose-lint: off` comment.

After a Bash call fails, `op-failure.pl` checks whether it was a git command that hit a signing error, an SSH key error, or a timeout. If so, it tells the agent to stop and ask you to unlock or approve 1Password, instead of retrying or deciding git is broken.

Each hook takes about 20 ms, plus the formatter's own time. Prettier is the slow one at about 100 ms because Node has to start.

## Knowledge cache

`hooks/know.pl` lets the agent keep facts about a project between sessions. Each fact has to cite the files it came from, and the cache stores a hash of each one:

```bash
perl ~/.claude/hooks/know.pl add "make serve runs templ generate before go run ./cmd" Makefile cmd/main.go
perl ~/.claude/hooks/know.pl list
perl ~/.claude/hooks/know.pl rm 3
```

At session start, any fact whose files have changed or disappeared is dropped, and the rest are loaded into context. Edits, branch switches, and pulls remove only the facts that depended on the files they touched. The cache lives in `~/.claude/knowledge/`, one JSON file per project, outside the repo.

A fact can still go stale if it depends on a file it didn't cite. `AGENTS.md` tells the agent to cite every file that proves the fact.

## Install

You need Claude Code 2.1.272 or later (for the `PostToolUseFailure` hook event), Perl 5 with its core modules, and git. Formatters are optional; the hooks skip any that aren't installed. [gitleaks](https://github.com/gitleaks/gitleaks) is optional too, and worth installing: with it, the secret scan on commit knows real tokens from documented examples. Without it, the built-in patterns are cruder.

With home-manager, where `style-agents` is this repo as a flake input or from `fetchFromGitHub`:

```nix
home.file.".claude/CLAUDE.md".source = "${style-agents}/AGENTS.md";
home.file.".claude/hooks".source = "${style-agents}/hooks";
home.file.".claude/skills/humanizer".source = "${style-agents}/skills/humanizer";
# Merge into the settings you already generate:
# lib.recursiveUpdate yourSettings (builtins.fromJSON (builtins.readFile "${style-agents}/settings.json"))
```

`lib.recursiveUpdate` replaces lists instead of joining them, so if your own settings have `permissions` lists, merge those by hand.

Without nix, symlink the same paths and copy the `permissions` and `hooks` blocks from `settings.json` into your own:

```bash
ln -s ~/Codes/style-agents/AGENTS.md ~/.claude/CLAUDE.md
ln -s ~/Codes/style-agents/hooks ~/.claude/hooks
ln -s ~/Codes/style-agents/skills/humanizer ~/.claude/skills/humanizer
```

## Tuning

The hooks will get things wrong, mostly by flagging text that was fine. The places to change:

- word lists and structural budgets for the prose lint: `@HARD`, `@SOFT` and `%BUDGET` in `hooks/lib/Lint.pm`
- 1Password and SSH error messages: `hooks/op-failure.pl`
- which formatter runs for which file type: `formatter()` in `hooks/post-edit.pl`
- permission rules: `settings.json`

To update humanizer, copy `SKILL.md` and `LICENSE` from upstream into `skills/humanizer/` and change the commit hash in the table above.

## License

MIT, see [LICENSE](LICENSE). `skills/humanizer/` is blader's work under its own MIT license, in [skills/humanizer/LICENSE](skills/humanizer/LICENSE).
