# CC Immunity Tooltip - WoW TBC Anniversary Addon

Shows creature crowd control immunities directly in their tooltips.

## Features

- **Comprehensive Database**: Pre-loaded with immunity data for 4,000+ creatures from TBC dungeons and raids
- **Difficulty-Aware**: Automatically detects Normal vs Heroic difficulty and shows appropriate immunities
- **Auto-Learning**: Remembers new immunities as you discover them in combat
- **Instant Tooltips**: Shows CC immunities directly in creature tooltips
- **Creature Type Detection**: Automatically applies immunity rules for Mechanical, Undead, Elemental, and Demon types
- **Slash Commands**: Manually add or clear immunities as needed

## Installation

1. Extract the addon to your WoW TBC directory:
   `World of Warcraft\_classic_\Interface\AddOns\CCImmunityTooltip\`

2. The folder should contain:
   - **CCImmunityTooltip.toc** - Addon manifest
   - **CCImmunityData.lua** - Compact immunity database (442 lines, 50KB)
   - **CCImmunityTooltip.lua** - Main addon logic (411 lines, 15KB)

3. Restart WoW or reload UI with `/reload`

The database uses efficient bitflag storage, reducing 4000+ creatures from ~4100 lines to just 442 lines.

## Usage

Simply mouse over any creature to see their CC immunities in the tooltip.

### CC Types Displayed

- **Polymorph** (Sheep) - Mage's polymorph spells
- **Fear** - Warlock fear, Priest psychic scream, etc.
- **Stun** - Hammer of Justice, Kidney Shot, etc.
- **Charm/MC** - Mind Control and Charm effects (same mechanic)
- **Slow** - Frost effects, Curse of Exhaustion
- **Root** - Entangling Roots, Frost Nova
- **Banish** - Warlock banish (Elementals/Demons only)
- **Sleep** - Wyvern Sting, Shackle Undead, etc.

## Commands

The addon automatically learns immunities as you play, but you can also manage them manually:

### View Help
```
/ccimmunity
/ccim
```

### Manually Set Immunities
Target a creature and use:
```
/ccim set [heroic|normal] <types>
```
Examples:
- `/ccim set sheep fear stun` - Set for current difficulty
- `/ccim set heroic sheep fear` - Set specific to heroic
- `/ccim set normal bleed` - Set specific to normal

### Clear Learned Immunities
```
/ccim clear [heroic|normal]
```
- `/ccim clear` - Clear for current target
- `/ccim clear heroic` - Clear heroic-specific immunities

### List All Learned Immunities
```
/ccim list
```
Shows all creatures you've learned immunities for

## Default Immunities

### By Creature Type:
- **Mechanical**: Immune to Polymorph, Mind Control, Bleed
- **Undead**: Immune to Polymorph, Mind Control, Bleed
- **Elemental**: Immune to Polymorph, Bleed
- **Demon**: Immune to Banish (can be banished but it's their specific CC)

### Bosses/Elites:
Most bosses and elite creatures are automatically marked as immune to:
- Polymorph
- Fear
- Mind Control
- Charm
- Sleep
- Banish

## How It Works

### Pre-loaded Database
The addon comes with immunity data for 4,000+ creatures including:
- All TBC dungeon and raid bosses
- Most dungeon trash mobs
- World bosses
- Outdoor elite creatures

### Auto-Learning System
As you play, the addon automatically:
- Monitors combat log for IMMUNE events
- Records which creatures are immune to which CC types
- Separates normal and heroic immunities
- Saves your discoveries between sessions
- Ignores temporary immunity effects (like Banish or Cyclone)

### Fallback Rules
For creatures not in the database, type-based immunities apply:
- **Mechanical**: Polymorph, Charm/MC
- **Undead**: Polymorph, Charm/MC
- **Elemental**: Polymorph
- **Demon**: (none by default)
- **World Bosses**: Polymorph, Fear, Charm/MC, Sleep, Banish

## Color Coding

Each CC type has its own color in the tooltip for easy recognition:
- Polymorph: Pink
- Fear: Purple
- Stun: Gold
- Mind Control: Hot Pink
- Bleed: Red
- Slow: Blue
- Root: Green
- Banish: Medium Purple
- Charm: Light Pink
- Sleep: Sky Blue

## Notes

- Database covers 4,000+ TBC creatures with known immunities
- Heroic dungeons automatically show additional heroic-specific immunities
- Auto-learning happens passively - just play normally
- Learned immunities persist between sessions
- Type-based fallback immunities for unknown creatures
- Tooltip shows "(Heroic)" tag when viewing heroic-specific immunities
- Temporary immunity effects (Banish, Cyclone) are filtered out

## Version History

**v1.1** - Database Update
- Added comprehensive database with 4,000+ creatures
- Implemented auto-learning from combat log
- Added heroic/normal difficulty awareness
- Fixed temporary immunity detection

**v1.0** - Initial release
- Basic tooltip integration
- Creature type detection
- Custom immunity commands
- Color-coded CC types

## Support

For issues or suggestions, use the addon's feedback system or modify the code to suit your needs.

## License

Free to use and modify for personal use.
