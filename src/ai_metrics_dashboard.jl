# ═══════════════════════════════════════════════════════════════════════
# AiMetricsDashboard — QCI AI Metrics TUI (Grok-first, local MVP)
#
# Elm-style: Model + update! + view. Sessions list (leftmost) + metrics BarChart
# (vertically stacked on the right). Real data layer support. Full TestBackend coverage.
# ═══════════════════════════════════════════════════════════════════════

using Tachikoma
using JSON
@tachikoma_app

const QCI_CYAN = ColorRGB(UInt8(0), UInt8(188), UInt8(212))
const QCI_NAVY = ColorRGB(UInt8(30), UInt8(32), UInt8(75))

# ═══════════════════════════════════════════════════════════════════════
# Phase 1: Immutable core data types + pure loader for ~/.ai-metrics/data.json
# Verbatim port of TS types from ai-metrics/src/types.ts (see plan/scout).
# Pure function only; safe fallbacks; no side effects. Used by later phases.
# JSON dep added for parse. All parsing defensive with get( , default).
# Existing dummy model/load_data! kept 100% unchanged per Phase 1 rules.
# ═══════════════════════════════════════════════════════════════════════

struct TokenBreakdown
    promptTokens::Int
    completionTokens::Int
    reasoningTokens::Int
end

struct GrokSessionUsage
    sid::String
    firstTs::String
    lastTs::String
    turnCount::Int
    total::TokenBreakdown
    models::Vector{String}
    cwds::Vector{String}
    totalTokens::Int
end

struct Attribution
    sid::String
    task::String
    pr::Union{String, Nothing}
    ticket::Union{String, Nothing}
    feature::Union{String, Nothing}
    hehsManual::Union{Float64, Nothing}
    hehsActual::Union{Float64, Nothing}
    outcome::Union{String, Nothing}
    notes::Union{String, Nothing}
    taggedAt::String
end

struct MetricsConfig
    burdenedHourlyRate::Float64
    modelPricing::Dict{String, NamedTuple{(:promptPerM, :completionPerM), Tuple{Float64, Float64}}}
end

struct StoredData
    sessions::Dict{String, GrokSessionUsage}
    attributions::Dict{String, Attribution}
    lastIngested::Union{String, Nothing}
    config::MetricsConfig
end

const DEFAULT_CONFIG = MetricsConfig(
    175.0,
    Dict{String, NamedTuple{(:promptPerM, :completionPerM), Tuple{Float64, Float64}}}(
        "grok-build" => (promptPerM = 3.0, completionPerM = 15.0),
        "grok-composer-2.5-fast" => (promptPerM = 0.5, completionPerM = 2.5),
        "mercury-2" => (promptPerM = 1.0, completionPerM = 4.0),
        "default" => (promptPerM = 2.0, completionPerM = 8.0),
    )
)

# Empty default for load fallbacks (note: reconstruct to avoid sharing mutables)
function _default_stored_data()::StoredData
    StoredData(
        Dict{String, GrokSessionUsage}(),
        Dict{String, Attribution}(),
        nothing,
        DEFAULT_CONFIG
    )
end

"""
    load_stored_data(path::AbstractString = expanduser("~/.ai-metrics/data.json"))::StoredData

Pure function (no mutation, no globals). Safe read for the local data store.
- If path missing or any read/parse error: return default (empty sessions/attrs, lastIngested=nothing, DEFAULT_CONFIG)
- Uses expanduser, isfile, try, read, JSON.parse + get(..., default) for robustness.
Mirrors TS loadData in ai-metrics/src/store.ts exactly in semantics.
"""
function load_stored_data(path::AbstractString = expanduser("~/.ai-metrics/data.json"))::StoredData
    if !isfile(path)
        return _default_stored_data()
    end

    try
        raw = read(path, String)
        parsed = JSON.parse(raw)
        # parsed is Dict{String,Any} or similar; all access via get + defaults

        # sessions
        sessions_raw = get(parsed, "sessions", Dict{String,Any}())
        sessions = Dict{String, GrokSessionUsage}()
        if isa(sessions_raw, AbstractDict)
            for (k, v) in sessions_raw
                if isa(v, AbstractDict)
                    total_raw = get(v, "total", Dict{String,Any}())
                    tb = TokenBreakdown(
                        Int(get(total_raw, "promptTokens", 0)),
                        Int(get(total_raw, "completionTokens", 0)),
                        Int(get(total_raw, "reasoningTokens", 0))
                    )
                    models_raw = get(v, "models", String[])
                    cwds_raw = get(v, "cwds", String[])
                    gs = GrokSessionUsage(
                        string(get(v, "sid", k)),
                        string(get(v, "firstTs", "")),
                        string(get(v, "lastTs", "")),
                        Int(get(v, "turnCount", 0)),
                        tb,
                        [string(x) for x in (isa(models_raw, AbstractArray) ? models_raw : String[])],
                        [string(x) for x in (isa(cwds_raw, AbstractArray) ? cwds_raw : String[])],
                        Int(get(v, "totalTokens", 0))
                    )
                    sessions[string(k)] = gs
                end
            end
        end

        # attributions
        attrs_raw = get(parsed, "attributions", Dict{String,Any}())
        attributions = Dict{String, Attribution}()
        if isa(attrs_raw, AbstractDict)
            for (k, v) in attrs_raw
                if isa(v, AbstractDict)
                    a = Attribution(
                        string(get(v, "sid", k)),
                        string(get(v, "task", "")),
                        get(v, "pr", nothing) isa AbstractString ? get(v, "pr", nothing) : nothing,
                        get(v, "ticket", nothing) isa AbstractString ? get(v, "ticket", nothing) : nothing,
                        get(v, "feature", nothing) isa AbstractString ? get(v, "feature", nothing) : nothing,
                        (x = get(v, "hehsManual", nothing); x === nothing ? nothing : Float64(x)),
                        (x = get(v, "hehsActual", nothing); x === nothing ? nothing : Float64(x)),
                        get(v, "outcome", nothing) isa AbstractString ? get(v, "outcome", nothing) : nothing,
                        get(v, "notes", nothing) isa AbstractString ? get(v, "notes", nothing) : nothing,
                        string(get(v, "taggedAt", ""))
                    )
                    attributions[string(k)] = a
                end
            end
        end

        # lastIngested
        li = get(parsed, "lastIngested", nothing)
        last_ingested = (li === nothing || li isa AbstractString) ? (li === nothing ? nothing : string(li)) : nothing

        # config (merge safe defaults)
        cfg_raw = get(parsed, "config", Dict{String,Any}())
        if isa(cfg_raw, AbstractDict) && !isempty(cfg_raw)
            bhr = Float64(get(cfg_raw, "burdenedHourlyRate", DEFAULT_CONFIG.burdenedHourlyRate))
            mp_raw = get(cfg_raw, "modelPricing", Dict{String,Any}())
            pricing = Dict{String, NamedTuple{(:promptPerM, :completionPerM), Tuple{Float64, Float64}}}()
            if isa(mp_raw, AbstractDict)
                for (mk, mv) in mp_raw
                    if isa(mv, AbstractDict)
                        pp = Float64(get(mv, "promptPerM", 2.0))
                        cp = Float64(get(mv, "completionPerM", 8.0))
                        pricing[string(mk)] = (promptPerM = pp, completionPerM = cp)
                    end
                end
            end
            if isempty(pricing)
                pricing = DEFAULT_CONFIG.modelPricing
            end
            config = MetricsConfig(bhr, pricing)
        else
            config = DEFAULT_CONFIG
        end

        return StoredData(sessions, attributions, last_ingested, config)
    catch err
        # any IO, parse, or conversion error -> safe default (per plan)
        return _default_stored_data()
    end
end

# ═══════════════════════════════════════════════════════════════════════
# Phase 2: Pure parser for ~/.grok/logs/unified.jsonl
# Line-by-line, only inference_done for tokens; model/cwd hints from
# multiple ctx keys + build_request_done + model-* msgs (verbatim TS parser.ts logic).
# Returns Dict{sid => GrokSessionUsage}. No side effects, no wiring to model/load_data!.
# Robust: per-line try JSON.parse (skip bad), !isfile->empty, Number(ctx||0), try/catch outer->empty.
# Keep ALL prior code untouched.
# ═══════════════════════════════════════════════════════════════════════

"""
    parse_grok_unified_jsonl(path::AbstractString = expanduser("~/.grok/logs/unified.jsonl"))::Dict{String, GrokSessionUsage}

Pure function. Mirrors ai-metrics/src/parser.ts:parseGrokLog .
- !isfile -> empty Dict
- each line: try JSON.parse skip bad/missing sid
- on "shell.turn.inference_done": accumulate prompt/completion/reasoning (Number||0 -> Int), ts min/max, turns++, cwd/git_root
- harvest models from: model resolved/changed/subagent msgs, any ctx.current_model_id|effective|model|child , build_request_done (incl global_model_id)
- cwd harvested from any ctx.cwd if sid rec seen
- models default ["unknown"] if none; unique preserved via Set
- Uses existing GrokSessionUsage + TokenBreakdown types.
"""
function parse_grok_unified_jsonl(path::AbstractString = expanduser("~/.grok/logs/unified.jsonl"))::Dict{String, GrokSessionUsage}
    if !isfile(path)
        return Dict{String, GrokSessionUsage}()
    end

    by_sid = Dict{String, Dict{String,Any}}()
    model_hints = Dict{String, String}()

    _to_int(v) = begin
        v === nothing && return 0
        if v isa Number
            return Int(floor(Float64(v)))
        end
        try
            return Int(floor(parse(Float64, string(v))))
        catch
            return 0
        end
    end

    try
        for line in eachline(path)
            line_stripped = strip(line)
            isempty(line_stripped) && continue
            local evt
            try
                evt = JSON.parse(line_stripped)
            catch
                continue
            end
            if !isa(evt, AbstractDict)
                continue
            end
            sid = get(evt, "sid", nothing)
            if sid === nothing || !(sid isa AbstractString) || isempty(strip(sid))
                continue
            end
            sid = string(sid)
            ctx_raw = get(evt, "ctx", Dict{String,Any}())
            ctx = isa(ctx_raw, AbstractDict) ? ctx_raw : Dict{String,Any}()
            msg = string(get(evt, "msg", ""))
            ts = string(get(evt, "ts", ""))

            # inference_done: tokens + base rec + some ctx
            if msg == "shell.turn.inference_done"
                rec = get!(by_sid, sid) do
                    Dict{String,Any}(
                        "firstTs" => ts,
                        "lastTs" => ts,
                        "turns" => 0,
                        "prompt" => 0,
                        "completion" => 0,
                        "reasoning" => 0,
                        "models" => Set{String}(),
                        "cwds" => Set{String}(),
                    )
                end
                rec["turns"] += 1
                rec["prompt"] += _to_int(get(ctx, "prompt_tokens", 0))
                rec["completion"] += _to_int(get(ctx, "completion_tokens", 0))
                rec["reasoning"] += _to_int(get(ctx, "reasoning_tokens", 0))
                if !isempty(ts) && (ts < rec["firstTs"] || isempty(rec["firstTs"]))
                    rec["firstTs"] = ts
                end
                if !isempty(ts) && (ts > rec["lastTs"])
                    rec["lastTs"] = ts
                end
                if haskey(ctx, "cwd") && ctx["cwd"] !== nothing
                    push!(rec["cwds"], string(ctx["cwd"]))
                end
                if haskey(ctx, "git_root") && ctx["git_root"] !== nothing
                    push!(rec["cwds"], string(ctx["git_root"]))
                end
            end

            # model resolution msgs (per TS)
            if occursin("model resolved", msg) || msg == "model changed" || occursin("subagent model", msg)
                model = get(ctx, "current_model_id", nothing)
                if model === nothing || !(model isa AbstractString) || isempty(model)
                    model = get(ctx, "effective_model", nothing)
                end
                if model === nothing || !(model isa AbstractString) || isempty(model)
                    model = get(ctx, "model", nothing)
                end
                if model === nothing || !(model isa AbstractString) || isempty(model)
                    model = get(ctx, "child_model", nothing)
                end
                if model !== nothing && isa(model, AbstractString) && !isempty(model)
                    model_hints[sid] = string(model)
                    if haskey(by_sid, sid)
                        push!(by_sid[sid]["models"], string(model))
                    end
                end
            end

            # harvest model keys from ANY ctx (incl on inference/build)
            any_model = get(ctx, "current_model_id", nothing)
            if any_model === nothing || !(any_model isa AbstractString) || isempty(any_model)
                any_model = get(ctx, "effective_model", nothing)
            end
            if any_model === nothing || !(any_model isa AbstractString) || isempty(any_model)
                any_model = get(ctx, "model", nothing)
            end
            if any_model === nothing || !(any_model isa AbstractString) || isempty(any_model)
                any_model = get(ctx, "child_model", nothing)
            end
            if any_model !== nothing && isa(any_model, AbstractString) && !isempty(any_model)
                mstr = string(any_model)
                if haskey(by_sid, sid)
                    push!(by_sid[sid]["models"], mstr)
                end
            end

            # build_request_done (often carries model hint, may precede inference)
            if msg == "shell.turn.build_request_done"
                m = get(ctx, "current_model_id", nothing)
                if m === nothing || !(m isa AbstractString) || isempty(m)
                    m = get(ctx, "effective_model", nothing)
                end
                if m === nothing || !(m isa AbstractString) || isempty(m)
                    m = get(ctx, "global_model_id", nothing)
                end
                if m !== nothing && isa(m, AbstractString) && !isempty(m)
                    if haskey(by_sid, sid)
                        push!(by_sid[sid]["models"], string(m))
                    end
                end
            end

            # cwd from any event for the sid (if rec present)
            if haskey(ctx, "cwd") && ctx["cwd"] !== nothing
                cstr = string(ctx["cwd"])
                if haskey(by_sid, sid)
                    push!(by_sid[sid]["cwds"], cstr)
                end
            end
        end
    catch err
        # any top-level read failure -> empty (safe, like load_stored_data fallback)
        return Dict{String, GrokSessionUsage}()
    end

    # assemble final GrokSessionUsage using types (dedup models already by Set)
    result = Dict{String, GrokSessionUsage}()
    for (sid, raw) in by_sid
        tb = TokenBreakdown(
            get(raw, "prompt", 0),
            get(raw, "completion", 0),
            get(raw, "reasoning", 0)
        )
        tot = tb.promptTokens + tb.completionTokens + tb.reasoningTokens
        models_arr = collect(raw["models"])
        if haskey(model_hints, sid)
            h = model_hints[sid]
            if !(h in models_arr)
                push!(models_arr, h)
            end
        end
        if isempty(models_arr)
            models_arr = ["unknown"]
        end
        cwds_arr = collect(raw["cwds"])
        gs = GrokSessionUsage(
            sid,
            get(raw, "firstTs", ""),
            get(raw, "lastTs", ""),
            get(raw, "turns", 0),
            tb,
            models_arr,
            cwds_arr,
            tot
        )
        result[sid] = gs
    end
    return result
end

# ═══════════════════════════════════════════════════════════════════════
# Phase 3: Pure compute helpers — compute_efficiency, simple quality filter,
# compute_dashboard_aggregates (or equiv). 
# Follow TS calculator.ts formulas EXACTLY (rounding, grok-build price bias for cost).
# Quality gate: only 'merged-clean'/'merged-rework' contribute to dashboard totals.
# Use existing types (GrokSessionUsage, Attribution, MetricsConfig, StoredData).
# Returns derived values; no mutation of model (populate derived for model later).
# Pure, side-effect free, independently testable. Merge for data+parsed.
# ═══════════════════════════════════════════════════════════════════════

"""
    filter_quality_for_credit(attr::Union{Attribution, Nothing})::Bool

Simple quality filter. Credits only outcomes 'merged-clean' and 'merged-rework'
(per TS filterQualityForCredit and report rules). Unattributed or other -> false.
"""
function filter_quality_for_credit(attr::Union{Attribution, Nothing})::Bool
    if attr === nothing || attr.outcome === nothing
        return false
    end
    good = ["merged-clean", "merged-rework"]
    return attr.outcome in good
end

"""
    compute_efficiency(
        usage::GrokSessionUsage,
        attr::Union{Attribution, Nothing},
        config::MetricsConfig
    )::NamedTuple{(:hehsSaved, :aiCostUsd, :valueCreated, :efficiency, :tokensPerHehs), Tuple{Float64, Float64, Float64, Float64, Int}}

Pure port of calculateEfficiency (TS calculator.ts).
- hehsSaved = max(0, hehsManual - hehsActual)   [always; gate is separate]
- aiCostUsd: using grok-build pricing (or default fallback) on prompt+completion /1M ; rounded to 4 decimals
- valueCreated = hehsSaved * burdenedHourlyRate - aiCostUsd ; round(*100)/100
- efficiency = (hehsSaved * rate) / (totalTokens/1000) or 0 ; round(*100)/100
- tokensPerHehs = total / hehsSaved or 0 ; Int round
No side effects. Attributed or not, formula applies (unattrib yields hehs=0).
"""
function compute_efficiency(
    usage::GrokSessionUsage,
    attr::Union{Attribution, Nothing},
    config::MetricsConfig
)::NamedTuple{(:hehsSaved, :aiCostUsd, :valueCreated, :efficiency, :tokensPerHehs), Tuple{Float64, Float64, Float64, Float64, Int}}
    hehsManual = (attr !== nothing && attr.hehsManual !== nothing) ? attr.hehsManual : 0.0
    hehsActual = (attr !== nothing && attr.hehsActual !== nothing) ? attr.hehsActual : 0.0
    hehsSaved = max(0.0, hehsManual - hehsActual)

    pricing = config.modelPricing
    fallback = get(pricing, "default", (promptPerM = 2.0, completionPerM = 8.0))
    gb = get(pricing, "grok-build", fallback)

    p = usage.total.promptTokens
    c = usage.total.completionTokens
    aiCostUsd = (p / 1_000_000) * gb.promptPerM + (c / 1_000_000) * gb.completionPerM

    valueCreated = (hehsSaved * config.burdenedHourlyRate) - aiCostUsd
    tokensK = usage.totalTokens / 1000.0
    efficiency = tokensK > 0 ? (hehsSaved * config.burdenedHourlyRate) / tokensK : 0.0
    tokensPerHehs = hehsSaved > 0 ? usage.totalTokens / hehsSaved : 0.0

    return (
        hehsSaved = hehsSaved,
        aiCostUsd = round(aiCostUsd * 10000) / 10000,
        valueCreated = round(valueCreated * 100) / 100,
        efficiency = round(efficiency * 100) / 100,
        tokensPerHehs = round(Int, tokensPerHehs),
    )
end

"""
    compute_dashboard_aggregates(
        data::StoredData,
        parsed_sessions::Dict{String, GrokSessionUsage} = Dict{String, GrokSessionUsage}()
    )::@NamedTuple{hehs_saved::Float64, efficiency::Float64, value_created::Float64, total_tokens::Int, session_count::Int, sessions::Vector{String}, hehs_trend::Vector{Float64}}

Pure aggregator + derivator.
- Simple merge/upsert: data.sessions preferred; add parsed for sids not in data.
- total_tokens, session_count from merged usages (always).
- HEHS/value totals: only sum eff for sessions where filter_quality_for_credit(attr)
- efficiency derived as (credited_hehs * rate) / tokensK  (overall)
- sessions: formatted list e.g. "sid-abc123 42k hehs=3.5"  (uses computed hehsSaved per eff, for display)
- hehs_trend: vector of hehsSaved values (capped ~6) — previously for quantum viz (data kept for compatibility)
- If no sessions: zeros + ["— no sessions —"] + [0.0]
Uses data.config and data.attributions. Pure.
"""
function compute_dashboard_aggregates(
    data::StoredData,
    parsed_sessions::Dict{String, GrokSessionUsage} = Dict{String, GrokSessionUsage}()
)::@NamedTuple{hehs_saved::Float64, efficiency::Float64, value_created::Float64, total_tokens::Int, session_count::Int, sessions::Vector{String}, hehs_trend::Vector{Float64}}
    # merge usages: data first (upsert), then add only new from parsed
    merged = Dict{String, GrokSessionUsage}()
    for (sid, u) in data.sessions
        merged[sid] = u
    end
    for (sid, u) in parsed_sessions
        if !haskey(merged, sid)
            merged[sid] = u
        end
    end

    total_tokens = 0
    credited_hehs = 0.0
    credited_value = 0.0
    session_list = String[]
    trend = Float64[]

    for (sid, usage) in merged
        total_tokens += usage.totalTokens
        attr = get(data.attributions, sid, nothing)
        eff = compute_efficiency(usage, attr, data.config)
        if filter_quality_for_credit(attr)
            credited_hehs += eff.hehsSaved
            credited_value += eff.valueCreated
        end
        k = usage.totalTokens ÷ 1000
        hehs_str = string(round(eff.hehsSaved; digits=1))
        # short-ish sid for list like dummy
        short_sid = length(sid) > 12 ? sid[1:8] * "…" : sid
        push!(session_list, "$(short_sid) $(k)k hehs=$(hehs_str)")
        push!(trend, eff.hehsSaved)
    end

    if isempty(merged)
        session_list = ["— no sessions —"]
        trend = [0.0]
    else
        # cap trend for viz, preserve order of appearance (dict iter)
        if length(trend) > 6
            trend = trend[end-5:end]
        end
    end

    session_count = length(merged)
    tokens_k = total_tokens / 1000.0
    overall_eff = tokens_k > 0 ? (credited_hehs * data.config.burdenedHourlyRate) / tokens_k : 0.0
    overall_eff = round(overall_eff * 100) / 100

    return (
        hehs_saved = round(credited_hehs; digits=1),
        efficiency = overall_eff,
        value_created = round(credited_value * 100) / 100,
        total_tokens = total_tokens,
        session_count = session_count,
        sessions = session_list,
        hehs_trend = trend,
    )
end

# ═══════════════════════════════════════════════════════════════════════
# Hooks hub gap: write support for attributions (interactive tagging)
# Defensive JSON roundtrip. Merges into existing data.json or creates minimal.
# Called from update! after parsing tag command. Pure-ish (no model mutation).
# ═══════════════════════════════════════════════════════════════════════

"""
    write_attribution_update(path::AbstractString, sid::AbstractString;
                             hehs_manual::Float64, hehs_actual::Float64=0.0,
                             outcome::String="merged-clean", task::String="",
                             notes::String="")::Bool

Writes/updates attribution for sid in the data.json store.
Returns true on success. Defensive (try, defaults).
Does not touch sessions or config.
"""
function write_attribution_update(path::AbstractString, sid::AbstractString;
                                  hehs_manual::Float64, hehs_actual::Float64=0.0,
                                  outcome::String="merged-clean", task::String="",
                                  notes::String="")::Bool
    try
        data = Dict{String,Any}()
        if isfile(path)
            raw = read(path, String)
            if !isempty(strip(raw))
                parsed = JSON.parse(raw)
                if isa(parsed, AbstractDict)
                    data = parsed
                end
            end
        end

        attrs = get(data, "attributions", Dict{String,Any}())
        if !isa(attrs, AbstractDict)
            attrs = Dict{String,Any}()
        end

        # merge to support partial updates (preserve existing hehsActual etc when tagging)
        prev = get(attrs, sid, Dict{String,Any}())
        merged = Dict{String,Any}(prev)
        merged["sid"] = sid
        merged["hehsManual"] = hehs_manual
        if hehs_actual != 0.0 || !haskey(prev, "hehsActual")
            merged["hehsActual"] = hehs_actual
        end
        merged["outcome"] = outcome
        if !isempty(task) || !haskey(prev, "task")
            merged["task"] = task
        end
        if !isempty(notes) || !haskey(prev, "notes")
            merged["notes"] = notes
        end
        merged["taggedAt"] = string(time())

        attrs[sid] = merged
        data["attributions"] = attrs

        # ensure lastIngested or minimal other keys preserved if present
        write(path, JSON.json(data))
        return true
    catch
        return false
    end
end

# Simple parser for tag commands typed by user: "3.5 merged-clean my task" or "hehs=3.5 outcome=merged-clean task=foo"
function parse_tag_cmd(cmd::AbstractString)
    cmd = strip(lowercase(cmd))
    hehs = 0.0
    outcome = "merged-clean"
    task = ""
    # hehs=NN or leading number
    m = match(r"(?:hehs\s*=\s*)?([0-9.]+)", cmd)
    if m !== nothing
        try hehs = parse(Float64, m.captures[1]) catch; hehs=0.0 end
    end
    if occursin("merged-rework", cmd) outcome = "merged-rework" end
    # crude task capture after
    parts = split(cmd)
    if length(parts) > 1
        task = join(parts[2:end], " ")
    end
    return (hehs_manual=hehs, hehs_actual=0.0, outcome=outcome, task=task)
end

@kwdef mutable struct AiMetricsDashboard <: Model
    quit::Bool = false
    tick::Int = 0
    # Unit-2+ : loaded from ~/.ai-metrics/data + logs (pure Julia, no Node)
    hehs_saved::Float64 = 12.5
    efficiency::Float64 = 8.7
    value_created::Float64 = 1850.0
    total_tokens::Int = 124300
    session_count::Int = 47
    last_ingested::String = "never"
    # Phase X (hooks hub gaps): source transparency so users see if real Grok logs/attributions are driving numbers
    data_source::String = "unknown"   # "real" | "demo" | "empty" | "error"
    source_detail::String = ""        # e.g. "2 sessions + 1 attr" or "no ~/.grok/logs found — using sample"
    # tagging input (reuse TextInput + enter pattern from cyberdeck)
    attr_input::TextInput = TextInput()
    tag_mode::Bool = false
    # store paths from last load_data! so tagging can write to the same (critical for mktemp tests)
    data_path::Union{String, Nothing} = nothing
    logs_path::Union{String, Nothing} = nothing
    # Unit-4: sessions list (sid, tokens summary, hehs)
    sessions::Vector{String} = ["sid-abc123 42k hehs=3.2", "sid-def456 18k hehs=1.1"]
    selected::Int = 1
    # hehs_trend kept for data compatibility (previously used by quantum viz; not rendered now)
    hehs_trend::Vector{Float64} = [1.2, 2.5, 1.8, 3.4, 2.9, 4.1]
    # Phase 4: real data layer (light extension). stored + sessions_data for rich data;
    # scalars + sessions + trend + last_ingested are populated from pures (or dummy fallback).
    stored::Union{StoredData, Nothing} = nothing
    sessions_data::Vector{GrokSessionUsage} = GrokSessionUsage[]
end

# Real `load_data!` (Phase 4): thin orchestrator calling the pures.
# Calls load_stored_data + parse_grok_unified_jsonl + compute_dashboard_aggregates,
# populates scalars, sessions (derived list), last_ingested, trend, and the new
# stored / sessions_data fields.
# Supports optional paths for test fixtures (mktemp). When called with explicit paths,
# uses the computed (real) values even if zero/empty. When using default paths and
# no data present, falls back to illustrative dummy sample (keeps UX + compat with
# prior direct 'r' tests that expect positive bump + "loaded-" ).
# Any unexpected error during load/parse/compute -> fallback to dummy.
# 'r' in update! remains wired as: load_data!(m)  (tick ++ is at end of update!)
function _apply_dummy_load!(m::AiMetricsDashboard)
    m.hehs_saved = 14.75
    m.efficiency = 9.2
    m.value_created = 2100.50
    m.total_tokens = 138450
    m.session_count = 52
    m.last_ingested = "loaded-$(m.tick)"
    m.sessions = ["sid-abc123 42k hehs=3.2", "sid-def456 18k hehs=1.1", "sid-ghi789 77k hehs=5.0"]
    m.selected = 1
    m.hehs_trend = [1.2, 2.5, 1.8, 3.4, 2.9, 4.1, round(m.hehs_saved; digits=1)]
    m.stored = nothing
    m.sessions_data = GrokSessionUsage[]
    m.data_source = "demo"
    m.source_detail = "no real data at default paths — using sample"
    m.data_path = nothing
    m.logs_path = nothing
end

function load_data!(m::AiMetricsDashboard; data_path=nothing, logs_path=nothing)
    # bad arg types (for the existing "fallback to dummy on error" test) -> immediately dummy
    if !(data_path === nothing || data_path isa AbstractString) || !(logs_path === nothing || logs_path isa AbstractString)
        _apply_dummy_load!(m)
        m.last_ingested = "loaded-$(m.tick)"
        return
    end

    dpath = data_path !== nothing ? data_path : expanduser("~/.ai-metrics/data.json")
    lpath = logs_path !== nothing ? logs_path : expanduser("~/.grok/logs/unified.jsonl")
    use_explicit_path = (data_path !== nothing || logs_path !== nothing)

    # remember for tagging writes (allows mktemp fixtures to work end-to-end)
    m.data_path = dpath
    m.logs_path = lpath

    try
        stored = load_stored_data(dpath)
        parsed = parse_grok_unified_jsonl(lpath)
        agg = compute_dashboard_aggregates(stored, parsed)

        has_real = !isempty(stored.sessions) || !isempty(parsed) || agg.session_count > 0

        if !has_real && !use_explicit_path
            # default paths + no data on disk -> fallback dummy for visible sample + test compat
            _apply_dummy_load!(m)
            m.data_source = "demo"
            m.source_detail = "no real data at default paths — using sample"
            m.data_path = dpath
            m.logs_path = lpath
            return
        end

        # real populate from pures (even if results are 0/"no sessions" when explicit empty fixture used)
        m.stored = stored

        # build sessions_data from merge (data preferred; mirrors compute logic)
        merged = Dict{String, GrokSessionUsage}()
        for (sid, u) in stored.sessions
            merged[sid] = u
        end
        for (sid, u) in parsed
            if !haskey(merged, sid)
                merged[sid] = u
            end
        end
        m.sessions_data = collect(values(merged))

        m.hehs_saved = agg.hehs_saved
        m.efficiency = agg.efficiency
        m.value_created = agg.value_created
        m.total_tokens = agg.total_tokens
        m.session_count = agg.session_count
        m.sessions = agg.sessions
        m.hehs_trend = agg.hehs_trend
        m.selected = 1
        m.last_ingested = (stored.lastIngested !== nothing && !isempty(stored.lastIngested)) ? string(stored.lastIngested) : "loaded-$(m.tick)"

        # hooks hub transparency
        m.data_source = "real"
        n_s = length(merged)
        n_a = length(stored.attributions)
        m.source_detail = "$(n_s) session(s) + $(n_a) attr(s)"
    catch err
        # any error (e.g. bad path type, IO surprises, etc) -> safe dummy fallback
        _apply_dummy_load!(m)
        m.data_source = "error"
        m.source_detail = "load error — using sample"
        m.data_path = dpath
        m.logs_path = lpath
    end
end


should_quit(m::AiMetricsDashboard) = m.quit

function update!(m::AiMetricsDashboard, evt::KeyEvent)
    if evt.key == :char && evt.char == 'q'
        m.quit = true
    elseif evt.key == :escape
        if m.tag_mode
            m.tag_mode = false
            # clear input
            # (simple: new input)
            m.attr_input = TextInput()
        else
            m.quit = true
        end
        m.tick += 1
        return
    elseif evt.key == :char && evt.char == 'r'
        # Phase 4: 'r' wired to real load_data! (which calls pures or falls back)
        load_data!(m)
    elseif evt.key == :char && evt.char == 't'
        # hooks hub: enter tag mode for selected session
        m.tag_mode = true
        m.attr_input = TextInput(; focused=true)
        m.tick += 1
        return
    end

    # Unit-4 list nav (only if not tagging)
    if !m.tag_mode
        n = length(m.sessions)
        if n > 0
            if evt.key == :char && evt.char == 'k' || evt.key == :up
                m.selected = max(1, m.selected - 1)
            elseif evt.key == :char && evt.char == 'j' || evt.key == :down
                m.selected = min(n, m.selected + 1)
            end
        end
    end

    # Tag input routing (when active)
    if m.tag_mode
        if handle_key!(m.attr_input, evt)
            m.tick += 1
            return
        end
        if evt.key == :enter
            cmd = strip(text(m.attr_input))
            m.attr_input = TextInput()
            m.tag_mode = false
            if !isempty(cmd) && length(m.sessions) > 0
                sel_idx = clamp(m.selected, 1, length(m.sessions))
                # sessions list strings are short; prefer sessions_data for sid if available
                sid = ""
                if !isempty(m.sessions_data)
                    sidx = clamp(m.selected, 1, length(m.sessions_data))
                    sid = m.sessions_data[sidx].sid
                else
                    # fallback parse from display string (first token before space or …)
                    sstr = m.sessions[sel_idx]
                    sid = split(sstr, [' ', '…'])[1]
                end
                if !isempty(sid)
                    parsed = parse_tag_cmd(cmd)
                    dpath = m.data_path !== nothing ? m.data_path : expanduser("~/.ai-metrics/data.json")
                    ok = write_attribution_update(dpath, sid; hehs_manual=parsed.hehs_manual,
                                                  hehs_actual=parsed.hehs_actual,
                                                  outcome=parsed.outcome, task=parsed.task)
                    # refresh to reflect new credit - use the same path
                    if m.data_path !== nothing
                        load_data!(m; data_path=m.data_path, logs_path=m.logs_path)
                    else
                        load_data!(m)
                    end
                    if ok
                        m.last_ingested = "tagged-" * string(m.tick)
                    end
                end
            end
            m.tick += 1
            return
        end
    end

    # tick advance exclusively in update! (AGENTS.md + review fix)
    m.tick += 1
end

function view(m::AiMetricsDashboard, f::Frame)
    buf = f.buffer
    area = f.area

    if area.width < 20 || area.height < 6
        set_string!(buf, area.x, area.y, "QCI AI (small)", tstyle(:text_dim))
        return
    end

    # Outer block — QCI navy/cyan glass-like
    outer = Block(
        title = "QCI AI METRICS",
        border_style = Style(; fg = QCI_CYAN),
        title_style = Style(; fg = QCI_CYAN, bold = true),
    )
    main = render(outer, area, buf)

    # Layout: header + content (SESSIONS left + metrics graphs right, horizontal) + status
    # Sessions is now the leftmost main panel. Metrics (gauges) placed horizontally to its right.
    # No quantum / trend canvas panel.
    rows = split_layout(Layout(Vertical, [Fixed(6), Fill(), Fixed(1)]), main)
    if length(rows) < 3
        return
    end
    header_area = rows[1]
    content_area = rows[2]
    status_area = rows[3]

    # BigText QCI branding (cyan)
    bt = BigText("QCI AI"; style = Style(; fg = QCI_CYAN, bold = true))
    tw, _ = intrinsic_size(bt)
    tx = header_area.x + max(0, (header_area.width - tw) ÷ 2)
    title_r = Rect(tx, header_area.y + 1, min(tw, header_area.width), 4)
    render(bt, title_r, buf)

    # Subtitle (unit-2: shows loaded last_ingested) + hooks hub source transparency (REAL vs DEMO)
    src_tag = uppercase(m.data_source)
    detail = !isempty(m.source_detail) ? " " * m.source_detail : ""
    sub = "GROK • LOCAL • HEHS DASHBOARD • $(m.last_ingested) • $(src_tag)$(detail) • tick=$(m.tick)"
    sx = header_area.x + max(0, (header_area.width - length(sub)) ÷ 2)
    sub_y = header_area.y + 5
    if sub_y <= bottom(header_area)
        set_string!(buf, sx, sub_y, sub, Style(; fg = QCI_CYAN, dim = true))
    end

    # Main content area: SESSIONS (leftmost) | metrics BarChart (stacked on right)
    if content_area.height >= 3 && content_area.width >= 30
        panels = split_layout(Layout(Horizontal, [Percent(38), Fill()]), content_area)
        if length(panels) >= 2
            sessions_area = panels[1]
            metrics_area = panels[2]

            # Left panel: SESSIONS list (tall, leftmost)
            if sessions_area.height >= 2 && sessions_area.width >= 10
                items = isempty(m.sessions) ? ["— no sessions —"] : m.sessions
                sel = clamp(m.selected, 1, length(items))
                lst = SelectableList(items; selected=sel, block=Block(title="SESSIONS", border_style=Style(; fg=QCI_CYAN), title_padding=0))
                render(lst, sessions_area, buf)
            end

            # Right: metrics as BarChart (stacked close vertically)
            # Labels (name + value) on the left of each bar
            if metrics_area.height >= 5 && metrics_area.width >= 20
                hs = clamp(m.hehs_saved / 25, 0.0, 1.0)
                ef = clamp(m.efficiency / 15, 0.0, 1.0)
                vc = clamp(m.value_created / 3000, 0.0, 1.0)
                tk = clamp(m.total_tokens / 200000, 0.0, 1.0)

                bars = [
                    BarEntry("HEHS " * string(round(m.hehs_saved; digits=1)), hs; style=Style(; fg=QCI_CYAN)),
                    BarEntry("EFF " * string(round(m.efficiency; digits=1)), ef; style=Style(; fg=QCI_CYAN)),
                    BarEntry("VAL " * string(round(Int, m.value_created)), vc; style=Style(; fg=QCI_CYAN)),
                    BarEntry("TOK " * string(m.total_tokens ÷ 1000) * "k", tk; style=Style(; fg=QCI_CYAN)),
                ]

                # Start one row down to align under SESSIONS title (with list items)
                mc = Rect(metrics_area.x, metrics_area.y + 1, metrics_area.width, max(0, metrics_area.height - 1))
                render(BarChart(bars; max_val=1.0, show_values=false, label_width=0), mc, buf)
            end
        end
    else
        # Small terminal fallback: sessions only
        if content_area.height >= 2 && content_area.width >= 10
            items = isempty(m.sessions) ? ["— no sessions —"] : m.sessions
            sel = clamp(m.selected, 1, length(items))
            lst = SelectableList(items; selected=sel, block=Block(title="SESSIONS", border_style=Style(; fg=QCI_CYAN), title_padding=0))
            render(lst, content_area, buf)
        end
    end

    # StatusBar (QCI help + live stats)
    if status_area.width >= 10
        help = m.tag_mode ? "[enter]save tag  [esc]cancel" : "[r]refresh  [j/k/↑↓]nav  [t]tag  [q]quit"
        stats = "HEHS=$(round(m.hehs_saved;digits=1)) eff=$(round(m.efficiency;digits=1)) tok=$(m.total_tokens÷1000)k"
        render(StatusBar(
            left = [Span(" " * help, Style(; fg = QCI_CYAN, dim=true))],
            right = [Span(" " * stats, Style(; fg = QCI_CYAN, dim=true))],
        ), status_area, buf)
    end

    # Tag input prompt (simple, when active — rendered near bottom if space)
    if m.tag_mode && status_area.width >= 10
        # show prompt + input just above status (rough; full layout polish later)
        tag_y = max(status_area.y - 1, header_area.y + 6)
        if tag_y > 0
            set_string!(buf, area.x + 2, tag_y, "TAG> ", Style(; fg=QCI_CYAN))
            # render the input widget in a small rect
            render(m.attr_input, Rect(area.x + 7, tag_y, max(10, area.width-10), 1), buf)
        end
    end
end

# Runner for MVP
function ai_metrics_dashboard()
    # QCI "theme" applied via explicit colors (no global set_theme for unit-1)
    app(AiMetricsDashboard())
end

const run_ai_metrics_dashboard = ai_metrics_dashboard