---
name: ship:pr-node
description: "Opens a work-graph node's PR in a context of its own, from the run's files. Dispatched by pipeline.sh next; not for direct use."
argument-hint: "Task: <id> | Artifact language: <lang> | Storage mode: <mode> | Scratch dir: <dir>"
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: false
model: "sonnet"
context: fork
background: false
---
@ship-body-of pr
