# ---Capital Recovery Factor (CRF) ---
function calc_crf(rate, lifetime)
    # Handle edges: if rate is 0, just spread over lifetime. If lifetime is infinite/missing, handle gracefully.
    if ismissing(rate) || ismissing(lifetime) || lifetime <= 0
        return 1.0 # Fallback (treat as 1 year or overnight)
    end
    if rate <= 1e-6
        return 1.0 / lifetime
    end
    return (rate * (1 + rate)^lifetime) / ((1 + rate)^lifetime - 1)
end
