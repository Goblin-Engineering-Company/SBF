# SBF 2026.11.05.1

**SBF 2026.11.05.1: Nothing Up Our Sleeves**

**The minimap button has a face again.**

A player sent in a bug report with a screenshot of an empty circle where the SBF button should be. Their minimap button addon had politely asked us to stop hand-building our own button. Fair. Our button's "icon" was the word SBF written on a dark circle, and button collectors only keep a real picture, so they kept nothing.

SBF now uses the standard minimap button library that everyone else uses, with a proper SBF badge: the letters, back where they belong, in brass on a real picture this time. It shows up in button collectors and minimap skins, and it shows up as a launcher in data broker bars too. Your button stays where you dragged it, and "Hide the minimap button" still works. The goblins were told that words typed on a button are not an icon. They painted the words onto a picture and called it a loophole. We allowed it.

**Forever: the bobber is in reach now.**

On WoW: Forever the interact key used to give up on far casts, so SBF had a whole kit for it: an "out of reach" alert and sound, a recast mode, a point-at-it-with-your-mouse mode, a camera tip and a saved fishing camera. With Forever live, the key reaches your bobber once SBF stretches its range, so all of that is gone on Forever:

- No more "Bobber out of reach" messages or sounds.
- The Bobber reach section is gone from Settings.
- A saved fishing camera from the beta isn't switched to anymore. Your camera is all yours.

SBF still stretches your interact range while you fish and puts your own setting back when you stop. That part is always on now, with nothing to set. If you turned it off during the beta, it's back on, because that's the bit that does the reaching.

The goblins kept the old kit in a crate out back, just in case. If a Thursday patch ever shortens the key again, type `/sbf reach classic` and the out-of-reach handling and its settings come back. `/sbf reach forever` puts them back in the crate.

**Small fixes.**

- `/sbf reach` on Forever tells you the range SBF uses. `/sbf reachmode` and `/sbf reachview` tell you they aren't needed there, instead of changing a setting that does nothing.
- On retail, `/sbf reachview` tells you the fishing camera is a Classic option.
- The "Out of reach" tooltip on the Stats tab only sends you to Settings when there's a Bobber reach section to find.
