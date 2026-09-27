# CI failure review

Use a failing CI run as an opportunity to improve the system, not only to make
the current run green. For each failure, capture the cause and decide whether a
lasting guarantee belongs in the model, tests, implementation, or architecture.

## Review prompts

1. What invariant or assumption failed? Which state, input, operation sequence,
   or schedule exposed it?
1. Would a TLA+ model make the relevant protocol or state transitions clearer?
   Add or extend a model when it can check meaningful safety or liveness
   properties.
1. Can property-based tests generate the inputs or operation sequences that
   exercise the boundary? Keep a small regression case for the discovered bug.
1. For concurrent Rust code, can the type and ownership structure express the
   guarantee? Consider synchronization semantics and concurrency-focused tests
   where runtime interleavings matter.
1. For TigerBeetle or ledger-style state, do transaction boundaries and
   idempotency preserve atomicity and domain invariants? Model and test the
   guarantee at the transaction boundary.
1. What architecture change would prevent this class of failure or make the
   invariant easier to review?

These are mechanisms to consider, not a required checklist of technologies.
Choose a mechanism that fits the code and risk. When no additional model,
property, concurrency, or transaction guarantee would help, record why and
still add a focused regression check when practical.

## Failure record

- **Failing job/check:**
- **Root cause and triggering condition:**
- **Invariant or assumption:**
- **Durable guarantee considered:** TLA+ / property-based / Rust concurrency /
  TigerBeetle transaction / other
- **Change made or reason no additional guarantee helps:**
- **Architecture consequence:**
