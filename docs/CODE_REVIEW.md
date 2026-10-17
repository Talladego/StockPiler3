# StockPiler3 notes

The 0.3.397 review, the 0.3.220 review, and the StockPiler4 roadmap are history. They are not a list of open work.

```text
git show 1533711:docs/CODE_REVIEW.md
git show e82a3e5:docs/CODE_QUALITY_REVIEW.md
git show 1533711:docs/REFACTORING_RECOMMENDATIONS.md
git show 1533711:docs/IMPLEMENTATION_PLAN.md
git show 1533711:docs/FRAME_SLICING.md
```

Section 12 of the 0.3.397 review shipped in 0.3.409 through 0.3.422. The product contract is [STOCKPILER3_BUILD_PROMPT.md](STOCKPILER3_BUILD_PROMPT.md). The player-facing overview is the repository README.

## Left on purpose

- **Cache wipes stay.** `InvalidateFocusCaches` and `InvalidateCraftableStamps` are still called. A Craftable stamp can change without a knowledge or snapshot generation bump, so dropping the wipes would serve a stale demand. Demand, focus, and seed-line keys already include every generation plus the recipe-stats generation (0.3.410, 0.3.412).
- **Fill-blocked ticks stay slow.** While AutoGrow is fill-blocked, the Scheduler returns the idle interval. The slow tick was left so a later tick-rate change is not buried in a cleanup.
- **Trade-skill hydration.** Caps hydrate once a character row exists. No further change.
