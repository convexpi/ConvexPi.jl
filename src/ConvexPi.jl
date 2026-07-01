"""
ConvexPi — write quant strategies in Julia and submit them to ConvexPi, scored by the same
hidden-holdout engine as Python and R. Market data comes from the published Python `convexpi-lab`
via PyCall (deterministic, matches the grader); strategies run natively in Julia in the grader.
"""
module ConvexPi

using PyCall, HTTP, JSON

export synthetic_market, submit
export run_agent, arena_limit, arena_market_order, arena_cancel, ARENA_DEFAULT_SERVER

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

# ---------------------------------------------------------------------------
# Arena — live limit-order-book trading over WebSocket (Mission 2).
# Protocol mirrors the Python RemoteAgent: join -> welcome -> {tick -> orders}* / fills.
# Prices and cash are in integer cents (6151310 = $61513.10).
# ---------------------------------------------------------------------------

const ARENA_DEFAULT_SERVER = "wss://arena-production-e3f1.up.railway.app"

"Post a limit order. `side` is \"buy\"/\"sell\", `price` in cents."
arena_limit(side, price, qty) =
    Dict("order_type" => "limit", "side" => String(side), "price" => Int(round(price)), "qty" => Int(qty))
"Send a market order (takes the best available price immediately)."
arena_market_order(side, qty) =
    Dict("order_type" => "market", "side" => String(side), "qty" => Int(qty))
"Cancel a resting order by its id (from `state.my_open_orders`)."
arena_cancel(order_id) = Dict("order_type" => "cancel", "cancel_id" => Int(order_id))

function _arena_state(msg)
    bb, ba, lp = msg["best_bid"], msg["best_ask"], msg["last_price"]
    mid = (bb !== nothing && ba !== nothing) ? (bb + ba) / 2 : (lp === nothing ? nothing : float(lp))
    spread = (bb !== nothing && ba !== nothing) ? ba - bb : nothing
    pnl = mid === nothing ? nothing : (msg["cash"] + msg["position"] * mid) / 100
    (tick = msg["tick"], best_bid = bb, best_ask = ba, last_price = lp, mid = mid, spread = spread,
     depth = msg["depth"], recent_trades = msg["recent_trades"], position = msg["position"],
     cash = msg["cash"], pnl = pnl, my_open_orders = msg["my_open_orders"])
end

"""
    run_agent(on_tick; agent_id, server=ARENA_DEFAULT_SERVER, max_ticks=200, on_fill=nothing) -> Vector

Connect to the Arena and trade. Each tick you receive a market `state` (a NamedTuple with
`best_bid/best_ask/last_price/mid/spread/depth/recent_trades/position/cash/pnl/my_open_orders`, all
prices in cents) and `on_tick(state)` returns a vector of orders built with `arena_limit`,
`arena_market_order`, `arena_cancel` (empty vector = do nothing). Runs `max_ticks` ticks, returns a
telemetry vector of `(tick, pnl, position, mid, last_price)` (prices in dollars). Reconnect with the
same `agent_id` to keep your position and cash.
"""
function run_agent(on_tick; agent_id, server = ARENA_DEFAULT_SERVER, max_ticks = 200, on_fill = nothing)
    telem = NamedTuple[]
    HTTP.WebSockets.open(server) do ws
        HTTP.WebSockets.send(ws, JSON.json(Dict("type" => "join", "agent_id" => agent_id)))
        welcome = JSON.parse(String(HTTP.WebSockets.receive(ws)))
        @info "Connected to Arena" agent_id tick_interval = get(welcome, "tick_interval", nothing) response_deadline = get(welcome, "response_deadline", nothing)
        n = 0
        for raw in ws
            msg = JSON.parse(String(raw))
            typ = get(msg, "type", "")
            if typ == "tick"
                st = _arena_state(msg)
                orders = try
                    something(on_tick(st), Dict[])
                catch e
                    @warn "on_tick error" tick = st.tick exception = e
                    Dict[]
                end
                HTTP.WebSockets.send(ws, JSON.json(Dict("type" => "orders", "tick" => st.tick, "orders" => orders)))
                push!(telem, (tick = st.tick, pnl = st.pnl === nothing ? NaN : st.pnl,
                              position = st.position, mid = st.mid === nothing ? NaN : st.mid / 100,
                              last_price = st.last_price === nothing ? NaN : st.last_price / 100))
                n += 1
                n >= max_ticks && break
            elseif typ == "fill" && on_fill !== nothing
                on_fill(msg["tick"], msg["price"], msg["qty"], msg["side"])
            end
        end
    end
    telem
end

end # module
