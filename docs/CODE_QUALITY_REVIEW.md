# StockPiler3 Code Quality Review (superseded)

This review was written against 0.3.220 and has been replaced by [`CODE_REVIEW.md`](CODE_REVIEW.md), which covers 0.3.397.

Section 10 of the new review re-checks each finding from this one (Fixed / Still open / Partially fixed / Incorrect). Two of the old claims turned out to be wrong:

- **4.1, the `RP.ExpireStuck` `pairs` mutation:** Lua 5.1 permits assigning or clearing existing keys during traversal, and every key in that table is a number.
- **3.2, `BuildBalancedSpecDemand` cloned in RecipeSpec:** it is a 4-line pass-through to Planner, not a clone.

The full previous text is available in git history (`git show e82a3e5:docs/CODE_QUALITY_REVIEW.md`).
