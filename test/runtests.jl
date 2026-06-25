using Test
using Tachikoma
using Supposition, Supposition.Data

const T = Tachikoma

# Include component tests (add more as we build features)
include("test_tachikoma_basics.jl")
include("test_cyberdeck.jl")
include("test_ai_metrics_dashboard.jl")
# include("test_myapp_logic.jl")
# include("test_widgets.jl")
# etc.

# println guarded/removed per review (noise in test output)