---
title: "Where everything is saved"
description: "A map of project documents, workspace state, and provider sessions."
section: "Reference"
order: 30
---

Array has project state, app state, and provider state. Preserving one does not automatically preserve the others.

## Project files and tile contents

Project-scoped state lives under `<project>/.array/`.

| Path | Contents |
| --- | --- |
| `project.json` | Project metadata |
| `canvas.json` | Project tile layout and metadata, including board references |
| `boards/index.json` | Board index |
| `boards/<id>.json` | Board columns, tasks, bodies, links, assignment, and ordering |
| `boards/assets/` | Board image assets |
| `notes/index.json` | Note index |
| `notes/<id>.md` | Markdown note body |
| `browser/tiles.json` | Browser tile records |
| `file-tree/index.json` | File-tree records |
| `reviews/<id>.json` | Review records |
| `sessions/<id>.json` | Session records |
| `managed-sessions/<tile-id>.json` | Managed-session records keyed by tile |
| `backups/` | Retained local state backups |
| `lock` | Exclusive project lock |

An Editor tile points at the actual source document. Its contents remain at that document’s path rather than being copied into `canvas.json`. Moving a tile changes layout, not the file’s location.

## App and workspace state

The production app uses `~/Library/Application Support/Array` and the `dev.arrayapp.macos` preferences domain. The registry records projects, workspaces, and last-active pointers. Workspace documents live under `workspaces/<workspace-id>/canvas.json` in app support.

Development builds use a separate **Array Dev** app store and preferences domain. That separation does not extend to a project’s `.array` folder: two installations pointed at the same folder share project state. Use separate project roots for separate installs.

## Provider state

The selected CLI owns its login and native session files. Array’s agent records and session references connect the UI to that provider state. A saved tile does not contain a portable copy of every provider credential, process, or transcript.

Do not copy authentication files into a project or commit them to share a workspace. Sign in through the CLI on the other machine.

## Back up and recover

Preserve the project files and `.array` directory for project-local content. Preserve Array’s app-support state for the workspace registry and app-level records. Provider session recovery also depends on the CLI’s own data and compatibility.

Git only backs up files you track; a `.gitignore` rule may exclude `.array`. Decide explicitly whether project-local state should be versioned or handled by another backup system. Board bodies and notes can contain private information.

Treat retained local backups as recovery aids, not a replacement for an independent backup. Close the project before restoring state files so a running instance cannot overwrite the restoration.

## Local does not mean offline

The workspace host and files are local. The selected CLI still sends model requests to its provider, and browser tiles contact the sites you open. See [Privacy](/privacy) and the selected provider’s own policy for those data paths.
