# rule 09 — platform parity (iOS ⇄ Android)

Both apps are products of the same repo and the same contract. A feature that exists on one
platform and not the other is a defect, not a backlog item that waits for someone to notice.

## The rule

1. **One feature, two surfaces.** Every user-visible feature (screen, control, gesture, player
   behaviour, setting, download path) ships on **both** iOS and Android. Platform idioms may differ
   (SwiftUI vs Compose, `AVPlayer` vs Media3, `URLSession` vs OkHttp); the *outcome* may not.
2. **The second platform is part of the definition of done.** A task that adds or changes a feature
   is not `done` until the other platform either has the same feature or has a linked parity task
   (`T-xxx`) with a reason and an owner.
3. **Parity is tracked in [`docs/PARITY.md`](../docs/PARITY.md).** Any change to a feature row is
   part of the same commit as the code. The matrix is the source of truth for "what does Android
   have", not memory and not chat.
4. **Shared logic stays in `core/`.** If a rule can be expressed without a UI toolkit (caption
   ranking, episode filtering, source resolution, signing, cache naming), it belongs in `core/` or
   in a mirror module with the same tests on both sides — not copy-pasted into a view model.
   When a surface has to re-implement it (like `FreeSubtitles` and `SubtitleTracks` today), the port
   carries the same fixtures and the same test names, so a later change is obvious on both sides.
5. **Port the fix, not the file.** A platform-specific bug fix does not automatically apply to the
   other platform, but the *behaviour* must be checked there. Fix commits name the counterpart
   behaviour in the message or the progress note.

## When one platform ships first

- Register the parity task in the same session (`node tasks/bin/tasks.mjs add ...`).
- Add (or flip) the row in `docs/PARITY.md` with the gap called out.
- Leave the reason in `tasks/progress/<agent>.md`.
- The original task may reach `review`, not `done`, while the pair is open.

## Evidence

- Both targets build (`./gradlew :app:assembleDebug`, `xtool dev build`).
- Shared logic has tests on both sides; a port is not verified by "it compiles".
- On-device checks are recorded in the progress file per platform. A device that is not available
  is stated plainly — it is not implied to have passed.
