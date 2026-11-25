# Issue tracker: Orbit

Issues and specs for this repo live as tasks in the **Kubernetes** project (key `K8S`) of Orbit (https://board.lorenzolab.com), managed with the `orbit` MCP tools (`mcp__orbit__*`). If the `orbit` MCP server is unavailable, say so and ask the user to run `/mcp` to reconnect; don't fall back to GitHub.

Tasks are referred to by identifier, e.g. `K8S-12`. Every tool that takes a `task_id` accepts either the identifier or the UUID.

## IDs

- **Project**: `K8S`, id `01a208d1-0cb6-75e2-80e1-7f6b33c41d6f`.
- **Statuses** (`list_task_statuses`): `Backlog`, `Todo`, `In Progress`, `Done`, `Cancelled`, `Duplicate`. New tasks go in `Backlog` unless they're already agent-ready (then `Todo`).
- **Labels**: the five triage labels (see `triage-labels.md`) and `wayfinder:map` / `wayfinder:research` / `wayfinder:prototype` / `wayfinder:grilling` / `wayfinder:task` exist in `K8S`. Look up their IDs with `list_labels`. Labels can't be created through the MCP; if a skill needs a new one, ask the user to create it in the Orbit UI.

## Conventions

- **Create an issue**: `create_task` with `project_id`, `status_id`, `title`, and the body as Markdown in `description`.
- **Read an issue**: `get_task` (identifier or id), plus `list_comments` for the comments.
- **List issues**: `list_tasks` with `project_id` (and `query` to search title/description). It includes completed tasks: filter on `status_id` yourself.
- **Make an issue a sub-issue of a parent**: `create_task` with `parent_task_id`, or `update_task` with `parent_task_id` afterwards. List children with `list_tasks` and `parent_task_id`.
- **Comment on an issue**: `create_comment`.
- **Apply / remove labels**: `update_task` with `label_ids`. It **replaces** the whole set, so read the current `label_ids` with `get_task` first and send the edited list.
- **Close**: `create_comment` with the reason, then `update_task` with `status_id` set to `Done` (or `Cancelled` / `Duplicate`).

`update_task` needs `expected_version`: take `version` from a fresh `get_task` right before writing.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

PRs still live on GitHub (`lorenzorapetti/homelab`); use `gh pr` for them. Reference the Orbit task identifier (e.g. `K8S-12`) in the PR body.

## When a skill says "publish to the issue tracker"

Create an Orbit task in the `K8S` project.

## When a skill says "fetch the relevant ticket"

Read it as in **Read an issue** above.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single task with **child** tasks as tickets.

- **Map**: a single task labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body.
- **Child ticket**: a sub-issue of the map (`parent_task_id` = the map). Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: Orbit has no native dependency links through the MCP, so put a `Blocked by: K8S-<n>, K8S-<n>` line at the top of the child's description. A ticket is unblocked when every blocker is `Done`, `Cancelled` or `Duplicate`.
- **Frontier query**: `list_tasks` with `parent_task_id` = the map; drop children that are completed, have an open task in their `Blocked by` line, or have an assignee; first in map order wins.
- **Claim**: `update_task` with `assignee_ids` = your `get_me` user id, the session's first write.
- **Resolve**: `create_comment` with the answer, then `update_task` to `Done`, then append a context pointer (gist + identifier) to the map's Decisions-so-far.
