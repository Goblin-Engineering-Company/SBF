# SBF 2026.09.01.1

**If you do not play in English, this is the release that makes SBF work.**

Huge thanks to **Fisu**, who found and reported both of the bugs below with the exact cause already tracked down. They had been in SBF since the beginning, and they were invisible to us because everything works fine on an English client. That is a rough way to meet an addon, and the report was better than most bug reports we write ourselves.

- **The fishing key now casts on every language.** The built-in "Cast Fishing" action was hard-coded to the English spell name. On a German, French, Spanish or any other non-English client that name does not exist, and a macro pointing at a spell that does not exist fails without saying anything. So a fresh install did nothing at all when you pressed the key. SBF now looks the spell up properly, in whatever your client calls it.
- **Catches, casts and stats are recorded again.** SBF worked out whether you were fishing by checking the spell name and one specific spell ID. Neither matched on Fisu's client, so SBF never noticed the fishing line was out. Fishing worked, fish were caught, and the Stats tab sat at zero. It now recognizes the cast by reading your own fishing spellbook instead of assuming.
- **Fighting back works on every language too.** The built-in combat action had the same problem as the fishing key: it named the assist spell in English, so on any other client it quietly cast nothing while SBF carried on as if it had. If you fish somewhere things attack you, this is the one you will notice.
- **Food, drink and boat buffs are tracked correctly** on non-English clients too. Same root cause in two more places, found while checking whether anything else made the same assumption.

If you reported odd behavior before and gave up, please try again.

**Slots that are switched off now stay off.**

- **Turning a slot off works, and keeps working.** Two separate faults could let a slot you had switched off keep firing. One left the slot's own key connected. The other could quietly disconnect the options window from your live profile after an automatic profile swap, so the switch you flipped was writing somewhere nothing read. The window agreed with you while the addon carried on regardless.
- **Edits stick.** The same disconnect could throw away a change you had just made, with no error and nothing to see.

**The loot key.**

- **Fixed a loot key that stopped working after an update.** A one-time upgrade step could remove your loot key binding while moving it, leaving you with nothing bound and no message about it. It now checks the move succeeded before removing anything, and tells you at login if no key can reach Interact.
- **Fixed two other ways the loot key could go dead** and never recover on its own, including one that could freeze it for the rest of the session.

**Chum, and items the game has changed.**

- **The Midnight chums are corrected.** Blizzard removed the use effect from Shimmer Spinefish, Tender Lumifin and Hollow Grouper. SBF was still treating them as chum, reporting them as thrown while nothing happened. They are out, and Sin'dorei Swarmer and Root Crab now track the right buffs.
- **An item that can no longer be used is skipped** instead of being thrown over and over, so one dead item cannot stall your rotation.
- **Hide items you never want offered.** Shift and left-click any item in a slot picker to hide it. Turn on "Show hidden items" in Settings to bring them back.

**New: telling us when something goes wrong.**

- **Report a bug.** There is a button at the top of the About page. It opens a window with a summary of your setup that you can copy straight into a report: versions, settings, what is in each slot and which item would fire next, and anything that went wrong during the session. It contains no character name, realm or guild.
- On a non-English client it also includes your language and fishing spell details, so the next report like Fisu's can be answered without a round of questions.

**New: the AddOns button and the minimap.**

- **SBF now appears in the game's AddOns menu** on the minimap, where it should have been all along. Haul, Megaphone, Gadgets and Coffer are in there now too.
- **You can hide the minimap button.** Settings, Minimap, "Hide the minimap button". You can still open SBF with /sbf or from the AddOns menu, and right-clicking SBF there puts the button back.
