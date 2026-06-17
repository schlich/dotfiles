Project-Scale TDD Agent Workflow
Use pydantic-ai-harness for composable capabilities and execution controls, and pydantic-deepagents for project-scale orchestration: planning, subagents, shared tasks, memory, context compression, checkpoints, sandboxing, and live run forking.
User goal
  ↓
Coordinator Agent
  ↓
Planning + Task Graph
  ↓
Feature slices
  ↓
RED agents write failing tests
  ↓
GREEN agents implement minimum code
  ↓
REFACTOR agents improve design
  ↓
Verifier runs full quality gates
  ↓
Reviewer/Judge accepts, rejects, or forks alternatives
Core Design
Use one always-on coordinator and specialized on-demand capabilities.
from pydantic_ai import Agent
from pydantic_ai.capabilities import Capability, Thinking, ToolSearch
from pydantic_ai_harness import CodeMode
from pydantic_deep import create_deep_agent, LiveForkCapability, default_security_hook

agent = create_deep_agent(
    model="anthropic:claude-sonnet-4-6",
    include_plan=True,
    include_todo=True,
    include_subagents=True,
    include_teams=True,
    include_memory=True,
    include_skills=True,
    include_checkpoints=True,
    context_manager=True,
    cost_tracking=True,
    thinking="high",
    forking=LiveForkCapability(
        test_command="pytest -q",
        test_timeout_s=180,
    ),
    hooks=[
        *default_security_hook(),
    ],
)
Add pydantic-ai-harness capabilities around that agent:
capabilities = [
    CodeMode(),          # batch tool calls in sandboxed Python
    ToolSearch(),        # avoid exposing every tool at once
    Thinking("high"),    # deeper reasoning for planning/refactor
]
Agents
Coordinator Agent:
Owns the project goal, task graph, TDD discipline, and merge decisions.
Responsibilities:
- Load repo context: AGENTS.md, existing architecture, test conventions, CI commands.
- Split work into vertical slices small enough for TDD.
- Enforce phase gates: no implementation before a failing test.
- Assign work to subagents.
- Keep project state in shared TODOs and persistent memory.
- Decide when to fork alternatives.
Planner Agent:
Produces a typed implementation plan.
Output shape:
class TDDPlan(BaseModel):
    objective: str
    affected_areas: list[str]
    test_command: str
    quality_commands: list[str]
    slices: list["FeatureSlice"]

class FeatureSlice(BaseModel):
    id: str
    behavior: str
    files_likely_touched: list[str]
    red_acceptance: str
    green_acceptance: str
    refactor_constraints: list[str]
RED Agent:
Writes one or more failing tests.
Rules:
- May read production code.
- May edit only tests, fixtures, snapshots, or contract files.
- Must run targeted tests.
- Must prove failure is meaningful, not syntax/import noise.
- Produces a RedReport.
class RedReport(BaseModel):
    slice_id: str
    tests_added: list[str]
    command: str
    failed: bool
    failure_summary: str
    expected_failure_reason: str
GREEN Agent:
Implements the smallest production change.
Rules:
- May edit production files.
- Must not weaken or delete RED tests.
- Optimizes for minimal correctness, not elegance.
- Runs targeted tests until green.
- Produces a GreenReport.
Refactor Agent:
Improves internal structure without changing behavior.
Rules:
- No new behavior.
- No test weakening.
- Must keep targeted and impacted tests green.
- Prefer small local simplification over broad rewrites.
- Produces a RefactorReport.
Verifier Agent:
Runs project-level checks.
Typical commands:
pytest -q
ruff check .
ruff format --check .
pyright
mypy .
Reviewer/Judge Agent:
Reviews diffs and structured reports.
Accepts only if:
- The RED failure was observed before implementation.
- GREEN fixed the intended behavior.
- Refactor preserved behavior.
- Full verification passes or failures are classified as unrelated.
- The diff is smaller than competing alternatives unless quality clearly justifies size.
TDD State Machine
Each slice moves through explicit states.
planned
  ↓
red_in_progress
  ↓
red_failed_expected
  ↓
green_in_progress
  ↓
green_passed
  ↓
refactor_in_progress
  ↓
refactor_passed
  ↓
verified
  ↓
merged
Invalid transitions:
planned → green_in_progress
red_in_progress → refactor_in_progress
green_passed → merged without verifier
Use lifecycle hooks from Pydantic AI capabilities to enforce this.
Examples:
- before_tool_execute: block production file writes during RED.
- after_tool_execute: record test command outputs.
- before_model_request: inject current slice state and TDD rules.
- after_run: require structured report output.
- output guardrail: reject a GREEN report if no prior RedReport.failed == True.
Use On-Demand Capabilities
The Pydantic AI capabilities docs emphasize that capabilities bundle tools, instructions, model settings, and hooks. For project-scale TDD, use deferred capabilities so the coordinator does not carry every workflow all the time.
red_capability = Capability(
    id="tdd-red",
    description="Use to write failing tests before implementation.",
    instructions="""
    You are the RED phase agent.
    Write tests only.
    Do not edit production code.
    Run targeted tests and prove the failure is expected.
    """,
    defer_loading=True,
)

green_capability = Capability(
    id="tdd-green",
    description="Use to implement the minimum code to pass failing tests.",
    instructions="""
    You are the GREEN phase agent.
    Implement the smallest production change.
    Do not weaken tests.
    Run targeted tests until passing.
    """,
    defer_loading=True,
)

refactor_capability = Capability(
    id="tdd-refactor",
    description="Use after green tests to improve design safely.",
    instructions="""
    You are the REFACTOR phase agent.
    Preserve behavior.
    Keep tests green.
    Prefer minimal local cleanup.
    """,
    defer_loading=True,
)
This matches the Pydantic capability model:
- RED loads test-writing instructions, test-only hooks, and test tools.
- GREEN loads implementation instructions and production write permissions.
- REFACTOR loads design-quality instructions and stricter verification hooks.
Use DeepAgents Forking
Use pydantic-deepagents live run forking when implementation or refactor choices are uncertain.
Good fork points:
- Multiple plausible implementation strategies.
- Risky refactors.
- Performance-sensitive code.
- Public API design.
- Migration or compatibility decisions.
Example:
GREEN fork:
  branch A: smallest direct implementation
  branch B: extract reusable helper
  branch C: adapt existing abstraction

Each branch:
  runs targeted tests
  reports diff size
  reports complexity impact

Judge selects:
  passing tests first
  smallest diff second
  maintainability third
For refactoring:
REFACTOR fork:
  branch A: no refactor
  branch B: local cleanup
  branch C: broader abstraction

Accept broader abstraction only if:
  all tests pass
  duplicated logic clearly reduced
  public behavior unchanged
  diff remains reviewable
Shared Project Memory
Use memory for stable project facts, not transient task chatter.
Store:
Test command: pytest -q
Typecheck command: pyright
Style command: ruff check .
Architecture notes
Known flaky tests
Module ownership
TDD conventions
Previously rejected approaches
Do not store:
Temporary failure logs
Unreviewed assumptions
Secrets
Large tool outputs
Verification Gates
At slice level:
RED gate:
  test exists
  test fails
  failure matches intended behavior

GREEN gate:
  RED test passes
  no test weakening
  minimal production diff

REFACTOR gate:
  tests still pass
  behavior unchanged
  complexity not increased

PROJECT gate:
  full test suite
  lint
  typecheck
  review
At project scale, add periodic integration gates:
After every 3-5 slices:
  run impacted test suite
  run static checks
  checkpoint state

Before final:
  run full CI equivalent
  summarize behavioral changes
  produce reviewable diff
Recommended Agent Team
coordinator
  Owns workflow and final decisions.

planner
  Converts goal into TDD slices.

test-writer
  RED phase only.

implementer
  GREEN phase only.

refactorer
  REFACTOR phase only.

verifier
  Runs commands and classifies failures.

reviewer
  Reviews final diff and TDD evidence.

judge
  Selects winning fork when alternatives exist.
Important Guardrails
Use hooks/tool guards to enforce:
RED cannot edit production files.
GREEN cannot delete or weaken RED tests.
REFACTOR cannot add new behavior.
No phase can skip required test commands.
Destructive shell commands require approval.
Secrets are redacted from tool output.
Budget limits stop runaway loops.
Stuck-loop detection terminates repeated failed attempts.
Workflow Summary
1. Coordinator loads repo context.
2. Planner creates typed TDD slices.
3. For each slice:
   1. RED agent writes failing test.
   2. Verifier confirms expected failure.
   3. GREEN agent implements minimum fix.
   4. Verifier confirms targeted pass.
   5. REFACTOR agent cleans design.
   6. Verifier confirms behavior preserved.
4. Coordinator checkpoints after each slice.
5. DeepAgents forks risky choices and judge selects winners.
6. Final verifier runs full project checks.
7. Reviewer validates diff, tests, and TDD evidence.
The key design choice is to treat TDD phases as capability-gated workflows, not just prompt instructions. pydantic-ai-harness gives the composable capability, hook, tool, and sandbox model. pydantic-deepagents gives the project-scale execution model: subagents, teams, shared tasks, memory, checkpoints, and fork/judge selection.
