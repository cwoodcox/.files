## Choose sub-agent models for cost

Sub-agents default to a cheaper model than the orchestrator. The expensive model's job is to plan and specify the work well enough that a cheaper one can carry it out; if a task needs Opus to *execute*, that usually means the spec is still vague.

Pass `model` explicitly on every `Agent` call instead of letting the sub-agent inherit:

- **`haiku`** — mechanical and fully bounded: file sweeps, grep-and-collate, mass renames, formatting, reading a known file to answer one question, running a command and reporting output.
- **`sonnet`** — the default for real work: implementing a specified change, writing tests, focused exploration, following a plan across a few files.
- **`opus`** — reserve for tasks where reasoning quality *is* the deliverable: ambiguous design decisions, cross-cutting refactors, subtle debugging, adversarial review, or planning that another agent will execute.

An agent may elect its own model tier — or higher — when the task's complexity genuinely justifies the cost. That's a judgment call the spawning agent owns; make it deliberately and say why in one clause, don't default to it.

Two things make the downgrade work, so do both:

- Write the prompt so a cheaper model can't go wrong — name the exact files, the acceptance criteria, and what's out of scope.
- Prefer several cheap parallel sub-agents over one expensive serial one when the work is separable.

This applies recursively: a sub-agent spawning its own sub-agents follows the same rule. Note that a model set in an agent definition's frontmatter wins unless overridden by `model` on the call, and `subagent_type: "fork"` always inherits the parent's model.
