# Capital Recovery Factor (CRF)
function calc_crf(rate, lifetime)
    if ismissing(rate) || ismissing(lifetime) || lifetime <= 0
        @warn "calc_crf called with missing or non-positive lifetime ($lifetime) — returning 1.0 fallback."
        return 1.0
    end
    if rate <= 1e-6
        return 1.0 / lifetime
    end
    return (rate * (1 + rate)^lifetime) / ((1 + rate)^lifetime - 1)
end
