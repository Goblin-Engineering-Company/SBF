# SBF 2026.10.20.1

**SBF 2026.10.20.1: The Pet Project**

**Your pet gets a say.**

Hunters and warlocks, this one's yours. Settings has a new Pet section, saved per character, so your demon's orders don't follow your mage around. Everything in it starts off.

- **Pet stance while fishing.** Pick Passive, Defensive, Assist or Aggressive (whichever your game has). When you press your fishing key out of combat and your pet is on some other stance, SBF puts it back. It finds the stance on your pet bar wherever you keep it, because the goblins know you rearranged it. SBF doesn't change the stance back when you stop fishing.
- **Fight when my pet is fighting.** If your pet is attacking something and you aren't in combat yet, your fishing key sends your Combat action instead of casting. Needs something in the Combat slot.
- **Target what my pet is attacking first.** When the key fights for your pet, it targets your pet's enemy first. If you already have a hostile target, it keeps yours. Untick it if your own combat macro picks its target.

A player on Forever asked for this one, and the goblins were glad to help. The pets were less glad. They liked standing there.

**Your fishing key fights back.**

Something jumps you while your line is in the water? Your fishing key now reels in its ambitions, drops the line and fights for the rest of the fight, the same as retail. Before, the key stayed stuck on looting until the fight was over, and your character just stood there holding a pole at the problem. Rather keep the key on looting, in case a fish bites mid-brawl? Untick "Fight instead of looting when combat starts" under Settings, Fishing behavior. Needs something in the Combat slot, which every character has unless you cleared it.

**Hunters shoot now (Forever).**

On Forever the default Combat action used to be melee auto-attack only, which is a bold choice for someone holding a bow. Hunters on the default now get both: you swing when something is in your face, and Auto Shot fires when it isn't. Up close you may see a "Target too close" message from the shot line. It's harmless, and the goblins are working on their people skills. One press is enough; Auto Shot keeps going on its own. Existing characters move over on their own, and a combat macro you dragged in yourself is left alone.

**Our advice: bring your own combat macro (Forever).**

Forever has no Single-Button Assistant, so SBF's default combat action can only auto-attack. That's fine for scaring off a rabbit and not much else. Anything with teeth will win. If you fish anywhere dangerous, make a WoW macro with your class's real attacks and drag it into the Combat (attack) slot. SBF runs it whenever you're in combat, from the same fishing key. One example, from a low-level hunter:

```
/startattack
/cast Raptor Strike
/castsequence reset=target/combat Serpent Sting, Concussive Shot, Arcane Shot, Arcane Shot
```

Raptor Strike lands when something is in your face, and the shots fire when it isn't. Warlocks, swap in your own spells. Your demon will appreciate the help.

**Empty corpses stop holding you hostage (Forever).**

Forever now opens a loot window even when a corpse has nothing on it. With Ultra fast loot on, that empty window stayed open where you couldn't see it, and your character stood there "looting" until you walked away. SBF now closes an empty window by itself.

**Small fixes.**

- The Buffs and Boat slots now take a spell when you click the slot while holding it, not only by dragging.
- On Forever, a fight that started soon after you stopped fishing could throw up "Interface action failed because of an AddOn". SBF now waits for the fight to end before it puts your interact range back.
- The slot tooltips say what each slot actually takes. The Buffs one used to promise macros. It lied. We had words with it.
