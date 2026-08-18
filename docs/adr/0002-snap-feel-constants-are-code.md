# 2. Snap feel constants live in code

Date: 2026-08-17

## Status

Accepted

## Context

The snapping prototype was tuned by hand: flick 220pt within 90ms with 80% axis dominance, edge press 260pt, corner press 140pt, corner sideways share 35%, wiggle 5 reversals within 0.7s with 30pt runs, settle 0.25s. Exposing these as settings would multiply the ways the gesture can feel wrong.

## Decision

The thresholds are named constants in `SnapFeel`, next to `MoveFeel`, and are locked by unit tests. The only user-facing setting is the per-gesture on/off switch (Flick, Edge Press, Corner Press, Wiggle) in Preferences and the status menu.

## Consequences

- Retuning is a code change with a test update, reviewed like any other.
- Users who dislike one trigger switch it off instead of tuning it.
