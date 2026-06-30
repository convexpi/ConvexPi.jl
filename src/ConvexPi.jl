"""
ConvexPi — write quant strategies in Julia and submit them to ConvexPi, scored by the same
hidden-holdout engine as Python and R. Market data comes from the published Python `convexpi-lab`
via PyCall (deterministic, matches the grader); strategies run natively in Julia in the grader.
"""
module ConvexPi

using PyCall, HTTP, JSON

export synthetic_market, submit

"""
    synthetic_market(split="train"; seed=42) -> (prices, features)

Load the exact synthetic market the grader scores on. `prices` is a days×stocks matrix; `features`
is a `Dict` of days×stocks matrices (e.g. "mom_1m"). Fit on "train"; "test" is what you're scored on.
"""
function synthetic_market(split::AbstractString = "train"; seed::Integer = 42)
    lab = pyimport("convexpi.lab")
    m = lab.SyntheticMarket(seed = seed)
    feats = m.features(split)
    return (prices = m.prices(split), features = Dict(string(k) => v for (k, v) in feats))
end

"""
    submit(name, code; slug="demo-fall-2026", api_key=ENV["CONVEXPI_API_KEY"]) -> Dict

Submit a Julia strategy. `code` must define `on_day(day, features, prices, portfolio)` returning a
vector of target weights. Create a key at https://www.convexpi.ai/settings/api-keys
"""
function submit(name, code; slug = "demo-fall-2026",
                api_key = get(ENV, "CONVEXPI_API_KEY", ""),
                base_url = "https://www.convexpi.ai")
    isempty(api_key) && error("Set CONVEXPI_API_KEY (or pass api_key=). Create one at /settings/api-keys.")
    body = JSON.json(Dict("slug" => slug, "strategyName" => name, "code" => code, "language" => "julia"))
    r = HTTP.post("$base_url/api/submissions",
                  ["Authorization" => "Bearer $api_key", "Content-Type" => "application/json"],
                  body; status_exception = false)
    parsed = JSON.parse(String(r.body))
    r.status >= 300 && error(get(parsed, "error", "submission failed"))
    @info "Submitted '$name' — track it at $base_url/compete/$slug/leaderboard"
    return parsed
end

end # module
