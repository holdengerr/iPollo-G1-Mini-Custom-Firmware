# Contributing

## Scope

This repository is for the custom firmware stack only.

Do not add:

- vendor firmware blobs
- extracted stock root filesystems
- raw captures
- large generated release artifacts

Those belong in local inputs, release outputs, or the separate stock research repository.

## Before Opening Changes

Please keep changes narrowly scoped and aligned with the current project structure:

- `src/web/` for UI
- `src/openwrt/cgi/` for web endpoints
- `src/openwrt/bin/` for helpers and generators
- `src/openwrt/init/` for service startup
- `docs/` for user and developer docs

## Validation Expectations

For behavior changes, include the most relevant checks you ran. Typical examples:

- dashboard load
- admin page load
- login flow
- pool save
- profile apply
- miner restart
- recovery path
- overnight or long-run validation for mining behavior changes

## Documentation

If you change operator-visible behavior, update the matching user docs in the same change.
