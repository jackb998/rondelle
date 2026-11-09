# Adding a file type or a conversion

Every new file type, and every new conversion between existing ones, changes all of the places below in the same
change. A conversion that works in the wheel but is missing from one of them counts as unfinished.

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
| Release notes | One line under *What's new*. |

Say in the report which rows changed and which did not apply.
