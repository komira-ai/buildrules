"""unmeasured: a library with a source kcov records no line of. `fast.mojo` is all `@always_inline("nodebug")`; `:coverage` accepts it because
`coverage_unmeasured.txt` lists it with its reason, and leaves it out of the totals."""

from .fast import bump, halve
from .ops import add, clamp
