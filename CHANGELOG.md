# SBF 2026.09.06.2

**Buff learning can no longer be fooled by combat.**

The first bug report sent through the new in-game reporter (thank you, whoever you are!) uncovered a nasty one. When you enter or leave combat, the game briefly hides buff names, and SBF's buff learner could mistake a permanent equipment buff reappearing for the buff your chum fish just applied. Once that wrong learn stuck, the chum slot thought its buff was always up and simply stopped throwing fish, forever, with no error. Two fixes make this impossible now: the learner never compares buff snapshots across a combat change, and a thrown item can never learn a permanent buff at all (a real chum, food, or lure buff always has a timer; a buff with no timer is your gear talking). Both guards work on every item, including ones we have never seen.

**Seven chum fish are now built in.**

Five new fish joined the built-in catalog with verified buffs, so they work correctly on the first throw and can never mis-learn: Lynxfish, Gore Guppy, and Toxic Tlhapi (Skillful Chum), plus Arcane Wyrmfish and Spotted Killifish (Perceptive Chum). That covers the Coiled Isle catches alongside the Quel'Thalas ones from before. If your Toxic Tlhapi was stuck from the bug above, this release un-sticks it automatically.

**New: the zone buff glow.**

When a special area blessing that boosts fishing is on your character, the edges of your screen now glow a soft green so you know you are standing somewhere worth fishing. It ships watching Cursed Land and Waters, the Coiled Isle blessing behind Captain Tokka's reputation arc (it appears after Turning Back the Surges). The first time it lights up, SBF tells you on screen what the glow means. It never blocks your mouse or covers the middle of the screen, and it can be turned off in Settings under Fishing behavior.

**Bug reports got easier to read.**

The catalog section of the in-game bug report now shows item names instead of bare ID numbers, and labels each line so it is obvious whether the entry involves a built-in item or one SBF learned on its own.

**Found something? Want a say in what gets built next?**

Head to **https://goblineng.co** to report bugs and vote on upcoming features, or use the one-click bug report on the About tab. This entire release started from a single pasted report, so it works.
