# Marker-less destination (update Step 3)

If the destination has no end marker, do not guess where the project section starts. Show its content (the size, and the first lines when long) beside the plugin copy and ask which of these to do:
- **Replace**: write the plugin copy over it. The existing content is lost, which suits a redirect stub.
- **Prepend**: write the source's framework-owned region (line 1 through its end marker), a blank line, then the whole existing file as the project section. Nothing is lost, and future updates merge normally.
- **Pin**: leave the file as it is, set `frameworkFiles["<manifest key>"].pinned` to the reason the user gives, and run `node "<plugin lib>/pin-reconcile.mjs" --record "<manifest key>"` so the pin carries its hashes. Future updates skip it.

Apply the answer and list it under `Preserved` (prepend), `Updated files` (replace) or `Pinned` (pin). Any of the three clears the doctor's `marker-missing`. For a renamed entry the move is already done, so `framework-renamed` is gone too. On no answer, leave the file untouched and report it as `marker-missing`.
