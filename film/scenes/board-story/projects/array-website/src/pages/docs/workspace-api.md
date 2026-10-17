# The workspace API

Agents can open files, arrange tiles and reveal their work on the canvas
through `array.workspace.v1`. Every operation is scoped to the agent's own
project and asks before it reaches outside it.

## Operations

| Operation | What it does |
|---|---|
| `artifact.open` | Opens a file or URL as a tile beside the agent |
| `canvas.query` | Lists the zones and tiles the agent may see |
| `canvas.apply` | Moves or resizes the agent's own tiles |
| `agent.reveal` | Brings an agent's tile into view |

## Grants

An agent starts with its own checkout. Anything wider is a prompt the
person answers once, in Array, never in the agent's transcript.
