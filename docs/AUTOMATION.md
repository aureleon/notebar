# Automation: URL scheme, AppleScript and Services

You can control NoteBar from other apps, from scripts, and from links.

## URL scheme

```text
notebar://new?text=…&folder=…&color=yellow&mode=code&show=1
notebar://show    notebar://hide    notebar://toggle
notebar://search?q=…
notebar://open?note=<id>
notebar://open?folder=<name>
```

Example, from Terminal:

```bash
open "notebar://new?text=Buy%20milk&folder=Personal&color=yellow"
```

## AppleScript

The AppleScript dictionary is in `Resources/NoteBar.sdef`. It includes these commands:
`new note`, `search notes`, `get note text`, `reveal note` and `list folders`.

## Services menu

NoteBar adds two items to the Services menu of other apps:

- **New Note from Selection**
- **New Note with Files**

## Test the integrations

`scripts/check-integrations.sh` tests the URL scheme and AppleScript offline. It does not start
NoteBar. See [Development](DEVELOPMENT.md).
