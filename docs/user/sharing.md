---
title: "Share work with a teammate"
description: "Share an agent, a tile, or part of your canvas."
section: "Workspace"
order: 12
---

Share an agent or part of your canvas with a link. The work keeps running on the owner's Mac. Each person keeps their own project and checkout.

## Get started

Use Share on a tile or an agent's sidebar row. The first time you share, Array asks for the name your teammates will see and creates a collaboration account. Opening a link can also create an account this way. This account is separate from your Claude Code, Codex, or Pi login.

Array uses its collaboration relay to connect people and shared content. The production app uses `relay.arrayapp.dev`. You can also open **File → Collaboration…** to choose an account or connect with an enrollment code.

## Share one agent

Choose **Share** on the agent's tile or sidebar row, then **Copy link**. Send the link to your teammate. They get a live agent tile and can send prompts; the agent still runs on your Mac. Prompts show who sent them. Anyone who opens the link can prompt and move the shared agent, so send it only to people you trust.

Choose **Works once** for a link spent when one person opens it, or **Until revoked** for a link that stays usable until you revoke it. The share panel shows people with access. You can remove a person, revoke a link, or revoke everyone's access there.

## Share part of your canvas

Use the **S** share tool and drag around the area you want to share. Review the listed tiles and copy the link. Your tiles stay where they are. Your teammate sees the shared region as one portal tile, with the arrangement following yours.

A tile dragged into that region is not automatically published. Choose **Add to share** on the tile to include it. Unsupported tiles are listed in the share panel with a reason. A portal needs at least one shareable tile besides a private terminal.

Inside the portal, scroll to pan, pinch or Command-scroll to zoom, and double-click to fit. An agent in the portal can be opened beside it for a conversation.

## What teammates can see and do

| Tile | Shared on its own | In a portal |
| --- | --- | --- |
| Agent | See and prompt the live agent | See the agent; open it beside the portal to prompt |
| Note | Edit together live | Read the host's updates |
| File | Read saved text and updates | Read updates |
| Diff | Read the current changes | Read updates and choose Approve or Request changes |
| Browser | Follow a public page; private pages can be shown as pictures with clicks and scrolling sent to the host | A public page loads on the guest's Mac; a private page appears as a still |
| Terminal | Watch live output, read-only, after the owner's confirmation | Private by default; the owner can opt it in after a warning |

Terminal output can contain passwords, tokens, keys, or environment values. Array warns before sharing it live. The owner can use **Stop sharing** on its Live badge. Guests cannot type in the shared terminal.

File trees, boards, iOS previews, inspectors, queues, run artifacts, and someone else's shared tiles cannot be shared from your Mac. The share panel explains exclusions. Older versions may need an update to open newer shared tile kinds.

## Presence and following

In a portal, you can see teammates' cursors over shared content. Cursor outlines and name backgrounds help them stand out against the canvas. Follow a teammate's view to move your camera with theirs. Pan, scroll, or zoom to stop following. Each person's view remains their own.

## Access, offline work, and privacy

If the owner's Mac goes offline, the shared view shows its offline state and the last content it received. The agent runs on the owner's Mac, so it needs that Mac to work. The owner can remove a person or revoke access from the share panel. Close a shared tile to remove it from your canvas. Closing it does not revoke your access; ask the owner to remove you if you want access ended. Content already shown stays visible until the tile is closed.

Sharing sends selected content, tile positions, prompts and presence through the relay to people with access. Shared files, notes, diffs, browser pictures and terminal output can contain private information. Review the selection before copying a link. A portal's terminal stays private unless you explicitly share it. Shared browsers do not send the host’s cookies. Pages with sensitive URL parameters are shown as a still; those addresses omit the query and fragment. Your project and checkout stay on your Mac; sharing is not a copy of the entire project. Provider sign-in stays with the CLI. See [local storage](/docs/storage/) and [privacy](/privacy) for the other data paths.
