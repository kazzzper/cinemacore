# core/fetch

**Planned — tracked as `T-005`.** No code yet, by design.

Will own bytes on the wire:

- Segmented downloader with HTTP `Range` resume and interrupt-safety
- Media proxy: range-aware streaming with cookie/`User-Agent` injection
- SRT → WebVTT conversion for the player path

Keep it independent of `provider` internals: it takes a URL + headers, returns a stream or a file.

Do not implement ahead of the task.
