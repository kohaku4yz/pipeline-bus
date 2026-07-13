# Upstream pull request notes

This branch contains the optional, read-only Pipeline Bus visualizer prepared for
`kohaku4yz/pipeline-bus`.

The development-only GitHub Actions screenshot workflow is intentionally omitted
from the upstream submission. Visual QA remains available in the work fork, while
the upstream patch keeps the core repository free of additional CI requirements.

Suggested title:

`feat(frontend): add optional Pipeline Bus control room visualizer`

Suggested description:

```md
## Summary

Adds an optional, zero-dependency, read-only visualizer for Pipeline Bus.

- maps protocol states onto a route-and-station control room;
- accepts analytics payloads, extractor bundles, or bare task/status arrays;
- bounds long task histories with internal scrolling;
- includes responsive desktop and mobile layouts;
- includes the original hand-drawn Pipeline Bus / Clawd boarding animation;
- ships only synthetic public demo data;
- does not change pollers, reviewers, protocol files, task state, or branch behavior.

## Run locally

```bash
python3 -m http.server 8000 -d frontend
```

Then open `http://localhost:8000`.

## Validation

The work fork was validated with Chromium screenshots at 1600px, 1280px, and
390px widths. The upstream patch does not add a GitHub Actions dependency; local
screenshot capture remains available through `frontend/capture-preview.py`.

## Scope

This is a companion observation layer only. Pipeline Bus remains a pure-git
transport and continues to operate without a UI, build step, package manager, or
backend service.
```
