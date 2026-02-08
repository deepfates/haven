# 🏡 haven

Haven is a mobile-first web client and local bridge for ACP agents. The theory is that you give a whole computer to your agents, whether as a VM or container or whatever, and the computer file system and the software within it becomes their sort of house or shared space. A haven. And you can interact with them from wherever through the mobile web client, spin up and talk to different agents. Like Codex and Claude Code and all the other ones supported by agent client protocol. 

This repo includes:
- A bridge server that speaks ACP to an agent over stdio and exposes a WebSocket JSON-RPC API to the browser.
- A web UI with an inbox of sessions, streaming updates, and approval prompts.

## What works today

- Create multiple sessions, each backed by its own agent process.
- Stream agent messages and tool-call updates in a chat-style feed.
- Handle ACP permission requests with approval cards.
- Persist sessions, updates, and pending approvals in SQLite for reloads.

## Protocol boundaries

- Browser <-> bridge: JSON-RPC 2.0 over WebSocket on `/ws` (custom methods).
- Bridge <-> agent: ACP over stdio.

## Quickstart

See `docs/quickstart.md`.

## Configuration (bridge)

Environment variables:

- `PORT` (default `8080`)
- `HOST` (default `0.0.0.0`)
- `AGENT_COMMAND` (default `npx @zed-industries/claude-code-acp`)
- `DEFAULT_CWD` (default `/home/sprite`)
- `STATIC_DIR` (default `client/dist`)

## Data & security

- Sessions and updates are stored in `~/.acp-client/sessions.db`.
- There is no built-in auth. Run on a trusted network or put a gateway in front.

## Current limitations

- No session resume if an agent process exits.
- Only text prompt content is rendered in the UI.
- `agentType` is recorded but does not select a different command.
- Operations for Sprites are manual and intentionally light.

## Reference

- Bridge + ACP notes: `ACP-PROTOCOL.md`
