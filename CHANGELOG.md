# SBF 2026.11.19.3

**SBF 2026.11.19.3: Wrong Target**

A small bug-fix release, fresh off the repair bench.

**Fishing works with a vendor targeted.** If you walked away from a vendor and started fishing without clearing your target, SBF could jam. A self-buff, heal or boat spell in one of your slots went to the vendor instead of you (or failed as out of range), and the key never got around to casting. The vendor did not need Thorns. Those spells now always land on you, whether the fishing key fires them or you press the slot on its own key, and your target is left alone. Your combat slot still goes at your enemy, and items and toys work as before.

**Custom macros stay out of fights.** If you put your own macro in a slot and set a combat action, the fishing key could fire that macro in the middle of a fight when its lines had their own [conditions], instead of your combat action. Its /cast and /use lines now wait until the fight is over, like every other slot. Fight first, fish later.

**No more skill-up error.** Sometimes the "Your skill in Fishing has increased" message arrives in a protected form that addons aren't allowed to read. SBF tried to read it anyway and threw an error every time that message came in. It now leaves the sealed envelope alone. Your skill level still updates the next time you open the profession window. Thanks to the player who sent in the error report.

**WoW: Forever: the fishing cast is found more reliably.** Forever's Fishing has a second spellbook entry, "Bait and Tackle", and SBF could mistake it for the fishing cast. The tackle box has been labeled. It works on any game language.

The goblin who kept buffing the shopkeeper has been reassigned. The shopkeeper has filed no complaint.
