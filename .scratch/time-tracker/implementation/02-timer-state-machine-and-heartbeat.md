# 02: Timer State Machine and Heartbeat Checkpointing

Status: completed
Phase: 1 - Core Engine
Dependencies: 01

## Scope
Implement the single-active-timer state machine with monotonic UTC epoch arithmetic and 60-second heartbeat persistence.

## Deliverables
- `TimerStateMachine` with methods: `start(activityId, comment, tags)`, `pause()`, `resume()`, `stop(comment)`, and atomic `switch(newActivityId)`.
- Monotonic elapsed duration calculation: `(is_paused ? paused_at : nowUtc) - started_at - accumulated_pause`.
- Periodic 60-second background heartbeat task updating `last_heartbeat_epoch_ms` in `active_timer`.
- Boot-up crash recovery checker detecting gaps $>6\text{h}$ and offering session resumption or truncation.
- Unit tests covering time zone shifts, DST transitions, pause accumulators, and atomic switches.
