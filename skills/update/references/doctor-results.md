# Doctor results (update Step 3.7)

Read the doctor's result as a checklist of this run:

- `framework-missing` / `framework-drift` → a manifest entry did not get written. Re-apply that entry, do not stamp over it. For a `marker-merge` file this covers the header above the start marker too: the framework-owned region is line 1 through the end marker.
- `marker-missing` → a `marker-merge` file has no `<!-- myspec:framework-start -->` / `<!-- myspec:framework-end -->` markers and the replace / prepend / pin choice in Step 3 was not applied. Either the question was skipped (ask it now) or the user gave no answer (report it; the file stays untouched and does not block the stamp).
- `framework-condition-off` → a conditional entry's file is on disk while its `when` does not hold; Step 2's conditional delete was skipped. Delete it now, or report it if the user wants it pinned.
- `framework-renamed` → an old filename is still on disk. Either the Step 2 move did not happen (do it now) or both names exist and the user declined the merge (report it).
- `hook-wired-locally` / `hook-copy-retired` → the `3.0.0-plugin-hooks` migration left a framework entry in `settings.json` or a copy under `.claude/hooks/` or `.claude/lib/`; read [migrations/3.0.0-plugin-hooks.md](migrations/3.0.0-plugin-hooks.md) and unwire or move it as that migration does, do not stamp over it.
- Anything in the `schema` or `features` group → fix before finishing; an unparseable `.myspec.json` or `verification.json` silently disables the surfaces that read it, and an entry the features parser cannot read is invisible to every status audit. Exception: `note-over-cap` / `note-volatile` / `manifest-unknown-key` are project content, not install state — report them and leave the notes alone.
