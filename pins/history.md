# Pin history

Every change to `pins/cart.txt`, appended by `zig build repin -- "<why>"`: the date, each
SHA-1 before and after, and why. The gate checks the last line matches `pins/cart.txt`.

- 2026-10-05 | retail none -> 3452e39133b42a96f6dcdaf09dc51aff6f4d097e | debug none -> e215c9a561cc5a2450010f35c0614ccf34d78948 | crawl none -> d4398e1b546fdda68e3146aab24910c09143d3ef | first pin: the carts of zig build rom at cc062f0 with release Step 0, on the committed crawler's crawl
- 2026-10-24 | retail 3452e39133b42a96f6dcdaf09dc51aff6f4d097e -> 92aba34751f0ade30572dee476e4ccc8c33d0d16 | debug e215c9a561cc5a2450010f35c0614ccf34d78948 -> c4f506239a7f8f428a9fc520495c5e5919b80706 | crawl d4398e1b546fdda68e3146aab24910c09143d3ef -> d4398e1b546fdda68e3146aab24910c09143d3ef | HUD moved to BG2 palette 1, colours unchanged
