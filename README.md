# ConvexPi.jl

Write quant strategies in **Julia** and submit them to [ConvexPi](https://www.convexpi.ai) — scored
by the same hidden-holdout engine as Python and R.

```julia
using ConvexPi

m = synthetic_market("train")            # the exact market the grader uses
keys(m.features)

code = """
function on_day(day, features, prices, portfolio)
    s = copy(features["mom_1m"]); s[.!isfinite.(s)] .= 0.0
    g = sum(abs.(s)); return g > 0 ? s ./ g : s
end
"""

ENV["CONVEXPI_API_KEY"] = "cpk_..."      # from /settings/api-keys
submit("my-julia-momentum", code)
```

Market data comes from the published Python `convexpi-lab` via PyCall (deterministic, matches the
grader). Your `on_day` is run natively in Julia by the grader.
