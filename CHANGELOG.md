# SBF 2026.09.03.6

**SBF now gets out of the way when you stop fishing.**

New in Settings under Fishing behavior: an **Idle timeout** (30 seconds by default). When you stop fishing for that long, SBF stands down completely: all of its background key and buff monitoring stops, and the addon's CPU use drops to roughly 0% until you fish again. Your first cast press wakes everything back up, instantly. If you use gear profiles, your normal gear and audio come back at that same moment, exactly like before; the timeout now covers everyone, gear profiles or not. This is a performance release as much as a feature: parked in town, SBF now costs the same as an addon that is not running at all.

**Looting cannot silently die anymore, in either mode.**

SBF's looting rides the game's own interact key. If the client option "Enable interact key" (Options, Gameplay, Controls) is off, looting just quietly does nothing: no error, the key does not respond, and it looks like SBF is broken. Some of you found the accidental workaround of turning on two-button mode, which happened to flip that option back on. Now SBF keeps the option enabled itself whenever looting works through interact, in single-button AND two-button mode, and re-checks it on every cast so a mid-session change cannot strand you. If SBF has to turn it back on, it tells you in chat.

**Settings clarity.**

- "Get out of the way in combat" is now "Hide interface in combat", which says what it does.
- The idle seconds field moved out of Profile advanced mode into Fishing behavior, since it is no longer a gear-only setting. The gear checkbox stays where it was and simply rides the shared timeout.
- The labeled rows in Fishing behavior now match the size and alignment of the checkbox text around them.

**Thank you.**

This release exists because players took the time to report what they were seeing: **bayerithe99706**, **Murphieus**, **joesonline**, and **Delphinen** all sent in issues that pointed us straight at the problems above. If we did this right, every one of them is fixed for you now.

Found something else? Want a say in what gets built next? Head to **https://goblineng.co** to report bugs and vote on upcoming features, or use the one-click bug report on the About tab (it builds a paste-ready blob, and it is exactly how these issues got found). The votes genuinely steer the roadmap.
