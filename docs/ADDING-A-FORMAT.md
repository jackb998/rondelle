# Adding a file type or a conversion

Every new file type, and every new conversion between existing ones, changes all of the places below in the same
change. A conversion that works in the wheel but is missing from one of them counts as unfinished. A format that is
read is finished only when the security row (bomb, file cut in half, extreme varints, «Annulla») passes.

| Where | What to do |
|---|---|
| `Support.swift` | Extension in `FileKind` (or a new kind), size limit in `DocumentOps.sizeLimit` if the file is mostly pictures or packed XML. |
| `Actions.swift` | Entries on the Convert and Tools wheels for the kind, in both directions where possible (read and write). |
| `FileHints.swift` | The one-line description shown on the wheel for each new target. `--test-wheel-hints` fails if one is missing. |
| `FormatsView.swift` | The extension in the right table of Settings → Formats (the grid itself is built from the wheels). |
| `FormatSettings.swift`, `SettingsView.swift` | Settings → Conversions: a group and its texts if the format has options, or the text of the group it shares (for example images from PDF and PPTX). |
| `Resources/{en,fr}.lproj` | Every new Italian string, translated. |
| `README.md` | The row of the formats table, the paragraph on limits and what is left out, the source file table. |
| Public site (`site/`, public repository only) | The tab and its chips (`TABS`, `KIND`, `TOOLS`, `SAMPLE`, `tab_*` and `t_*` in English, Italian and French), the chips of the kinds it converts to, and the `site.js?v=` number in the four pages. |
| `Tests/functional/run.sh` | A conversion in each direction, and the read-back of what was written. |
| `Tests/security/run.sh` | For a format that is read: a decompression bomb, a file cut in half, length and count fields at their extremes (2^31, 2^32, 2^63, 2^64 − 1), and «Annulla» while reading. Each one is refused in under 2 s with under 500 MB and no file written, or stopped in under 1 s; every cap has a file exactly at it (accepted) and one past it (refused). Section U is the model. |
| Release notes | One line under *What's new*. |

Say in the report which rows changed and which did not apply.

A format that Rondelle writes from an installed app's template (Pages, Keynote, Numbers) is also read, and its wheel entry
is offered only when the app is installed. The message layouts of those files can be read from the apps' own frameworks
(serialized `.proto` descriptors inside their binaries); say in the report if a written file could not be opened in the app.
