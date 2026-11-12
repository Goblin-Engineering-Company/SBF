# SBF 2026.11.11.1

**SBF 2026.11.11.1: Stay Where We Put You**

**Your profile stays put.**

A player told us their gear loadout worked for a few minutes, then started flipping back to default. They were right, and it was us. Every time you pressed the fishing key, SBF asked which profile belongs to the spot you're standing in. A profile you picked by hand, and didn't bind to a zone, isn't anyone's answer to that question, so SBF swapped you back to your default profile on the next cast. Your gear set went with it.

It only started after you saved, which is why it looked fine while you were still setting things up.

Now a profile you pick stays picked until you move to another zone or subzone, or log back in. Walk into a zone you've bound a profile to and SBF still switches for you, same as always. It also checks right away when you turn auto-swap back on, delete the profile you're using, or switch between Warband and Individual profiles, so you land on the profile that belongs where you're standing. The goblin responsible has been reassigned to the bait shop, where nothing moves unless you move it.

**Forever: the bobber reach handling is actually off now.**

The last update said that on WoW: Forever, SBF stops worrying about bobbers out of reach and hides the Bobber reach settings. On your end, none of that happened. SBF works out which game it's in when it loads, and our check for Forever was written against the beta, which introduced itself differently than the live game does. So SBF decided you were playing Classic and kept running all the Classic reach handling.

It recognizes Forever properly now, and here is exactly what that changes on Forever:

- Pressing the fishing key on a bobber that's out of reach no longer recasts for you. Forever's interact key reaches your casts on its own.
- The out-of-reach alert, its sound and the mouseover switching are gone, and so is the Bobber reach section in Settings.
- SBF no longer switches to your saved fishing camera when you start fishing. Your camera is yours.
- SBF still raises the interact range to 60 yards while you fish and puts yours back when you stop. There's no setting for it on Forever, so if you had turned the raise off or picked your own distance, that choice no longer applies there.
- The out-of-reach count on the Stats tab only shows on Classic now.

If a future patch ever shortens Forever's reach again, `/sbf reach classic` brings all of the Classic handling back, and `/sbf reach forever` turns it off again. Those two commands only start working on Forever with this update. Classic players: nothing changes for you.

**One flash, not two.**

Switching profile and putting that profile's gear on in the same press flashed the profile name twice on top of itself. Once is plenty.

**Better bug reports.**

`/sbf bug` now lists every profile you have: which one is active, which one is your default, which one the spot you're standing in would pick, whether each one has a gear set and a pole, and which zones it's bound to. For your active profile it shows whether the game thinks the set is on and whether SBF does, since SBF leaves the pole out of that check when your profile brings its own pole. It also says whether SBF thinks your fishing gear is on, and on Forever it now says WoW: Forever instead of an unknown game. Profile and gear set names stay out of it, the same as your character name. If your gear or profile ever does something odd, that one paste tells us why.
