module TachikomaUITest

# Entry point for the experiment package.
# Re-export Tachikoma for convenience in our apps/tests, or define our own models here.
using Tachikoma
@tachikoma_app

export Tachikoma

include("cyberdeck.jl")
include("ai_metrics_dashboard.jl")

# Demo exports (Phase 1: model; Phase 4 adds runner)
export Cyberdeck, cyberdeck, run_cyberdeck

# AI Metrics (small units MVP)
export AiMetricsDashboard, ai_metrics_dashboard, run_ai_metrics_dashboard

# Phase 1-3 pure data layer (per plan + review)
export TokenBreakdown, GrokSessionUsage, Attribution, MetricsConfig, StoredData, DEFAULT_CONFIG
export load_stored_data, parse_grok_unified_jsonl, compute_efficiency, compute_dashboard_aggregates, filter_quality_for_credit

# Add shared utilities, demo apps, or reexports as the project grows.
# Example:
# include("my_dashboard.jl")

end # module