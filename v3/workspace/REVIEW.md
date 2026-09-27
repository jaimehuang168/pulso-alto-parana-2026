# Workspace review 3.1.3

This release changes presentation and read composition, not database permissions or collection rules.

- Five main administrative work areas; dedicated interviewer and Viewer navigation.
- Complete frozen record snapshots are read through the existing audited export RPC. The numeric expected revision and request UUID occupy separate API arguments; a regression checks that contract.
- The configuration is reread after creating an audited snapshot, so subsequent edits do not reuse the operation revision from before export.
- Candidate percentages use the published questionnaire and independent city/point denominators. Point-level other-answer breakdown is not supplied by the current aggregate; the UI explains that limitation instead of inventing zeros.
- Pausing the result screen never pauses collection. Failed refreshes retain the actual last confirmed time.
- Authority labels and the protected owner's row are not rendered. The server still enforces the original account hierarchy.
- Public app/manual are Spanish only; bilingual manuals are generated privately outside this repository. Removing current files does not erase previously downloaded copies or Git history.
- Filters apply to the full snapshot, never only the displayed first page. CSV uses the same complete filter set.
- Original capture, receipt verification, encrypted local storage and SQL remain unchanged.
- No production records, Supabase credentials, paid resources or new activation forms are created by this release.
