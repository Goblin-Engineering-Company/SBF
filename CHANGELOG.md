# SBF 2026.08.17.2

**Updated for World of Warcraft 12.1, Curse of Ula'tek.**

Patch 12.1 changed the rules for how addons read your buffs, and SBF's buff checks hadn't caught up. The result was a stream of Lua errors any time the game hides buff information.

- **Fixed the error spam.** SBF now steps back cleanly when the game hides buff data instead of throwing an error at you several times a second.
- **Fixed the fishing-perception readout,** which hit the same wall and could surface the error through Haul's perception field as well.
- **Marked compatible with 12.1,** so the client stops flagging SBF as out of date.

Fishing itself is unchanged.
