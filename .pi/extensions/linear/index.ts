import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { execFileSync } from "node:child_process";

const LINEAR_GRAPHQL_URL = "https://api.linear.app/graphql";
const KEYCHAIN_SERVICE = "pi-linear-api-key";

type Json = Record<string, unknown>;

function getApiKey(): string | undefined {
  if (process.env.LINEAR_API_KEY) return process.env.LINEAR_API_KEY;

  // macOS Keychain fallback. Keeps tokens out of project files and shell profiles.
  try {
    const out = execFileSync(
      "security",
      ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    ).trim();
    if (out) return out;
  } catch {
    // Not macOS, not configured, or keychain locked.
  }

  return undefined;
}

async function linearGraphql<T = unknown>(query: string, variables?: Json): Promise<T> {
  const apiKey = getApiKey();
  if (!apiKey) {
    throw new Error(
      `Linear API key not configured. Set LINEAR_API_KEY or add a macOS Keychain item named ${KEYCHAIN_SERVICE}.`,
    );
  }

  const res = await fetch(LINEAR_GRAPHQL_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      // Linear's GraphQL API expects API keys as the raw Authorization value.
      // OAuth/MCP bearer tokens may include the Bearer prefix already.
      Authorization: apiKey,
    },
    body: JSON.stringify({ query, variables: variables ?? {} }),
  });

  const text = await res.text();
  let payload: any;
  try {
    payload = JSON.parse(text);
  } catch {
    throw new Error(`Linear returned non-JSON response (${res.status}): ${text.slice(0, 400)}`);
  }

  if (!res.ok || payload.errors?.length) {
    const err = payload.errors?.map((e: any) => e.message).join("; ") || text;
    throw new Error(`Linear GraphQL error (${res.status}): ${err}`);
  }

  return payload.data as T;
}

function text(data: unknown) {
  return JSON.stringify(data, null, 2);
}

export default function linearExtension(pi: ExtensionAPI) {
  pi.registerTool({
    name: "linear_graphql",
    label: "Linear GraphQL",
    description: "Run a raw Linear GraphQL query or mutation. Use for Linear operations not covered by convenience tools.",
    parameters: Type.Object({
      query: Type.String({ description: "GraphQL query or mutation." }),
      variables: Type.Optional(Type.Record(Type.String(), Type.Any(), { description: "GraphQL variables." })),
    }),
    async execute(_toolCallId, params) {
      const data = await linearGraphql(params.query, params.variables as Json | undefined);
      return { content: [{ type: "text", text: text(data) }], details: data as Json };
    },
  });

  pi.registerTool({
    name: "linear_viewer",
    label: "Linear Viewer",
    description: "Show the authenticated Linear user and workspace.",
    parameters: Type.Object({}),
    async execute() {
      const data = await linearGraphql(`
        query Viewer {
          viewer {
            id
            name
            email
            organization { id name urlKey }
          }
        }
      `);
      return { content: [{ type: "text", text: text(data) }], details: data as Json };
    },
  });

  pi.registerTool({
    name: "linear_teams",
    label: "Linear Teams",
    description: "List Linear teams available to the authenticated user.",
    parameters: Type.Object({}),
    async execute() {
      const data = await linearGraphql(`
        query Teams {
          teams(first: 100) {
            nodes { id key name description }
          }
        }
      `);
      return { content: [{ type: "text", text: text(data) }], details: data as Json };
    },
  });

  pi.registerTool({
    name: "linear_projects",
    label: "Linear Projects",
    description: "List Linear projects.",
    parameters: Type.Object({
      limit: Type.Optional(Type.Number({ description: "Max projects to return.", default: 50 })),
      query: Type.Optional(Type.String({ description: "Optional search string." })),
    }),
    async execute(_toolCallId, params) {
      const data = await linearGraphql(`
        query Projects($first: Int, $filter: ProjectFilter) {
          projects(first: $first, filter: $filter) {
            nodes {
              id
              name
              description
              url
              state
              createdAt
              updatedAt
              teams { nodes { id key name } }
            }
          }
        }
      `, {
        first: Math.min(params.limit ?? 50, 100),
        filter: params.query ? { name: { containsIgnoreCase: params.query } } : undefined,
      });
      return { content: [{ type: "text", text: text(data) }], details: data as Json };
    },
  });

  pi.registerTool({
    name: "linear_create_project",
    label: "Linear Create Project",
    description: "Create a Linear project tied to one or more team IDs.",
    parameters: Type.Object({
      name: Type.String(),
      teamIds: Type.Array(Type.String(), { description: "Linear team IDs to attach the project to." }),
      description: Type.Optional(Type.String()),
      icon: Type.Optional(Type.String()),
      color: Type.Optional(Type.String()),
    }),
    async execute(_toolCallId, params) {
      const data = await linearGraphql(`
        mutation ProjectCreate($input: ProjectCreateInput!) {
          projectCreate(input: $input) {
            success
            project { id name url description state teams { nodes { id key name } } }
          }
        }
      `, {
        input: {
          name: params.name,
          teamIds: params.teamIds,
          description: params.description,
          icon: params.icon,
          color: params.color,
        },
      });
      return { content: [{ type: "text", text: text(data) }], details: data as Json };
    },
  });

  pi.registerTool({
    name: "linear_issues",
    label: "Linear Issues",
    description: "List Linear issues, optionally filtered by team, project, state, assignee, or search query.",
    parameters: Type.Object({
      limit: Type.Optional(Type.Number({ default: 50 })),
      teamId: Type.Optional(Type.String()),
      projectId: Type.Optional(Type.String()),
      query: Type.Optional(Type.String({ description: "Search in title/description." })),
    }),
    async execute(_toolCallId, params) {
      const and: unknown[] = [];
      if (params.teamId) and.push({ team: { id: { eq: params.teamId } } });
      if (params.projectId) and.push({ project: { id: { eq: params.projectId } } });
      if (params.query) {
        and.push({
          or: [
            { title: { containsIgnoreCase: params.query } },
            { description: { containsIgnoreCase: params.query } },
          ],
        });
      }

      const data = await linearGraphql(`
        query Issues($first: Int, $filter: IssueFilter) {
          issues(first: $first, filter: $filter, orderBy: updatedAt) {
            nodes {
              id
              identifier
              title
              description
              priority
              url
              createdAt
              updatedAt
              team { id key name }
              project { id name }
              state { id name type }
              assignee { id name email }
            }
          }
        }
      `, {
        first: Math.min(params.limit ?? 50, 100),
        filter: and.length ? { and } : undefined,
      });
      return { content: [{ type: "text", text: text(data) }], details: data as Json };
    },
  });

  pi.registerTool({
    name: "linear_create_issue",
    label: "Linear Create Issue",
    description: "Create a Linear issue.",
    parameters: Type.Object({
      teamId: Type.String(),
      title: Type.String(),
      description: Type.Optional(Type.String()),
      projectId: Type.Optional(Type.String()),
      priority: Type.Optional(Type.Number({ description: "0=None, 1=Urgent, 2=High, 3=Medium, 4=Low." })),
      assigneeId: Type.Optional(Type.String()),
      labelIds: Type.Optional(Type.Array(Type.String())),
    }),
    async execute(_toolCallId, params) {
      const data = await linearGraphql(`
        mutation IssueCreate($input: IssueCreateInput!) {
          issueCreate(input: $input) {
            success
            issue { id identifier title url team { key name } project { id name } state { name type } }
          }
        }
      `, {
        input: {
          teamId: params.teamId,
          title: params.title,
          description: params.description,
          projectId: params.projectId,
          priority: params.priority,
          assigneeId: params.assigneeId,
          labelIds: params.labelIds,
        },
      });
      return { content: [{ type: "text", text: text(data) }], details: data as Json };
    },
  });

  pi.registerTool({
    name: "linear_update_issue",
    label: "Linear Update Issue",
    description: "Update a Linear issue by issue ID or identifier.",
    parameters: Type.Object({
      id: Type.String({ description: "Issue UUID or identifier, e.g. SAV-123." }),
      title: Type.Optional(Type.String()),
      description: Type.Optional(Type.String()),
      projectId: Type.Optional(Type.String()),
      stateId: Type.Optional(Type.String()),
      assigneeId: Type.Optional(Type.String()),
      priority: Type.Optional(Type.Number()),
    }),
    async execute(_toolCallId, params) {
      const { id, ...input } = params;
      const data = await linearGraphql(`
        mutation IssueUpdate($id: String!, $input: IssueUpdateInput!) {
          issueUpdate(id: $id, input: $input) {
            success
            issue { id identifier title url state { name type } assignee { name email } project { id name } }
          }
        }
      `, { id, input });
      return { content: [{ type: "text", text: text(data) }], details: data as Json };
    },
  });

  pi.registerTool({
    name: "linear_create_comment",
    label: "Linear Create Comment",
    description: "Add a comment to a Linear issue.",
    parameters: Type.Object({
      issueId: Type.String({ description: "Linear issue UUID." }),
      body: Type.String(),
    }),
    async execute(_toolCallId, params) {
      const data = await linearGraphql(`
        mutation CommentCreate($input: CommentCreateInput!) {
          commentCreate(input: $input) {
            success
            comment { id body url createdAt issue { identifier title } }
          }
        }
      `, { input: { issueId: params.issueId, body: params.body } });
      return { content: [{ type: "text", text: text(data) }], details: data as Json };
    },
  });

  pi.registerCommand("linear-status", {
    description: "Check Linear API connectivity for the current Pi session.",
    handler: async (_args, ctx) => {
      try {
        const data: any = await linearGraphql(`query { viewer { name organization { name } } }`);
        ctx.ui.notify(`Linear connected: ${data.viewer.name} · ${data.viewer.organization?.name ?? "workspace"}`, "success");
      } catch (err) {
        ctx.ui.notify(`Linear not connected: ${err instanceof Error ? err.message : String(err)}`, "error");
      }
    },
  });

  pi.on("session_start", async (_event, ctx) => {
    ctx.ui.setStatus("linear", getApiKey() ? "Linear ready" : "Linear key missing");
  });
}
