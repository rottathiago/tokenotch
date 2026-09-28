# AI-assisted insights for Tokenotch

Prepared: 2026-09-22.
Status: exploratory proposal for later reevaluation, not an approved implementation plan.

This is a historical snapshot, not current setup or support documentation.
Collection has since evolved, including separate VS Code usage telemetry; use
[current features](../features.md) and [privacy](../tokenotch-privacy.md) for today's
behavior. No cloud-inference proposal here expands the released product's consent.

This note captures the discussion about whether Tokenotch collects enough data for
useful AI insights and whether those insights could use the user's GitHub
Copilot account. No AI generation, additional collection, or cloud submission
was implemented as part of this exploration.

## Summary

Tokenotch already has enough metadata to explain changes in observed Copilot usage
and behavior. It does not have enough evidence to measure productivity, work
quality, money saved, or which model produces the best results.

The proposed first feature is an on-demand "Your Copilot week" brief:
deterministic local calculations establish the facts, and a model explains a
small selection of those facts. Every finding remains connected to its evidence.

The official Copilot SDK can provide model access through the user's Copilot
account without a separate model-provider API key or a Tokenotch-hosted backend.
This still uses cloud inference and consumes the applicable Copilot allowance.

## What Tokenotch captures today

These findings come from the current source and documentation, not an
inspection of a user's saved archive. Schema capability does not establish
that a particular user has enough observations.

| Data source | Available evidence | Important limits |
| --- | --- | --- |
| Live observations | Model IDs, input/output/cached-input tokens, call counts, latest session context readings | Memory-only; at most 24 hours, 4,096 calls, and latest context for up to 100 sessions. Restart and clearing observations remove live metrics. |
| Opt-in daily history | Tokens and calls by day/model; independent latency sums and sample counts; context high-water marks; successful/failed compaction counts; recording coverage and gap markers | Retained until deleted. Daily aggregation loses individual-call chronology and session attribution. No pre-consent backfill. |
| Separately opt-in saved timelines | Pseudonymous session IDs, timestamped calls and supported lifecycle events, reported token/model/latency fields, context and compaction events | Default seven-day retention, selectable 1/7/30 days, plus event/session caps. Incomplete timelines are labeled. |
| Account usage snapshots | Runtime-reported entitlement, used/remaining allowance, reset information | Current snapshots are not a historical quota series. Local token counts are not account billing totals. |

Token and context metrics come from the CLI integration. Current VS Code hooks
provide supported lifecycle observations, not equivalent token/context coverage.
Prompts, responses, commands, source, paths, and raw errors are not part of the
saved timeline metadata.

Relevant implementation:

- [Daily history storage](../../sources/Core/UsageHistoryStore.swift)
- [Timeline storage](../../sources/Core/SessionTimelineStore.swift)
- [Timeline event fields](../../sources/Core/SessionTimeline.swift)
- [Account and token models](../../sources/Core/CopilotUsage.swift)
- [Current collection and retention documentation](../../README.md)

## Insights supported by the existing evidence

| Question | Feasibility and boundary |
| --- | --- |
| What changed in my usage this week? | Compare observed tokens, calls, model mix, and latency when coverage permits. |
| Where did the token increase come from? | Decompose changes by day/model, input/output/cache, and call volume versus tokens per call. This explains the arithmetic, not the task-level cause. |
| Is Copilot responding more slowly? | Compare sample-weighted mean first-token latency and call duration, including within the same model. Task complexity and other confounders remain unknown. |
| Which sessions had context pressure or repeated compactions? | Describe retained session events. Do not infer that compaction caused a poor result. |
| Which model gives me better results? | Not established: task classification and outcome/quality evidence are missing. |
| Am I saving time or money? | Not established: call duration is not human time saved, tokens are not billing, and stopping is not proof of task success. |

The existing [history insight engine](../../sources/Core/HistoryInsights.swift)
already compares model mix, mean first-token latency, mean call duration, and
compaction frequency across the last seven completed reporting days and the
preceding seven. AI would build on this evidence rather than replace its math.

Current directional comparisons require calls on all fourteen days, collection
beginning before the window, and no known recording gaps. Model mix additionally
needs at least 20 calls per period; latency needs at least 20 valid samples and
80% field coverage per period. These gates may exclude normal weekday-only use.

Reevaluate baseline design before expanding the feature. Matched weekdays or
explicit observed-day comparisons may be worth considering, but must not treat
missing dates as zero or silently weaken evidence requirements. Daily aggregates
cannot recover precise intraday comparisons, latency percentiles, or discarded
per-call detail.

## Proposed role of AI

Keep statistical calculation and evidence eligibility local and deterministic.
Give the model a bounded evidence bundle containing:

- Exact periods and reporting time zone.
- Calculated values, differences, units, and contributing models.
- Sample counts, missing-field coverage, recording gaps, and eligibility.
- Local evidence identifiers that Tokenotch can resolve to the captured snapshot.

The model's job is to prioritize and explain findings in plain language. Separate
observations from hypotheses and optional experiments; do not present an
association as a cause or invent a confidence score.

Illustrative wording, not a finding about actual user data:

> Observed input tokens increased mainly because calls contained more input,
> rather than because you made more calls.

Tokenotch must calculate and substantiate that claim before allowing it into a
brief. Requested structured output should reference known evidence identifiers;
the app should validate those references and reject unsupported numerical claims.
Insufficient evidence should produce an explicit limitation, not a generated
explanation of an unknown trend.

A template-based summary remains a useful non-AI baseline and fallback. If AI
generation fails, report that failure and label any deterministic summary as
such rather than presenting it as a successful AI result.

## How a Copilot model call could work

1. The user selects "Generate insights" and approves the disclosed submission.
2. Tokenotch builds the minimal evidence summary locally.
3. A dedicated integration opens a Copilot SDK session using the account
   authenticated in Tokenotch's isolated CLI runtime configuration.
4. It discovers available models and selects one allowed for that account and
   organization; do not assume a hard-coded model is available.
5. It submits the evidence and constrained summarization instructions.
6. Tokenotch validates the response and displays it beside the local evidence links.
7. The dedicated session is closed and the result may be cached against its
   evidence snapshot, model, and prompt version.

Start with one user-triggered request and no scheduled background generation.
Bound payload/output size, support cancellation and timeouts, and avoid
unbounded retries that could consume allowance repeatedly.

### Existing foundation and implementation options

[CopilotRuntime.swift](../../sources/Core/CopilotRuntime.swift) already launches
the selected CLI executable for browser sign-in and headless JSON-RPC calls.
It currently reads runtime status, authentication, and account quotas; it does
not create AI conversations or handle generation streams.

The runtime uses a private `COPILOT_HOME`, an isolated working directory, and a
restricted environment. A new integration should preserve these boundaries and
use the intended account, not accidentally inherit another terminal identity,
ambient tokens, provider settings, or unrelated CLI configuration.

The official SDK currently lists TypeScript, Python, Go, .NET, Java, and Rust,
not Swift. The initial preference is a small bundled helper using the official
Go SDK, communicating with the Swift app over a bounded local interface and
using the selected Copilot CLI executable.

This is a preference to investigate, not a settled dependency decision:

- An official-SDK helper reduces custom session-protocol maintenance but adds
  packaging, signing, process lifecycle, and SDK/CLI compatibility work.
- Extending the Swift JSON-RPC client avoids another language but requires
  maintaining generation events, permissions, cancellation, and compatibility.
- Template summaries require no model access and provide a comparison baseline.
- On-device inference could preserve a local-only submission boundary, but is
  a separate integration and hardware/model-quality decision.

Do not call undocumented Copilot endpoints or extract credentials to emulate a
provider API. Use the supported runtime authentication and SDK integration.

## Privacy, permissions, and usage boundaries

- Local history consent is not consent to cloud inference. Require a separate,
  clear opt-in and make the submitted summary inspectable.
- Send only allowlisted aggregate evidence. Do not send the database, raw
  session identifiers, transcripts, repository files, paths, or credentials.
- The Copilot SDK is an agent runtime with first-party tools exposed by
  default. Explicitly disable unnecessary tools and deny permission requests.
  Do not rely on prompt instructions alone to prevent file or shell access.
- Verify that unrelated hooks, plugins, extensions, MCP servers, and custom
  instructions cannot expand the intended input or capabilities.
- Keep Tokenotch's existing isolated authentication behavior. Never log credentials
  or sensitive payloads while diagnosing failures.
- Generation counts against the applicable Copilot usage allowance and is
  subject to account/model availability and organization policy. Do not promise
  free, unlimited, or a fixed per-brief cost.
- Tag or isolate Tokenotch-generated sessions so their own token use does not feed
  back into the usage trends being explained. Account quota changes must still
  remain truthful; filtering local analytics does not remove billed usage.
- Define cache retention, deletion, account separation, and invalidation before
  persisting generated briefs. Deleting evidence must not leave an undisclosed
  retained copy of its summary.

No claim is made here that a local subprocess means local inference, or that
deleting local data deletes any provider-side records. Recheck applicable data
handling and retention documentation before implementation.

## Possible future data additions

Only add data in response to a specific insight that cannot otherwise be
supported, with appropriate separate consent:

| Addition | What it could enable |
| --- | --- |
| User-selected task category | Comparisons among more similar activities instead of mixing debugging, writing, and other tasks. |
| Optional outcome feedback, such as useful / substantial rework | Outcome-aware observations; still not proof of model superiority or causation. |
| Retained account quota snapshots | Allowance pacing and tentative forecasts, subject to delayed upstream reporting and account-wide activity. |
| Longer-lived distribution summaries, if needed | Latency spread/percentile analysis after individual timeline events expire. |

Do not start by collecting transcripts or building productivity scores.

## Reevaluation checklist

- [ ] Confirm that representative opt-in histories support useful findings;
      evaluate missing days, pauses, restarts, and partial field reporting.
- [ ] Decide which comparison baselines are honest and useful for weekday users.
- [ ] Compare AI-written briefs with deterministic templates for added value,
      factual accuracy, unsupported claims, latency, and allowance consumption.
- [ ] Recheck official SDK language support, model discovery, authentication,
      billing, policy restrictions, and SDK/CLI compatibility.
- [ ] Prototype the Swift/helper boundary without accessing repository content
      or inheriting unintended tools/configuration.
- [ ] Define consent, preview, caching/deletion, account isolation, and exclusion
      of self-generated sessions from local analytics.
- [ ] Exercise sign-in failure, unavailable models, rate limits, insufficient
      allowance, cancellation, malformed output, and insufficient evidence.
- [ ] Decide whether the benefit justifies the extra integration and privacy
      surface before committing to implementation.

## External references

Reviewed during the discussion on 2026-09-22; these are moving documents and
must be checked again when the proposal is revisited.

- [Official Copilot SDK repository](https://github.com/github/copilot-sdk):
  supported languages, CLI/JSON-RPC architecture, model discovery, tool defaults,
  subscription requirements, and billing overview.
- [Copilot SDK authentication](https://docs.github.com/en/copilot/how-tos/copilot-sdk/auth/authenticate):
  signed-in-user authentication, including desktop application use.
- [Copilot SDK documentation](https://docs.github.com/en/copilot/how-tos/copilot-sdk):
  setup, features, integrations, and troubleshooting.

The intended product promise is: **understand how your observed Copilot usage
is changing**, not **let AI score your productivity**.
