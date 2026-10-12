# OpenDot runtime assessment for Catpaw-m

Checked: 2026-10-12. Scope: read-only review of current public upstream sources, not an execution/security audit. Branch links can change; pin a commit before implementation.

## Identity is not confirmed

The name is ambiguous. No prior repository URL was recoverable in the available conversation search. The main assessment below is **tentatively about [composio-community/open-dot](https://github.com/composio-community/open-dot)**, the Mac/Electron personal-agent application supporting OpenRouter. Do not silently equate it with the user's earlier OpenDot research.

Other distinct candidates:
- [thinkwee/OpenDot](https://github.com/thinkwee/OpenDot): self-hosted Python/FastAPI agent team, MIT shown by upstream. Its design describes durable jobs/effects and is potentially more relevant to durable execution.
- [defog-ai/opendot](https://github.com/defog-ai/opendot): Python host orchestrating coding CLIs in containers; Apache-2.0 according to upstream. Its current README says actions execute without approval, despite a conflicting older repository description.
- [diggerhq/opendots](https://github.com/diggerhq/opendots): OpenComputer Serverless Agents application, a different runtime and hosting dependency.

## Tentative candidate: composio-community/open-dot

### Runtime and framework

This is an application with a hand-written TypeScript agent loop, not a drop-in durable-agent framework. `runtime.ts` directly drives the OpenAI Responses API, streams output, executes tools sequentially, and stops after 60 steps. It supports OpenRouter's stateless path with locally retained history. The dependency manifest includes OpenAI SDK, MCP SDK, Composio, E2B, Croner, Playwright, Next.js and Electron; it does not list LangGraph, Temporal, or OpenAI Agents SDK. [Runtime](https://github.com/composio-community/open-dot/blob/main/src/server/agent/runtime.ts), [manifest](https://github.com/composio-community/open-dot/blob/main/package.json)

Dot-to-dot consultation is particularly limited: the implementation makes a separate model request with web search, rather than launching another full tool-capable durable worker. [Consultation implementation](https://github.com/composio-community/open-dot/blob/main/src/server/agent/runtime.ts#L500-L523)

### Persistence is not general durable execution

Approval continuation state is serialized: response ID, tool calls, outputs, next-call index, card and trigger. Approving a card can continue that sequence. However, live inboxes, callbacks and running flags live in a `globalThis` map, not a durable queue. This distinction matters for crashes and process termination. [Runtime](https://github.com/composio-community/open-dot/blob/main/src/server/agent/runtime.ts)

SQLite stores conversations, pending continuations, messages, memories, skills, rules and routines; OpenRouter history is stored per conversation. WAL mode helps database durability, but is not a workflow-recovery protocol. The inspected schema has no jobs/effects ledger. [Database schema](https://github.com/composio-community/open-dot/blob/main/src/server/db.ts), [repository layer](https://github.com/composio-community/open-dot/blob/main/src/server/repo.ts)

Croner jobs are in-process, reconstructed from saved routines at scheduler start. The README explicitly states routines/triggers require the app to be running and missed occurrences are skipped. Do not infer full agent continuity from the fact an E2B computer remains available. [Scheduler](https://github.com/composio-community/open-dot/blob/main/src/server/scheduler.ts), [operational limits](https://github.com/composio-community/open-dot#good-to-know)

### Memory

Memory is simple, explicit CRUD: per-dot short text records, plus named skills with descriptions and bodies. Every turn rebuilds a prompt containing all stored memories and skill descriptions; a tool loads a skill's body. This is understandable and useful as a starting pattern, but the reviewed paths are not semantic retrieval, provenance tracking, automatic reconciliation, or a scalable memory service. [Persistence](https://github.com/composio-community/open-dot/blob/main/src/server/repo.ts), [prompt assembly](https://github.com/composio-community/open-dot/blob/main/src/server/agent/prompt.ts), [memory/skill tools](https://github.com/composio-community/open-dot/blob/main/src/server/agent/tools.ts)

### Tools, approvals and security

Tool definitions combine schema, execution function, action description, optional precheck, default decision, and pause behavior. The same conceptual interface could fit Catpaw-m well. Local host commands ask by default; isolated cloud/Docker commands default to allow. Browser clicks use a text-based risk heuristic; typing defaults to allow. These are prototype policies, not sufficient evidence of comprehensive protection. [Tool definitions](https://github.com/composio-community/open-dot/blob/main/src/server/agent/tools.ts)

A separate model matches actions to rules. Code resolves matched rules in the order never, ask, allow. Reviewer failures preserve allow defaults, while other defaults become ask, so it is not globally fail-closed. [Reviewer](https://github.com/composio-community/open-dot/blob/main/src/server/agent/review.ts)

Composio is accessed through its hosted MCP service, with saved OAuth state. Read/write classification uses verbs in tool slugs. Its call wrapper reconnects and retries after most exceptions. For consequential writes, that retry pattern needs explicit idempotency or uncertain-outcome handling before reuse: a timeout does not prove that the first write failed. [Connector and retry code](https://github.com/composio-community/open-dot/blob/main/src/server/composio.ts)

### Hosting and licensing

The application runs a local Next.js server inside Electron, with SQLite/files on the user's Mac. README says it has no login screen and should not be exposed publicly as-is. E2B, Docker, and local-folder computer adapters provide execution environments; they do not move the orchestrator into a managed durable backend. [README](https://github.com/composio-community/open-dot), [computer interface](https://github.com/composio-community/open-dot/blob/main/src/server/computer/index.ts)

**Reuse license is unverified.** The observed root listing contains no LICENSE file; `package.json` is private and has no license field. The README calling it open source is not enough to select a license. Confirm upstream licensing before copying or distributing its code. [Root listing](https://github.com/composio-community/open-dot), [package metadata](https://github.com/composio-community/open-dot/blob/main/package.json)

## What Catpaw-m should take from this

Recommendation (architecture inference): keep SwiftUI, Supabase Auth/Postgres and the existing bounded OpenRouter loop. Study these application patterns rather than replacing the stack wholesale:

1. A provider-neutral tool contract with explicit policy and execution metadata.
2. Persisted approval requests tied to exact tool arguments and continuation state.
3. Separate conversation history, curated user facts, and reusable skills.
4. Browser/computer adapters isolated from orchestration.
5. Explicit pause, cancel, timeout, and budget states visible to the client.

For genuinely durable work, implement or adopt a separate execution layer: transactionally enqueue jobs with the initiating message; claim work with leases; checkpoint steps; persist wait conditions and approval decisions; maintain an effects ledger with idempotency keys; recover expired leases; reconcile uncertain external writes instead of replaying blindly. Do not keep a single Edge Function request alive as the durability mechanism. These are proposed requirements for Catpaw-m, not features verified in this OpenDot implementation.

## Alternate candidate worth checking: thinkwee/OpenDot

Upstream describes FastAPI + SQLite + LiteLLM, a custom per-agent loop, helper delegation, readable file-based memory and a Gatekeeper. Its design specifically describes atomic message/job insertion, recovery of interrupted jobs younger than six hours, stored approvals and an effects ledger to avoid blind repeated outward actions. It also explicitly warns that a local command guard is a safety net rather than strong isolation; Docker/bubblewrap are preferred. [Official design](https://github.com/thinkwee/OpenDot/blob/master/docs/DESIGN.md)

Those durability patterns align more closely with Catpaw-m's missing layer. However, in this pass direct fetches of `durable.py` failed, so these are **documented upstream claims, not source-code-verified guarantees**. The repository identity and actual implementation must be confirmed before recommending adoption. [Repository and MIT indication](https://github.com/thinkwee/OpenDot)
