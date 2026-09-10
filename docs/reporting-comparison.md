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