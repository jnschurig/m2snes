# Pin history

Every change to `pins/cart.txt`, appended by `zig build repin -- "<why>"`: the date, each
SHA-1 before and after, and why. The gate checks the last line matches `pins/cart.txt`.

- 2026-10-05 | retail none -> 3452e39133b42a96f6dcdaf09dc51aff6f4d097e | debug none -> e215c9a561cc5a2450010f35c0614ccf34d78948 | crawl none -> d4398e1b546fdda68e3146aab24910c09143d3ef | first pin: the carts of zig build rom at cc062f0 with release Step 0, on the committed crawler's crawl
- 2026-10-24 | retail 3452e39133b42a96f6dcdaf09dc51aff6f4d097e -> 92aba34751f0ade30572dee476e4ccc8c33d0d16 | debug e215c9a561cc5a2450010f35c0614ccf34d78948 -> c4f506239a7f8f428a9fc520495c5e5919b80706 | crawl d4398e1b546fdda68e3146aab24910c09143d3ef -> d4398e1b546fdda68e3146aab24910c09143d3ef | HUD moved to BG2 palette 1, colours unchanged
- 2026-10-24 | retail 92aba34751f0ade30572dee476e4ccc8c33d0d16 -> 52a8a138497b4826b14855e869d1960b9255e79e | debug c4f506239a7f8f428a9fc520495c5e5919b80706 -> 3dfdf4f68c8f636475a7f8170505f4a708b6584c | crawl d4398e1b546fdda68e3146aab24910c09143d3ef -> d4398e1b546fdda68e3146aab24910c09143d3ef | default colour scheme gbc: the cart carries a scheme table, boot record v18 drops its palettes
- 2026-10-24 | retail 52a8a138497b4826b14855e869d1960b9255e79e -> 9d1e398f05ee8889b03d21f65148406f1c0459f3 | debug 3dfdf4f68c8f636475a7f8170505f4a708b6584c -> 9fe3a6893c7f44615a42cba7ac73913bc2c62ccf | crawl d4398e1b546fdda68e3146aab24910c09143d3ef -> d4398e1b546fdda68e3146aab24910c09143d3ef | each save slot keeps its colour scheme in SRAM; L on the title steps it
- 2026-10-24 | retail 9d1e398f05ee8889b03d21f65148406f1c0459f3 -> 15b38c81a8721e4a9d46ffa2cd1dc6dc0ce49fa7 | debug 9fe3a6893c7f44615a42cba7ac73913bc2c62ccf -> 215a19f5a0d752079562f94ffbecfd0c61f217e6 | crawl d4398e1b546fdda68e3146aab24910c09143d3ef -> d4398e1b546fdda68e3146aab24910c09143d3ef | L badge on the title, colour schemes Step 7
