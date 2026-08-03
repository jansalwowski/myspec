# Core Heuristics — Nielsen 10 + Laws of UX

Always load. Universal cognitive/perceptual rules; apply to every surface regardless of audience or content.

## Nielsen's 10 Heuristics
1. **Visibility of system status** — every async op has a loading indicator visible within 200ms (Doherty threshold). Long ops show progress, not a spinner.
2. **Match real world** — labels use domain vocabulary, not system/code terms. "Check-in", not `check_in_date`.
3. **User control & freedom** — every path has Cancel / Back / Undo. No traps. Destructive ops are reversible or guarded.
4. **Consistency & standards** — same action looks the same everywhere. Primary CTA position is consistent across steps of a flow.
5. **Error prevention** — disable submit when invalid; greyed-out impossible options; confirmation for destructive. Confirmation modal copy includes "Cannot be undone" for high-risk actions; names the entity and blast radius.
6. **Recognition over recall** — visible options, not hidden behind menus. Recently-used / current-context surfaces up.
7. **Flexibility & efficiency** — bulk actions for power users; keyboard shortcuts hinted in tooltips.
8. **Aesthetic & minimalist design** — one focal point per surface. ≤ ~7 equal-weight elements per region.
9. **Error recovery** — error messages are actionable. "Email is required" beats "Invalid input."
10. **Help & documentation** — contextual hints over external docs. Help text in the same lane as future errors.

## Laws of UX (load-bearing subset)
- **Jakob's Law** — users prefer familiar patterns; matches Group B Sibling Comparison.
- **Hick's Law** — too many options slows decisions; group / collapse / progressive-disclose past ~7.
- **Fitts's Law** — primary CTA prominent; click targets ≥ 32×32 desktop / 44×44 mobile.
- **Miller's Law** — chunk lists at 7±2; longer lists need search / filter / sections.
- **Doherty Threshold** — < 400ms feels instant; > 400ms needs a loading state.
- **Peak-end rule** — the moment of highest emotion and the last interaction shape memory; polish the destructive-action confirmation and the success state.
