# Third-party components

The production build downloads @supabase/supabase-js 2.116.0 (MIT) from jsDelivr and serves that fixed version from web/supabase-vendor.js. This SDK is not included in the source archive because the current working environment could not download it. The deployment workflow fails rather than publish if the download fails. Review its package and license at https://github.com/supabase/supabase-js/tree/v2.116.0 . Keep copyright/license comments in the distributed bundle. The standalone practice HTML uses no external SDK and makes no database requests.

Fonts: system Segoe UI / Arial; no font files are distributed.
Icons: application SVG paths and geometric mark, no candidate or party logos.
