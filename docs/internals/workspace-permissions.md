# Workspace permission scopes

Agent permissions in Settings apply to workspace tools. Free approves actions
inside the agent's owning project. Legacy records without a project tag resolve
through their registered Home repository; they never inherit the active project.
An unknown or foreign Home still requires the normal approval.

Ask first offers Allow Once, Allow for This Agent Session, Allow for This
Project Session, and Deny. Agent Session covers the requesting agent until its
Workspace Tools are disabled or Array quits. Project Session covers the same
caller project, target project or checkout, and action scope for agents in that
caller project until Array quits. Opening files does not grant transcript
inspection. Simulator control and Build & Run form one action scope.
Session approvals are held in memory. They do not change Settings or persist
across a relaunch. Each agent must still have Workspace Tools enabled, and
in-flight operations still check cancellation and revocation.

Allow Once retains its operation meaning for workspace actions. A browser site
approval lasts for that browser visit and ends on a committed departure,
user reclaim or runtime replacement; a simulator Open approval lasts for the
opened simulator session. A directly approved asynchronous build can finish
after its initial receipt is returned, subject to revocation and ownership checks.

An agent-owned browser using the Agents profile skips remote site prompts under
Free. Access to a person's browser profile requires one takeover approval covering
reading, interaction and JavaScript, shared across browser tiles in the project for the app session.
Reading an approval does not consume the browser action timeout. Site grants
share the registrable domain according to the bundled Mozilla Public Suffix List,
including private suffixes; unrelated public-suffix tenants keep separate grants.
Localhost, loopback, 0.0.0.0 and private LAN addresses count as local targets.

A person reclaims simulator control through a click or key input. Hovering or
scrolling over a preview does not interrupt an agent.

Behavioral verification runs with `scripts/run-matrix.sh --permission-ux`.
The full matrix also registers these permission legs. Production approval alerts
can be captured in both appearances by setting
`CONTINUUM_PERMISSION_UI_CAPTURE_DIR` when running
`--workspace-api-session-permissions-check` with isolated app support.
