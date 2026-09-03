# SBF 2026.09.02.4

**Every edit in the options window sticks now.**

Last release fixed the on/off switch writing to a dead copy of your settings after an automatic profile swap. This release fixes the same disconnect everywhere else on the row, because it turned out the switch was not the only victim:

- **Items you add, remove or reorder in a slot picker stay added, removed and reordered**, including when a profile swap happens mid-session with the window open. Before this, an edit could look fine on screen, never reach the addon, and be gone after a reload.
- **The firing mode button and the buff-to-watch box** write to your live profile the same way now.
- **Your selected items show their zone info again.** The orange "not confirmed in this zone" tint, the list of zones an item has worked in, and the works-in-all-zones toggle were only appearing on items you had NOT picked. They now show on the items you actually fish with, which is where they matter.

**Hiding items is reversible, like the tooltip always said.**

- Hiding a learned item from a picker used to also delete the record that would let "Show hidden items" bring it back, so the promised way back did not exist. It does now.
- There is a **"Restore all hidden" button** in Settings next to "Show hidden items", for when you want everything back without clicking each one.
- The item tooltip claimed shift-click did two different things. It does one thing: hide. The tooltip says so.

**Boats: SBF will never cast a spell your character does not know.**

If you share one profile across characters, the boat slot can hold Levitate, Path of Frost, Water Walking and Zen Flight side by side. Each character is supposed to use the ones it knows and skip the rest. One path through the code skipped that check and fired whatever was loaded, so a monk could sit there trying to cast a priest spell forever instead of using its own. Every cast now goes through the same "do you actually know this?" gate, on every character, in every mode.

**Non-English clients: the follow-through.**

Last release made SBF work off English. This one finishes the corners we found while checking everything else:

- **A cast that misses fishable water is now detected on every language**: the short back-off, the fail sound, and the log entry all fire. Off English these were silently doing nothing, so a whole class of cast results was missing from your Stats.
- **The Perception stat reads correctly** instead of showing 0.
- **Pole enchant time-left reads correctly on Russian, Korean and Chinese clients.** Before this the timer never matched, SBF thought the enchant was always expired, and it would burn roughly three lures per fishing cycle re-applying one that was fine.

**Small but real.**

- Building a status report, or having a Haul bar show SBF's next action, no longer nudges the addon itself. Reading is reading now; before, just drawing a bar could quietly consume a chum burst or start a boat sequence.
- A cast you reeled in normally could occasionally be logged as "nothing happened" because the key watcher blinked at the wrong instant. It waits for real evidence now.
- Status reports now include the combat and heal slots, which were missing entirely.
- Pressing Backspace in the bug report window no longer erases the report you were about to copy.
