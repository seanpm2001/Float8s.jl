abstract type AbstractFloat8 <: AbstractFloat end
primitive type Float8 <: AbstractFloat8 8 end        # standard 3 exp version
primitive type Float8_4 <: AbstractFloat8 8 end      # version with 4 exp bits

# conversions
Float8(x::UInt8) = reinterpret(Float8,x)
Float8_4(x::UInt8) = reinterpret(Float8_4,x)
UInt8(x::T) where {T<:AbstractFloat8} = reinterpret(UInt8,x)
bitstring(x::AbstractFloat8) = bitstring(reinterpret(UInt8,x))
Float8(x::T) where {T<:Union{Int16,Int32,Int64,Float64,Float16}} = Float8(Float32(x))
Float8_4(x::T) where {T<:Union{Int16,Int32,Int64,Float64,Float16}} = Float8_4(Float32(x))
(::Type{T})(x::AbstractFloat8) where {T<:Union{Int16,Int32,Int64,Float64,Float16}} = T(Float32(x))

# masks, UInt8s with 1s for the respective parts
sign_mask(::Type{T}) where {T<:AbstractFloat8} = 0x80
exponent_mask(::Type{Float8}) = 0x70
exponent_mask(::Type{Float8_4}) = 0x78
significand_mask(::Type{Float8}) = 0x0f
significand_mask(::Type{Float8_4}) = 0x07

sign_mask(::Type{Float32}) =            0x8000_0000
exponent_mask(::Type{Float32}) =        0x7f80_0000
significand_mask(::Type{Float32}) =     0x007f_ffff
n_exponent_bits(::Type{Float32}) =      8
n_significant_bits(::Type{Float32}) =   23

# number of exp/sig bits
n_exponent_bits(::Type{Float8}) = 3
n_exponent_bits(::Type{Float8_4}) = 4
n_significant_bits(::Type{Float8}) = 4
n_significant_bits(::Type{Float8_4}) = 3
bias(::Type{Float8}) = 3
bias(::Type{Float8_4}) = 7

eps(::Type{Float8}) = Float8(0x02)
eps(::Type{Float8_4}) = Float8_4(0x20)

# define inifinities and nan
inf8(::Type{Float8}) = Float8(0x70)
inf8(::Type{Float8_4}) = Float8_4(0x78)

nan8(::Type{Float8}) = Float8(0x78)
nan8(::Type{Float8_4}) = Float8_4(0x7c)

const NaN8 = nan8(Float8)
const Inf8 = inf8(Float8)

const NaN8_4 = nan8(Float8_4)
const Inf8_4 = inf8(Float8_4)

typemin(::Type{T}) where {T<:AbstractFloat8} = -inf8(T)
typemax(::Type{T}) where {T<:AbstractFloat8} = inf8(T)

# smallest non-subnormal number, largest representable number
floatmin(::Type{Float8}) = Float8(0x10)
floatmin(::Type{Float8_4}) = Float8_4(0x08)
floatmax(::Type{Float8}) = Float8(0x6f)
floatmax(::Type{Float8_4}) = Float8_4(0x77)

# one and zero element
one(::Type{Float8}) = Float8(0x30)
one(::Type{Float8_4}) = Float8_4(0x38)
zero(::Type{T}) where {T<:AbstractFloat8} = Float8(0x00)

one(x::AbstractFloat8) = one(typeof(x))
zero(x::AbstractFloat8) = zero(typeof(x))

# is positive zero 0x00 or negative zero 0x80
iszero(x::AbstractFloat8) = reinterpret(UInt8, x) == 0x00 || reinterpret(UInt8,x) == 0x80
-(x::T) where {T<:AbstractFloat8} = reinterpret(T, reinterpret(UInt8, x) ⊻ 0x80)
Bool(x::AbstractFloat8) = iszero(x) ? false : isone(x) ? true : throw(InexactError(:Bool, Bool, x))

abs(x::T) where {T<:AbstractFloat8} = reinterpret(T, reinterpret(UInt8, x) & 0x7f)
isnan(x::T) where {T<:AbstractFloat8} = reinterpret(UInt8,x) & 0x7f > exponent_mask(T)
isfinite(x::T) where {T<:AbstractFloat8} = reinterpret(UInt8,x) & exponent_mask(T) != exponent_mask(T)

precision(::Type{Float8}) = 5
precision(::Type{Float8_4}) = 4

# Float32 -> Float8 algorithm in analogy to
#
# Float32 -> Float16 algorithm from:
#   "Fast Half Float Conversion" by Jeroen van der Zijp
#   ftp://ftp.fox-toolkit.org/pub/fasthalffloatconversion.pdf
#
# With adjustments for round-to-nearest, ties to even.

function create_base_shifttable(::Type{T}) where {T<:AbstractFloat8}

    basetable = Vector{UInt8}(undef, 512)
    shifttable = Vector{UInt8}(undef, 512)

    if T == Float8
        # elements derive from
        # [1]   2^-6 = Float8(0x01) the smallest representable number (subnormal)
        # [2]   2^-2 = Float8(0x10) the first non-subnormal number
        # [3]   2^4 = 16 > floatmax(Float8) is the smallest power of two that is larger than floatmax(Float8)

        e_limits = [-6,-2,4]

        # shift a 0x1 in the exponent bits created by "significand_mask(Float32) + 0x1"
        # to the first significand bit
        # e_shift_subnorm is 17 for Float8
        e_shift_subnorm = n_significant_bits(Float32)-(n_significant_bits(Float8)-1)+e_limits[2]-1
    elseif T == Float8_4

        # see above
        e_limits = [-9,-6,8]

        # shift a 0x1 in the exponent bits created by "significand_mask(Float32) + 0x1"
        # to the first significand bit
        # e_shift_subnorm is 14 for Float8_4
        e_shift_subnorm = n_significant_bits(Float32)-(n_significant_bits(Float8_4)-1)+e_limits[2]-1
    end

    for i = 0:255                               # all possible exponents for Float32
        e = i - 127                             # subtract Float32 bias
        if e < e_limits[1]                      # Very small numbers map to +- zero
            basetable[i|0x000+1] = zero(T)
            basetable[i|0x100+1] = -zero(T)
            shifttable[i|0x000+1] = n_significant_bits(T)+1
            shifttable[i|0x100+1] = n_significant_bits(T)+1
        elseif e < e_limits[2]                  # Small numbers map to denorms
            basetable[i|0x000+1] = zero(T)
            basetable[i|0x100+1] = -zero(T)
            shifttable[i|0x000+1] = -e+e_shift_subnorm
            shifttable[i|0x100+1] = -e+e_shift_subnorm
        elseif e < e_limits[3]                  # Normal numbers just lose precision
            basetable[i|0x000+1] = ((e+bias(T)) << n_significant_bits(T))
            basetable[i|0x100+1] = ((e+bias(T)) << n_significant_bits(T)) | sign_mask(T)
            shifttable[i|0x000+1] = n_significant_bits(Float32)-n_significant_bits(T)
            shifttable[i|0x100+1] = n_significant_bits(Float32)-n_significant_bits(T)
        elseif e < 128                          # Large numbers map to Infinity
            basetable[i|0x000+1] = inf8(T)
            basetable[i|0x100+1] = -inf8(T)
            shifttable[i|0x000+1] = n_significant_bits(T)+1
            shifttable[i|0x100+1] = n_significant_bits(T)+1
        else                                    # Infinity and NaN's stay Infinity and NaN's
            basetable[i|0x000+1] = inf8(T)
            basetable[i|0x100+1] = -inf8(T)
            shifttable[i|0x000+1] = n_significant_bits(Float32)-n_significant_bits(T)
            shifttable[i|0x100+1] = n_significant_bits(Float32)-n_significant_bits(T)
        end
    end

    return basetable, shifttable
end

const basetable8, shifttable8 = create_base_shifttable(Float8)
const basetable8_4, shifttable8_4 = create_base_shifttable(Float8_4)

function Float8(val::Float32)

    f = reinterpret(UInt32, val)

    if isnan(val)       #TODO retain the significant bits for NaN?
        return nan8(Float8)
    end

    # exponent as Int64
    i = f >> n_significant_bits(Float32) + 1
    @inbounds sh = shifttable8[i]
    f &= significand_mask(Float32)

    # If `val` is subnormal, the tables are set up to force the
    # result to 0, so the significand has an implicit `1` in the
    # cases we care about.

    f |= significand_mask(Float32) + 0x1
    @inbounds h = (basetable8[i] + (f >> sh) & significand_mask(Float8)) % UInt8

    # rounding
    nextbit = (f >> (sh-1)) & 1
    if nextbit != 0 && (h & exponent_mask(Float8)) != exponent_mask(Float8)
        # Round halfway to even or check lower bits
        if h&1 == 1 || (f & ((1<<(sh-1))-1)) != 0
            h += one(UInt8)
        end
    end
    return reinterpret(Float8, h)
end

function Float8_4(val::Float32)

    f = reinterpret(UInt32, val)

    if isnan(val)       #TODO retain the significant bits for NaN?
        return nan8(Float8_4)
    end

    # exponent as Int64
    i = f >> n_significant_bits(Float32) + 1
    @inbounds sh = shifttable8_4[i]
    f &= significand_mask(Float32)

    # If `val` is subnormal, the tables are set up to force the
    # result to 0, so the significand has an implicit `1` in the
    # cases we care about.

    f |= significand_mask(Float32) + 0x1
    @inbounds h = (basetable8_4[i] + (f >> sh) & significand_mask(Float8_4)) % UInt8

    # rounding
    nextbit = (f >> (sh-1)) & 1
    if nextbit != 0 && (h & exponent_mask(Float8_4)) != exponent_mask(Float8_4)
        # Round halfway to even or check lower bits
        if h&1 == 1 || (f & ((1<<(sh-1))-1)) != 0
            h += one(UInt8)
        end
    end
    return reinterpret(Float8_4, h)
end

first_sig_bit_mask(::Type{Float8}) = 0x00000008
first_sig_bit_mask(::Type{Float8_4}) = 0x00000004

sig_bit_shift(::Type{Float8}) = 19          # 23 significand bits for Float32 - 4 significand bits for Float8
sig_bit_shift(::Type{Float8_4}) = 20        # 23 significand bits for Float32 - 3 significand bits for Float8_4

bias_difference(::Type{Float8}) = 0x0000007c        # = 124, 127 for Float32 minus 3 for Float 8
bias_difference(::Type{Float8_4}) = 0x00000078      # = 120, 127 for Float32 minus 7 for Float 8_4

exp_bits_all_one(::Type{Float8}) = 0x00000007
exp_bits_all_one(::Type{Float8_4}) = 0x0000000f

function Float32(val::T) where {T<:AbstractFloat8}

    ival = reinterpret(UInt8, val)

    # seperate into sign, exponent, significand
    sign = UInt32((ival & sign_mask(T)) >> 7)
    exp  = UInt32((ival & exponent_mask(T)) >> n_significant_bits(T))
    sig = UInt32(ival & significand_mask(T))

    if exp == zero(UInt32)
        if sig == zero(UInt32)          # +-0 case
            return reinterpret(Float32,sign << 31)
        else                            # subnormals
            n_bit = 1
            # first significand bit set to one, else zero, to check for size of subnormal
            bit = first_sig_bit_mask(T)
            while (bit & sig) == 0
                n_bit = n_bit + 1
                bit = bit >> 1
            end
            sign = sign << 31

            # bias = 2^(n_exp-1) - 1, i.e. 127 for Float32, 15 for Float16, 3 for Float8, 7 for Float8_4
            # difference in bias + 1 has to be added, e.g. 127-3 = 124 = 0x0000007c

            exp = ((bias_difference(T)+1 - n_bit) << 23) % UInt32
            sig = ((sig & (~bit)) << n_bit) << sig_bit_shift(T)
            ret = sign | exp | sig
            reinterpret(Float32,ret)
        end
    elseif exp == exp_bits_all_one(T)       # Inf/NaN case
        if sig == zero(UInt32)              # Infinity
            if sign == zero(UInt32)
                return Inf32
            else
                return -Inf32
            end
        else                # NaN, preserve sign and significand (first sig bit always 1)
            # NaN32 == reinterpret(Flaot32,0x7fc00000)
            ret = 0x7fc00000 | (sign<<31) | (sig<<sig_bit_shift(T))
            reinterpret(Float32,ret)
        end
    else
        sign = sign << 31

        # bias = 2^(n_exp-1) - 1, i.e. 127 for Float32, 15 for Float16, 3 for Float8, 7 for Float8_4
        # difference in bias has to be added, e.g. 127-3 = 124 = 0x0000007c

        exp  = (exp + bias_difference(T)) << 23
        sig  = sig << sig_bit_shift(T)
        ret = sign | exp | sig
        return reinterpret(Float32, ret)
    end
end

round(x::T, r::RoundingMode{:ToZero}) where {T<:AbstractFloat8} = T(round(Float32(x), r))
round(x::T, r::RoundingMode{:Down}) where {T<:AbstractFloat8} = T(round(Float32(x), r))
round(x::T, r::RoundingMode{:Up}) where {T<:AbstractFloat8} = T(round(Float32(x), r))
round(x::T, r::RoundingMode{:Nearest}) where {T<:AbstractFloat8} = T(round(Float32(x), r))

function ==(x::AbstractFloat8, y::AbstractFloat8)
    if isnan(x) || isnan(y)     # Alternatively, For Float16: (ix|iy)&0x7fff > 0x7c00
        return false
    end
    if iszero(x) && iszero(y)   # For Float16: (ix|iy)&0x7fff == 0x0000
        return true
    end
    return reinterpret(UInt8,x) == reinterpret(UInt8,y)
end

for op in (:<, :<=, :isless)
    @eval ($op)(a::T, b::T) where {T<:AbstractFloat8} = ($op)(Float32(a), Float32(b))
end

for op in (:+, :-, :*, :/, :\, :^)
    @eval ($op)(a::Float8, b::Float8) = Float8(($op)(Float32(a), Float32(b)))
    @eval ($op)(a::Float8_4, b::Float8_4) = Float8_4(($op)(Float32(a), Float32(b)))
end

for func in (:sin,:cos,:tan,:asin,:acos,:atan,:sinh,:cosh,:tanh,:asinh,:acosh,
             :atanh,:exp,:exp2,:exp10,:log,:log2,:log10,:sqrt,:lgamma,:log1p)
    @eval begin
        $func(a::Float8) = Float8($func(Float32(a)))
        $func(a::Float8_4) = Float8_4($func(Float32(a)))
    end
end

for func in (:atan,:hypot)
    @eval begin
        $func(a::Float8,b::Float8) = Float8($func(Float32(a),Float32(b)))
        $func(a::Float8_4,b::Float8_4) = Float8_4($func(Float32(a),Float32(b)))
    end
end

function show(io::IO,x::Float8)
    if isnan(x)
        print(io,"NaN8")
    elseif isinf(x)
        print(io,"Inf8")
    else
        io2 = IOBuffer()
        print(io2,Float32(x))
        f = String(take!(io2))
        print(io,"Float8("*f*")")
    end
end

function show(io::IO,x::Float8_4)
    if isnan(x)
        print(io,"NaN8_4")
    elseif isinf(x)
        print(io,"Inf8_4")
    else
        io2 = IOBuffer()
        print(io2,Float32(x))
        f = String(take!(io2))
        print(io,"Float8_4("*f*")")
    end
end
