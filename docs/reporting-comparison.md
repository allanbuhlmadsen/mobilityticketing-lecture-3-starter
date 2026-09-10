# Where should reporting logic execute?

Lecture 3 implementation lab. Four mechanisms for daily captured revenue, compared against six changes to the source data.

## Evidence

All figures below are for `2026-04-29`. The seed data contains two captured payments of 36.00, one per operator. Test cases were run one at a time, with
all four mechanisms measured between each, so that every divergence can be attributed to a specific write.

Reproducing these figures requires a fresh container: `docker compose down`,
`docker compose up -d`, the three migrations in order, and one
`refresh materialized view daily_captured_revenue` before case 1.

### SQL object definitions

- Direct query: `database/postgres/queries/base_revenue.sql`, unchanged.
- Function: `captured_revenue_for_day(text, date)`, from
  `database/postgres/migrations/020_reporting_function.sql`.
- Materialized view: `daily_captured_revenue`, created `with no data` and
  carrying a unique index on `(operator_id, revenue_date)`, from
  `database/postgres/migrations/022_daily_captured_revenue.sql`.
- Trigger and summary table: `daily_revenue_by_operator`,
  `add_inserted_payment_to_daily_revenue()` and
  `payments_daily_revenue_after_insert`, from
  `database/postgres/migrations/021_daily_revenue_trigger.sql`. Applied as
  supplied; no branches were added.

### Baseline, before any test case

| Mechanism | OP-METRO | OP-BUS |
| --- | --- | --- |
| Direct query | 36.00 / 1 | 36.00 / 1 |
| Function | 36.00 / 1 | 36.00 / 1 |
| Materialized view | `ERROR: has not been populated` | — |
| Trigger table | absent | absent |

Three different answers before any data changed. The view raises an error rather than returning rows, because it was created `with no data`. The trigger table is empty because the trigger was created after the seed data was loaded and therefore never observed those payments.

After `refresh materialized view daily_captured_revenue`, the view agrees with
the source. The trigger table remains empty; no command exists that would populate it.

### Case 1: captured payment inserted

`PAY-CASE-CAPTURED`, 36.00, `TICKET-1`, which belongs to OP-METRO.

| Mechanism | OP-METRO | OP-BUS |
| --- | --- | --- |
| Direct query | 72.00 / 2 | 36.00 / 1 |
| Function | 72.00 / 2 | 36.00 / 1 |
| Materialized view | 36.00 / 1 | 36.00 / 1 |
| Trigger table | 36.00 / 1 | absent |

**This is the captured disagreement required by the lab.** Three mechanisms
report three different figures for the same operator on the same date. The view and the trigger table both show 36.00, but the figures are not equivalent: the view holds the correct value as of its last refresh, while the trigger table holds the sum of the one payment it happened to see.

### Case 2: failed payment inserted

`PAY-CASE-FAILED`, 50.00, status `Failed`.

No figure changed anywhere. The direct query and the function filter on `status = 'Captured'`; the trigger function returns early for any other status;
the view was already stale and would not have reacted to any write. Three mechanisms were right for the right reason and one was right by accident.

### Case 3: correction from Failed to Captured

| Mechanism | OP-METRO |
| --- | --- |
| Direct query | 122.00 / 3 |
| Function | 122.00 / 3 |
| Materialized view | 36.00 / 1 |
| Trigger table | 36.00 / 1 |

The source now holds three captured payments for OP-METRO: 36.00 from `PAYMENT-1`, 36.00 from `PAY-CASE-CAPTURED` and the 50.00 just corrected.
The trigger is declared `after insert on payments`. An update does not fire it, so the summary never learns that 50.00 arrived. The view is equally wrong but
recoverable; the summary is not.

### Case 4: correction from Captured to Refunded

| Mechanism | OP-METRO |
| --- | --- |
| Direct query | 86.00 / 2 |
| Function | 86.00 / 2 |
| Materialized view | 36.00 / 1 |
| Trigger table | 36.00 / 1 |

Refunding `PAY-CASE-CAPTURED` removes 36.00 from the source, leaving 86.00.
The summary's 36.00 is now composed entirely of `PAY-CASE-CAPTURED`, the payment that was just refunded, while omitting both payments that should count.
The figure is not merely out of date; it is made of the wrong rows.

### Case 5: test payment deleted

| Mechanism | OP-METRO |
| --- | --- |
| Direct query | 36.00 / 1 |
| Function | 36.00 / 1 |
| Materialized view | 36.00 / 1 |
| Trigger table | 36.00 / 1 |

All four agree, and the agreement is meaningless. The source figure comes from `PAYMENT-1`; the summary figure still comes from the refunded `PAY-CASE-CAPTURED`. Agreement between an authority and a derived copy is not
evidence that the copy is correct.

### Case 6: duplicate delivery of one gateway reference

`PAY-CASE-DUPLICATE` reuses `gateway-capture-0001`, already held by `PAYMENT-1`. The insert succeeded: `\d payments` confirms that this lecture's starter schema has only a primary key on `id`, with no unique constraint on `external_payment_reference`.

| Mechanism | OP-METRO |
| --- | --- |
| Direct query | 72.00 / 2 |
| Function | 72.00 / 2 |
| Materialized view | 36.00 / 1 |
| Trigger table | 72.00 / 2 |

The source now holds two captured payments for OP-METRO: 36.00 from `PAYMENT-1` and 36.00 from `PAY-CASE-DUPLICATE`, which record the same charge. This is the only case in which the direct query is wrong. It aggregates the source faithfully; the source contains one charge recorded twice. No reporting mechanism can distinguish two genuine payments from one delivered twice. The view appears closest to the truth only because it is stale, and reports 72.00 after a refresh.

## Responsibility matrix

`payments` is the authority for captured revenue. Everything below is derived from it, and every stored copy needs a stated freshness rule and rebuild path.

| Dimension | Direct query | SQL function | Materialized view | Trigger-maintained table |
| --- | --- | --- | --- | --- |
| Correctness | Correct by construction; reflects the source at read time | Same, and the logic exists in one place instead of being copied into each caller | Correct as of the last refresh; never wrong, only old | Wrong for anything other than an insert. Corrections, refunds and deletes never reach it |
| Freshness | Always current | Always current | Stale from the first write until someone refreshes | Current for inserts only; permanently diverges after the first correction |
| Write cost | None | None | None at write time; the refresh recomputes the whole aggregate | 5.587 ms of trigger time against 0.298 ms for the insert itself — roughly 19× the cost, on the purchase path |
| Read cost | Full aggregate over the join every time | Same as the direct query | One indexed lookup | One indexed lookup |
| Hidden side effects | None | None | None; staleness is visible only by comparison | One write becomes two. Five tables are locked. The caller sees only `INSERT 0 1` |
| Rebuildability | Not applicable; nothing is stored | Not applicable | `refresh materialized view daily_captured_revenue` restores it fully from the source | None supplied. The table cannot be rebuilt and has no backfill for rows written before the trigger existed |
| Operational complexity | None | One object to version and migrate | Must be refreshed at least once before it can be read at all; a schedule or trigger for the refresh must be owned by someone | Three objects, and the only one whose failure can reject an operational write |

### Authority, freshness rule and rebuild path

| Object | Authority | Freshness rule | Rebuild path |
| --- | --- | --- | --- |
| `payments` | Itself. The system of record for captured revenue | Current at commit | Not derived; restored from backup only |
| `captured_revenue_for_day` | `payments` | Reads the source at call time, so always current | Redeploy the function definition |
| `daily_captured_revenue` | `payments` | As of the last `refresh`; not current after any write | `refresh materialized view daily_captured_revenue` |
| `daily_revenue_by_operator` | Claims to derive from `payments`, but cannot be verified against it | No rule holds. Correct only if no payment is ever corrected or deleted | None exists. This is the central defect |

## Side-effect trace: one INSERT INTO payments

Traced with `explain analyze` and `pg_locks` on a clean container.

1. **Constraints and references checked.** In this lecture's schema, only the
   primary key on `payments.id`. The starter schema for lecture 3 carries no
   foreign keys, no not-null columns beyond the key, and no unique constraint on
   `external_payment_reference` — confirmed with `\d payments`. Nothing verifies
   that `USER-1` or `TICKET-1` exist, or that the gateway reference is new.

2. **Trigger execution.** `payments_daily_revenue_after_insert` fires for each
   row after the insert. It runs `add_inserted_payment_to_daily_revenue`, which
   returns early unless the status is exactly `'Captured'`, then resolves the
   operator by joining `tickets`, `trips` and `routes`.

3. **Summary-table writes.** One `insert ... on conflict do update` against
   `daily_revenue_by_operator`, keyed on `(operator_id, revenue_date)`. The
   application issued one write; the database performed two.

4. **Rows and locks touched.** `pg_locks` during an open transaction shows
   `RowExclusiveLock` on `payments` and on `daily_revenue_by_operator`, plus
   `AccessShareLock` on `tickets`, `trips` and `routes` from the operator
   lookup. Five tables are involved in what the caller sees as one insert.

5. **Commit and rollback behaviour.** The trigger runs inside the caller's
   transaction. A rollback discards the summary update along with the payment;
   the two cannot diverge on failure. The cost is that a failure inside the
   trigger fails the payment write itself — reporting logic can now reject an
   operational write.

6. **When each report becomes current.**
   - Direct query and function: immediately at commit, since they read the source.
   - Trigger table: at the same commit, but only for inserts. Corrections and
     deletions never reach it.
   - Materialized view: not until someone runs `refresh materialized view`.
     No write makes it current.

7. **What the application observes.** `INSERT 0 1`. Nothing in the response
   reveals that a second table was written, that three more were read, or that
   the write cost 5.9 ms instead of 0.3 ms. `explain analyze` shows the trigger
   took 5.587 ms of that total — roughly nineteen times the cost of the insert
   itself, on the latency-sensitive purchase path.

## Issue register

### Issue 1: The trigger-maintained summary has no authority and no rebuild path

- **Evidence:** After the six test cases, `daily_revenue_by_operator` reported
  36.00 for OP-METRO while the source reported 122.00, then 86.00, then 36.00
  again. At the end of case 5 the two agreed on 36.00 by coincidence: the
  source figure came from `PAYMENT-1`, while the summary figure came from
  `PAY-CASE-CAPTURED`, a payment that had been refunded. OP-BUS was absent from
  the summary throughout, since its only payment predates the trigger.

- **Problem:** The trigger fires `after insert` only. Corrections, refunds and
  deletions never reach the summary, and rows written before the trigger
  existed were never counted. The table is not a function of the current data;
  it is an accumulated record of the writes the trigger happened to observe.

- **Consequence:** The error is silent and permanent. An operator reading the
  report sees a plausible number with no indication that it is wrong, and no
  command exists that would correct it. Worse, the figure can be composed of
  exactly the payments that should not count while missing those that should —
  which is what happened after case 4.

- **Specific improvement:** Two directions. Add `after update` and
  `after delete` branches and a backfill statement that populates the table
  from `payments` before the trigger is enabled, which makes the table
  rebuildable but adds three more code paths to the write route. Or replace the
  table with the materialized view, which is rebuildable by definition through
  a single refresh. The second is preferred here because correctness comes from
  recomputation rather than from remembering to handle every case.

- **Open question:** If the summary is kept, who owns the reconciliation that
  detects drift, and how often does it run? A derived table with no comparison
  against its source cannot be trusted regardless of how many trigger branches
  it has.

## Decision record

### Decision: use the SQL function for current figures and the materialized view for reporting; do not keep the trigger-maintained table

- **Context:** Operators need daily captured revenue. The brief for the
  reporting workload states that reports tolerate latency and need not reflect
  every operational write immediately. Purchase and validation, by contrast,
  are latency-sensitive. Two payments exist in the seed data, so read cost is
  not currently a constraint on any approach.

- **Decision:** `captured_revenue_for_day` serves any caller that needs a
  figure which is correct right now. `daily_captured_revenue` serves scheduled
  reporting, refreshed on a schedule that the reporting owner sets.
  `daily_revenue_by_operator` is not adopted.

- **Rationale tied to the workload, not to preference:**

  The reporting workload tolerates staleness, so the view's freshness gap costs
  nothing that the brief asks for. What reporting cannot tolerate is a figure
  that is wrong in a way nobody can detect or repair, which is precisely what
  the trigger table produced in test cases 3, 4 and 5.

  The purchase workload is latency-sensitive, and the trigger places 5.587 ms
  of reporting work inside it against 0.298 ms for the payment write itself.
  Reporting is the workload that tolerates delay; loading its cost onto the one
  that does not is the wrong direction.

  The trigger also couples the two paths in a way that can fail the wrong
  thing. Because it runs in the caller's transaction, a fault in reporting
  logic rejects a payment. A refresh that fails leaves reporting stale and
  leaves purchase untouched.

- **Consequences accepted:** Reports show data as of the last refresh, and
  someone must own the refresh schedule. The unique index on
  `daily_captured_revenue` allows `refresh materialized view concurrently`,
  so refreshing need not block readers. The view must be refreshed once before
  it can be read at all — an unpopulated view raises an error rather than
  returning no rows, which is what happened at baseline in this lab.

- **What this decision does not settle:** Test case 6 showed the direct query,
  the function and the trigger table all reporting 72.00 for a single actual
  charge delivered twice. No reporting mechanism can detect that, because the
  duplicate is present in the source. The fix belongs in the schema — a unique
  constraint on `payments.external_payment_reference`, as implemented in the
  lecture 2 migration but absent from this lecture's starter schema.