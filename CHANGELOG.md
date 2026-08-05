# SBF 2026.08.04.7

A lot of bug fixes in this one. Most of them only bite in specific situations, so
you may never have hit them, but if you did they were annoying. There are some
quality of life improvements in here too, mostly around the fishing log telling you
what actually happened.

## Better cast outcome tracking

Casts used to fall into "interrupt" or "unknown" far more often than they should
have, which made those counts fairly useless. Outcomes are now sorted properly, so
the log tells you exactly what happened on every cast.

- Added NOTHING. You reeled properly and on time, the line just came up empty. That
  used to land in interrupt/unknown along with everything else.
- Pressing Escape now registers as an escape. It also used to show up as
  interrupt/unknown, which is why that number was never worth much.
- Improved catch logging. A catch is captured the moment the loot window opens, so
  recasting quickly no longer loses it.
- Improved chest logging. The Patiently Rewarded Chest and the Grandline Chest are
  tracked by their own IDs and register in the log properly, including when your
  bags are full and the loot window has to reopen.
- Improved loot kind detection generally, so what lands in the log is what actually
  happened.

## Fixed: non fishing loot logged as gathered

Loot that had nothing to do with fishing, herb nodes, mining and chests you opened
on your own, was being logged as gathered in the fishing journal. It skewed catch
rates and it was never meant to be there. Corrected.

## Fixed: windows locked during combat

The Welcome screen and the configuration windows could get stuck while you were in
combat, and you could not close or move them. They now get out of your way on their
own when combat starts and come back when it ends. It is a setting, so you can have
them collapse, hide completely, or stay put if you would rather they did not move.

## Improved buff handling

Buffs could get cross identified between items, so one item would end up watching
another item's buff and the rotation would act on the wrong thing. Items now hold
onto their own buff identity and cannot take one from a neighbor.

## Fixed: gear switching on its own

In a specific set of circumstances your gear would swap itself back to fishing gear
when it should have left it alone. Fixed.

## Fixed: controller support turning itself off

A controller setting was being changed when it should not have been. This should
also make SBF behave better alongside other controller addons.

## Skill numbers fill themselves in now

The game does not hand an addon your per expansion fishing skill until you have
opened the Fishing Journal yourself at least once. Until that happens SBF has
nothing to read, so the skill numbers sit there empty and it looks broken.

Refresh skill on cast takes care of it. The first time you press your fishing key
in a session, SBF flashes the journal open and shut, grabs the numbers and carries
on casting. You see a blink and nothing else. It only does this once per session,
only when the data is actually missing, and never in combat.

It is on by default and you can turn it off from either the Settings page or the
Skill Book page, whichever one you happen to be looking at.

## Polish

- Tooltips follow your cursor and read the same everywhere.
- A simpler Welcome screen.
- The Stats page no longer shows empty boxes where a character should be. A couple
  of symbols were outside the range the game font covers.
- Help text pointed at a few slash commands that do not exist. Those are gone, and
  the sound folder note now tells you where the setting actually lives.
- The Combat slot describes what it really does. It casts Single-Button Assistant
  at whatever you are already fighting, and picking up the nearest enemy is opt in.
- The idle gear restore help said the feature was off by default. It is on.
- SBF now shows up as "Single-Button Fishing" in your addon list instead of "SBF".

Happy fishing, and may every cast come up worth something.

GEC Management
