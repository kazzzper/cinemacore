# core/store/library

**Planned — tracked as `T-005`.** No code yet, by design (see `rules/00-senior-doctrine.md`: no speculative code).

Will own the user library:

- Watchlist (add/remove/list)
- Watch history (seen events)
- Resume position keyed by `subjectId` (+ `s{season}_e{episode}` for series)
- SQLite persistence in `server`; mirrored to SwiftData/Room on device

Interface intent:

```go
type Library interface {
    Watchlist(ctx context.Context) ([]models.Subject, error)
    Toggle(ctx context.Context, id string) (added bool, err error)
    History(ctx context.Context) ([]models.Subject, error)
    Position(ctx context.Context, id string) (int64, error)
    SavePosition(ctx context.Context, id string, ms int64) error
}
```

Do not implement ahead of the task.
