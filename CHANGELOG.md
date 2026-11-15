# SBF 2026.11.14.8

**SBF 2026.11.14.8: Quiet on the Docks**

**No more interact key spam.**

SBF loots your bobber through the game's interact key, so it checks that the "Enable interact key" option is on each time you press the fishing key, and puts it back if something turned it off. A few of you saw SBF's "turned the interact key back on" line over and over in chat. That was another addon changing the same setting, and SBF announcing every single time it put it back. It looked like SBF was the one making noise, and in a way it was.

Now SBF still fixes it, but it only tells you once per session. That one line says what the setting was changed to and, when it can tell, which addon changed it, so you know where to look.

A few other things changed along the way:

- While you're fishing, SBF puts the setting back right after something changes it, so your loot key never goes dead between casts.
- When you're not fishing, SBF leaves the setting alone. It no longer touches it when you log in.
- If something changes it in the middle of a fight, SBF can't fix it until the fight is over, so it puts it back the moment combat ends instead of waiting for your next cast.
- If another addon keeps fighting over it, SBF stops answering for a little while instead of trading blows every frame. Your next cast still fixes it.
- If the game refuses the change, SBF says so instead of claiming it's fixed, and that warning always shows, because it means your loot key may not work.

**Better bug reports.**

`/sbf bug` now lists the last times SBF had to put the interact key back, what it had been changed to, and which addons have been changing it and how often. If your loot key ever stops working, that paste tells us who did it.
