# narrative/

Everything text-and-story-shaped lives here. Three sub-folders by **shape of
the content**, not by character or scene — that lets a single character
appear in stories, ad-hoc dialogue, AND back-and-forth conversations without
duplicating files.

## Sub-folders

### `stories/`
**Long-form narrative chunks.** Backstory, lore, mission briefings, intro/
outro text, level summaries, anything that's mostly read top-to-bottom with
no branching. Markdown (`.md`) is the obvious format; plain text (`.txt`) or
JSON for richer metadata also fine.

Suggested filename pattern: `<topic>.md`, e.g. `intro.md`, `golden_human_origin.md`.

### `dialogue/`
**One-shot lines or barks.** Short, situational, character-specific text the
game can pull at a moment. Examples: a human's "oh no!" alternates ("watch
out!", "ahhh!"), the car's idle voice clip, a tutorial nudge.

A flat JSON or Godot Resource file keyed by an ID is ideal:
```json
{
  "human_flee": ["oh no!", "ahhh!", "watch out!"],
  "human_meet": ["hi", "hello", "hey"],
  "tutorial_first_boost": ["tap ⚡ to launch"]
}
```

### `conversations/`
**Back-and-forth, branching exchanges.** A NPC asks something, the player
chooses a reply, the NPC responds. Tree-shaped, possibly with conditions
("only if you've completed quest X").

JSON works for hand-authored trees; tools like
[Dialogic](https://github.com/dialogic-godot/dialogic) or
[DialogueManager](https://github.com/nathanhoad/godot_dialogue_manager) drop
their own resources here too.

Suggested filename pattern: `<scene-or-character>__<topic>.json`, e.g.
`market__greeting.json`, `golden_human__why_gold.json`.

## Picking the right folder

| You're writing... | Folder |
|---|---|
| A paragraph of lore that a player just reads | `stories/` |
| A single line a character shouts at runtime | `dialogue/` |
| A multi-step talk with player choices | `conversations/` |

If a piece of text fits more than one bucket, put it where the **structure**
lives, not where the *speaker* lives. A long monologue with no branching is
a story even if delivered by one character.

## Git

Empty folders aren't tracked, so each sub-folder has a `.gitkeep` placeholder
to preserve the layout in fresh clones. Delete the `.gitkeep` once the folder
has real content.
