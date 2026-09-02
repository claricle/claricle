# Convert fixtures

Hand-written, not sniffed. Each one differs from `rect_and_line.svg` — the
clean control — by **exactly one thing**, so its verdict says what that one
thing does. A fixture that also trips an *earlier* guard can never exercise the
guard it is named for; three fixtures failed that way during design and were
rebuilt.

**These fixtures demonstrate that the classifier DETECTS a feature. They do not
demonstrate the loss.** The losses are measurements taken with vectory 0.12.0
during design; vectory is not a dependency of this gem and nothing here runs a
conversion.

## The control

| Fixture | Verdict | Why it is shaped this way |
|---|---|---|
| `rect_and_line.svg` | `lossless` | rect + line, hex paint, root `width`/`height`. Hex rather than `fill="red"`: a named colour is an open set nobody has measured |

## What each fixture discriminates

| Fixture | Verdict | Wrong behaviour it catches |
|---|---|---|
| `gradient_linear`, `gradient_radial` | `lossy` | a gradient treated as surviving |
| `clip_path_element`, `clip_path_attribute` | `lossy` | a clip applied by element or by attribute going unseen |
| `embedded_raster` | `lossy` (eps), `unknown` (emf) | a one-list rule set calling the EMF case lossless, which nobody measured |
| `prefixed_gradient` | `lossy` | matching the qualified name, so `s:linearGradient` hides a loss |
| `text_rect_line` | `unknown` | an unmeasured element waved through. Carries a rect and a line so the empty-feature guard cannot answer first |
| `path_and_rect` | `unknown` | an unmeasured element waved through when proven shapes sit beside it. The `<path/>` is bare: a `d=` attribute would trip the attribute rule instead. It does NOT catch `IGNORED` growing — adding `path` there reddens the constant pin, not this fixture |
| `defs_container` | `lossless` | `defs` dropped from `IGNORED` |
| `empty_svg`, `empty_defs` | `unknown` | a vacuous `lossless` from a document with no features |
| `defs_root_svg_ns` | `unknown` | the root local-name check removed. Carries the CORRECT namespace, so only that check can catch it |
| `foreign_namespace_rect`, `foreign_prefixed_defs` | `unknown` | a foreign-namespace element passing as a proven-kept shape; the second also catches the prefix test running after the `IGNORED` skip |
| `foreign_default_ns_rect`, `no_namespace_rect` | `unknown` | a root that is not positively in the SVG namespace |
| `nested_foreign_ns_rect` | `unknown` | a default namespace rebound below the root |
| `redundant_svg_ns_rect` | `lossless` | the namespace rule over-firing on a harmless redeclaration. Uses a `rect`, a RECOGNISED element, so the verdict is about the namespace |
| `opacity_rect`, `root_style_rect` | `unknown` | an unproven attribute name; the second also catches attributes going unread on ignored elements |
| `foreign_prefixed_attr` | `unknown` | a local-name-first reading that lets `foo:fill` through |
| `entity_gradient`, `attlist_default_opacity` | `unknown` | markup an internal DTD subset can hide |
| `public_doctype_rect`, `system_dtd_rect` | `unknown` | an external subset, which is never fetched |
| `public_doctype_attlist` | `unknown` | nothing on its own — it trips the external-subset and internal-declaration rules together, and each is caught alone by `public_doctype_rect` and `attlist_default_opacity`. Kept as a corpus row confirming the two compose, not as a discriminator |
| `bare_doctype_rect` | `lossless` | the DTD rule widened to "any doctype" |
| `external_entity_ref` | `unknown` | an event type the scanner does not recognise |
| `stylesheet_pi_rect`, `other_pi_rect` | `unknown` | a PI going unseen; the second catches a rule written for one PI name |
| `xmldecl_rect` | `lossless` | the PI rule widened onto the XML declaration |
| `xml_space_rect` / `xml_space_text` | `lossless` / `unknown` | the `xml:` allowance becoming a general escape hatch |
| `no_paint_rect` / `paint_none_rect` | `lossless` / `unknown` | an ABSENT attribute read as harmless while `none` is refused |
| `paint_named_rect`, `paint_transparent_rect`, `paint_url_rect`, `paint_stroke_url_rect` | `unknown` | paint proven by name rather than by value. `transparent` also catches a colour-SHAPED regex |
| `paint_rgb_rect` | `lossless` | the paint allowlist narrowed to hex only |
| `geom_percent_rect`, `geom_em_rect`, `geom_mm_rect`, `geom_calc_rect` | `unknown` | geometry proven by name rather than by value |
| `geom_height_percent`, `geom_y1_percent` | `unknown` | a rule that guards `width` and leaves the rest name-only |
| `geom_px_rect`, `geom_viewbox_rect` | `lossless` | the geometry rule collapsing into "refuse every unit" |
| `nested_svg_rect` | `unknown` | a nested `<svg>` viewport ignored by name rather than by position |
| `truncated_gradient` | `unknown` | an unclosed element stack at EOF. `large_trailing_gradient` cut by 30 bytes: without the depth check this classifies `lossless`, so losing bytes made the verdict MORE confident |
| `second_root`, `epilog_content` | `unknown` | document phase unmodelled. REXML raises on neither |
| `no_root_dimensions` | `unknown` | absent root dimensions read as harmless while `50%` is refused |
| `large_trailing_gradient` | `lossy` | a scan bounded to a prefix. Over 8192 bytes, feature at the very end |
| `utf16_gradient` | `unknown` | currently caught by the root guard, not a guard of its own — it is here so relaxing that guard reddens something |
| `bad_encoding` | `unknown` | an unusable encoding name crashing instead of returning a verdict |
| `malformed` | `unknown` | a parse failure escaping as an exception |
| `comment_rect`, `cdata_rect` | `lossless` | comments and CDATA treated as marks |
| `style_element_rect` | `unknown` | a `<style>` element treated as structural |

## A note on what a README entry means here

An entry in the table above is a CLAIM that a spec asserts that property. Three
fixtures once had an entry and no example — and one of them, `style_element_rect`,
would have let a `<style>` document reach `lossless` with the whole suite green.
A fixture with no spec is invisible; a fixture with no spec AND a table entry is
worse, because the next reader checks the table and stops looking. If you add a
fixture here, add the example in the same change.
